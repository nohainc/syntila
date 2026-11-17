import { PersonGrantQuotaSchema, WorkspaceInvitationSchema } from "@syntila/protocol";
import { readBody } from "./validation.js";
import { ownsActiveWorkspace } from "../queries.js";
import { hashToken } from "@syntila/security";
import { hasPaidFeature, requirePaidFeature } from "../account-plan.js";
import { createEventPublisher } from "../event-publisher.js";
import { MutationIdempotency, NO_RECEIPT, type ReceiptWrite } from "./mutation-idempotency.js";
import {
  HttpError,
  json,
  securityContext,
  type SecurityEnv,
} from "./http-security.js";
import { dataOf } from "../../platform/data.js";

/** First instant of the current UTC month, as an ISO timestamp. */
export function monthStartIso(now = new Date()): string {
  return new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1),
  ).toISOString();
}

/** Approximate run seconds a person used on a Workspace this UTC month. */
export const MONTHLY_RUN_SECONDS_SQL = `SELECT COALESCE(ROUND(SUM(GREATEST(0, EXTRACT(EPOCH FROM (updated_at - created_at)))))::bigint, 0) AS seconds
   FROM worker_assignments
   WHERE execution_workspace_id = ?1 AND requested_by_user_id = ?2 AND created_at >= ?3`;

/**
 * ID-only invalidation on each party's own user stream: the owner sees the
 * response while on the sharing page, and the invitee sees new invitations.
 * A failed signal never fails the mutation; clients reconcile on reconnect.
 */
async function publishWorkspaceInvitationChanged(
  env: SecurityEnv,
  invitationId: string,
  userIds: readonly (string | null | undefined)[],
) {
  const publisher = createEventPublisher(env);
  for (const userId of new Set(userIds.filter((id): id is string => !!id))) {
    try {
      await publisher.publish({
        type: "workspace_invitation.updated",
        stream: { kind: "user", id: userId },
        payload: { entityId: invitationId },
        recipientUserIds: [userId],
        // Live-only: invitation lists are small and refetched on reconnect,
        // so this signal needs no replay log entry.
        durable: false,
      });
    } catch (error) {
      console.warn("workspace_invitation.signal_failed", {
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }
}

async function userIdByEmail(env: SecurityEnv, email: string) {
  const row = await dataOf(env).read.row<{ id: string }>`SELECT id FROM users WHERE LOWER(email) = ${email.trim().toLowerCase()} LIMIT 1`;
  return row?.id;
}

const INVITATION_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_PENDING_PER_WORKSPACE = 20;

async function ownedWorkspace(
  env: SecurityEnv,
  workspaceId: string,
  userId: string,
) {
  const workspace = await ownsActiveWorkspace(dataOf(env).read, workspaceId, userId);
  if (!workspace) throw new HttpError(404, "Workspace not found");
}

/**
 * Owner-only: list (GET), create (POST {email}) and revoke
 * (POST .../:invitationId/revoke) Workspace invitations. The invitation grants
 * nothing until the invitee accepts it.
 */
export async function handleWorkspaceInvitations(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  invitationId?: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await ownedWorkspace(env, workspaceId, context.userId);
  const now = new Date().toISOString();
  if (invitationId !== undefined) {
    if (request.method !== "POST")
      throw new HttpError(405, "Unsupported method");
    const revoked = await dataOf(env).read.run`UPDATE workspace_invitations SET status='revoked',updated_at=${now} WHERE id=${invitationId} AND workspace_id=${workspaceId} AND status='pending'`;
    if (!revoked)
      throw new HttpError(404, "Pending invitation not found");
    const invitee = await dataOf(env).read.row<{ email: string }>`SELECT email FROM workspace_invitations WHERE id = ${invitationId}`;
    await publishWorkspaceInvitationChanged(env, invitationId, [
      context.userId,
      invitee ? await userIdByEmail(env, invitee.email) : undefined,
    ]);
    return json({ revoked: true });
  }
  if (request.method === "GET") {
    const rows = await dataOf(env).read.rows`SELECT id, email, status, expires_at AS "expiresAt", created_at AS "createdAt"
       FROM workspace_invitations WHERE workspace_id = ${workspaceId} ORDER BY created_at DESC LIMIT 100`;
    return json({ invitations: rows });
  }
  if (request.method !== "POST") throw new HttpError(405, "Unsupported method");
  // Inviting people is the paid part of sharing; listing and revoking stay
  // free so a downgraded owner can still see and remove access.
  await requirePaidFeature(env, context.userId, "workspace.sharing");
  const body = await readBody(request, WorkspaceInvitationSchema, {
    message: "An email address is required",
  });
  // A retried send with the same Idempotency-Key returns the first result.
  const receipt = await MutationIdempotency.from(
    request,
    env.SYNTILA_DB,
    context.userId,
    `workspace-invitation:${workspaceId}`,
    body,
  );
  const replay = await receipt?.replay();
  if (replay) return replay;
  const email = body.email.trim().toLowerCase();
  if (!email.includes("@") || email.length > 254)
    throw new HttpError(400, "Enter a valid email address");
  if (email === context.user.email.trim().toLowerCase())
    throw new HttpError(400, "You cannot invite yourself");
  await dataOf(env).read.run`UPDATE workspace_invitations SET status='expired',updated_at=${now} WHERE workspace_id=${workspaceId} AND status='pending' AND expires_at<=${now}`;
  const already = await dataOf(env).read.row`SELECT 1 AS found FROM workspace_person_grants g JOIN users u ON u.id = g.user_id
     WHERE g.workspace_id = ${workspaceId} AND g.status = 'active' AND LOWER(u.email) = ${email}`;
  if (already) throw new HttpError(409, "This person already has access");
  const pending = await dataOf(env).read.row<{ n: number; same: number | null }>`SELECT COUNT(*) AS n, COUNT(*) FILTER (WHERE LOWER(email) = ${email}) AS same FROM workspace_invitations WHERE workspace_id = ${workspaceId} AND status = 'pending'`;
  if (pending?.same)
    throw new HttpError(409, "An invitation is already pending");
  if ((pending?.n ?? 0) >= MAX_PENDING_PER_WORKSPACE)
    throw new HttpError(429, "Too many pending invitations");
  const id = `winv-${crypto.randomUUID()}`;
  const token = `workspace_invite_${crypto.randomUUID()}_${crypto.randomUUID()}`;
  const expiresAt = new Date(Date.now() + INVITATION_TTL_MS).toISOString();
  const created = { id, email, status: "pending", expiresAt };
  const tokenHash = await hashToken(token);
  const write = (receiptWrite: ReceiptWrite) =>
    dataOf(env).tx("workspace.invitation.create", async (tx) => {
      await receiptWrite(tx);
      await tx.run`INSERT INTO workspace_invitations(id,workspace_id,email,token_hash,invited_by_user_id,status,expires_at,created_at,updated_at)
     VALUES(${id},${workspaceId},${email},${tokenHash},${context.userId},'pending',${expiresAt}::timestamptz,${now}::timestamptz,${now}::timestamptz)`;
    });
  const concurrentReplay = receipt
    ? await receipt.commit(created, 201, write)
    : (await write(NO_RECEIPT), null);
  if (concurrentReplay) return concurrentReplay;
  await publishWorkspaceInvitationChanged(env, id, [
    context.userId,
    await userIdByEmail(env, email),
  ]);
  return json(created, { status: 201 });
}

/** The signed-in person's pending Workspace invitations, matched by email. */
export async function handleMyWorkspaceInvitations(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method !== "GET") throw new HttpError(405, "Unsupported method");
  const rows = await dataOf(env).read.rows`SELECT i.id, ew.name AS "workspaceName", u.display_name AS "ownerName", i.expires_at AS "expiresAt"
     FROM workspace_invitations i
     JOIN execution_workspaces ew ON ew.id = i.workspace_id AND ew.status != 'revoked'
     JOIN users u ON u.id = ew.owner_user_id
     WHERE LOWER(i.email) = ${context.user.email.trim().toLowerCase()} AND i.status = 'pending' AND i.expires_at > ${new Date().toISOString()}
     ORDER BY i.created_at DESC`;
  return json({ invitations: rows });
}

/**
 * Accept an invitation as the invited email. Single use. Creates only the
 * Person Grant; when the Workspace has no default policy the person starts
 * with chat-only access to no Workers, so the owner must choose what to share.
 */
export async function handleAcceptWorkspaceInvitation(
  request: Request,
  env: SecurityEnv,
  invitationId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method !== "POST") throw new HttpError(405, "Unsupported method");
  const invitation = await dataOf(env).read.row<{
      id: string;
      workspaceId: string;
      email: string;
      status: string;
      expiresAt: string;
      invitedBy: string;
      ownerId: string;
      acceptedBy: string | null;
    }>`SELECT i.id, i.workspace_id AS "workspaceId", i.email, i.status, i.expires_at AS "expiresAt",
            i.invited_by_user_id AS "invitedBy", ew.owner_user_id AS "ownerId",
            i.accepted_by_user_id AS "acceptedBy"
     FROM workspace_invitations i
     JOIN execution_workspaces ew ON ew.id = i.workspace_id AND ew.status != 'revoked'
     WHERE i.id = ${invitationId}`;
  // A retried accept by the same person repeats the first result.
  if (
    invitation?.status === "accepted" &&
    invitation.acceptedBy === context.userId
  )
    return json({ workspaceId: invitation.workspaceId, status: "active" });
  if (!invitation || invitation.status !== "pending")
    throw new HttpError(404, "Workspace invitation not found");
  if (new Date(invitation.expiresAt).getTime() <= Date.now())
    throw new HttpError(410, "Workspace invitation expired");
  if (
    context.user.email.trim().toLowerCase() !==
    invitation.email.trim().toLowerCase()
  )
    throw new HttpError(
      403,
      "Invitation recipient does not match signed-in user",
    );
  // The inviter must still own the Workspace.
  if (invitation.ownerId !== invitation.invitedBy)
    throw new HttpError(403, "The inviter can no longer lend this Workspace");
  if (invitation.ownerId === context.userId)
    throw new HttpError(400, "You already own this Workspace");
  // Pending invitations lapse with the owner's plan. The invitee cannot fix
  // this by upgrading, so this is a plain 403, not paid_plan_required.
  if (!(await hasPaidFeature(env, invitation.ownerId, "workspace.sharing")))
    throw new HttpError(403, "This Workspace can no longer be shared");
  const now = new Date().toISOString();
  const results = await env.SYNTILA_DB.batch([
    env.SYNTILA_DB.prepare(
      "UPDATE workspace_invitations SET status='accepted',accepted_by_user_id=?1,accepted_at=?2,updated_at=?2 WHERE id=?3 AND status='pending' AND expires_at>?2",
    ).bind(context.userId, now, invitation.id),
    env.SYNTILA_DB.prepare(
      `INSERT INTO workspace_person_grants(workspace_id,user_id,granted_by_user_id,status,created_at,updated_at)
       SELECT ?1,?2,?3,'active',?4,?4 WHERE EXISTS (SELECT 1 FROM workspace_invitations WHERE id=?5 AND status='accepted' AND accepted_by_user_id=?2 AND accepted_at=?4)
       ON CONFLICT(workspace_id,user_id) DO UPDATE SET status='active',granted_by_user_id=excluded.granted_by_user_id,updated_at=excluded.updated_at`,
    ).bind(
      invitation.workspaceId,
      context.userId,
      invitation.ownerId,
      now,
      invitation.id,
    ),
    env.SYNTILA_DB.prepare(
      `INSERT INTO workspace_audit_log(id,workspace_id,actor_type,actor_id,action,target_type,target_id,details_json,created_at)
       SELECT ?1,?2,'user',?3,'workspace.person_grant.created','user',?3,'{}',?4
       WHERE EXISTS (SELECT 1 FROM workspace_person_grants WHERE workspace_id=?2 AND user_id=?3 AND updated_at=?4)`,
    ).bind(crypto.randomUUID(), invitation.workspaceId, context.userId, now),
  ]);
  if (!results[0]?.meta?.changes)
    throw new HttpError(409, "Workspace invitation is no longer pending");
  await publishWorkspaceInvitationChanged(env, invitation.id, [
    invitation.ownerId,
    context.userId,
  ]);
  return json({ workspaceId: invitation.workspaceId, status: "active" });
}

/**
 * End a person's grant: the owner revokes anyone, and a borrower may revoke
 * their own grant with person id "me". They lose access at their next request,
 * and every Space grant their Spaces hold on this Workspace is revoked so the
 * scheduler stops dispatching to it.
 */
export async function handleRevokePersonGrant(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  personId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (personId === "me") personId = context.userId;
  else await ownedWorkspace(env, workspaceId, context.userId);
  if (request.method !== "POST") throw new HttpError(405, "Unsupported method");
  const now = new Date().toISOString();
  const results = await env.SYNTILA_DB.batch([
    env.SYNTILA_DB.prepare(
      "UPDATE workspace_person_grants SET status='revoked',updated_at=?3 WHERE workspace_id=?1 AND user_id=?2 AND status='active'",
    ).bind(workspaceId, personId, now),
    env.SYNTILA_DB.prepare(
      `UPDATE workspace_space_grants SET status='revoked',updated_at=?3
       WHERE workspace_id=?1 AND status IN ('active','suspended')
         AND space_id IN (SELECT id FROM spaces WHERE owner_user_id=?2)`,
    ).bind(workspaceId, personId, now),
    env.SYNTILA_DB.prepare(
      `INSERT INTO workspace_audit_log(id,workspace_id,actor_type,actor_id,action,target_type,target_id,details_json,created_at)
       SELECT ?1,?2,'user',?3,'workspace.person_grant.revoked','user',?4,'{}',?5
       WHERE EXISTS (SELECT 1 FROM workspace_person_grants WHERE workspace_id=?2 AND user_id=?4 AND status='revoked' AND updated_at=?5)`,
    ).bind(crypto.randomUUID(), workspaceId, context.userId, personId, now),
  ]);
  if (!results[0]?.meta?.changes)
    throw new HttpError(404, "Active grant not found");
  return json({ revoked: true });
}

/**
 * Owner-only: set a borrower's concurrent request limit (1-10) on this
 * Workspace. Enforced when a request is admitted.
 */
export async function handlePersonGrantQuota(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  personId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await ownedWorkspace(env, workspaceId, context.userId);
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");
  const body = await readBody(request, PersonGrantQuotaSchema, {
    message:
      "maxConcurrentRequests must be 1-10 and maxRunSecondsPerMonth null or 60 to 2678400",
  });
  const limit = body.maxConcurrentRequests;
  const runSeconds = body.maxRunSecondsPerMonth;
  const updated = await dataOf(env).read.run`UPDATE workspace_person_grants
        SET max_concurrent_requests = COALESCE(${limit ?? null}, max_concurrent_requests),
            max_run_seconds_per_month = CASE WHEN ${runSeconds === undefined ? 0 : 1} = 1 THEN ${runSeconds ?? null} ELSE max_run_seconds_per_month END,
            updated_at = ${new Date().toISOString()}
      WHERE workspace_id=${workspaceId} AND user_id=${personId} AND status='active'`;
  if (!updated)
    throw new HttpError(404, "Active grant not found");
  return json({
    ...(limit !== undefined ? { maxConcurrentRequests: limit } : {}),
    ...(runSeconds !== undefined ? { maxRunSecondsPerMonth: runSeconds } : {}),
  });
}

/**
 * Decline an invitation as the invited email. The status schema has no
 * "declined" value, so the invitation is closed as revoked; the owner may
 * invite the person again.
 */
export async function handleDeclineWorkspaceInvitation(
  request: Request,
  env: SecurityEnv,
  invitationId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method !== "POST") throw new HttpError(405, "Unsupported method");
  const now = new Date().toISOString();
  const result = await dataOf(env).read.run`UPDATE workspace_invitations SET status='revoked',updated_at=${now} WHERE id=${invitationId} AND status='pending' AND LOWER(email)=${context.user.email.trim().toLowerCase()}`;
  if (!result) {
    // A retried decline: the invitation is already closed for this person.
    const closed = await dataOf(env).read.row`SELECT 1 AS found FROM workspace_invitations WHERE id=${invitationId} AND status='revoked' AND LOWER(email)=${context.user.email.trim().toLowerCase()}`;
    if (closed) return json({ status: "declined" });
    throw new HttpError(404, "Workspace invitation not found");
  }
  const owner = await dataOf(env).read.row<{ userId: string }>`SELECT invited_by_user_id AS "userId" FROM workspace_invitations WHERE id = ${invitationId}`;
  await publishWorkspaceInvitationChanged(env, invitationId, [
    owner?.userId,
    context.userId,
  ]);
  return json({ status: "declined" });
}
