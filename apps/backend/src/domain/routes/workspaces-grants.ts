import { dataOf } from "../../platform/data.js";
import { WorkspaceGrantUpdateSchema } from "@syntila/protocol";
import { readBody } from "./validation.js";
import { publishCollaborationEvent } from "../collaboration-events.js";
import { revokeAssignment } from "../assignment-revocation.js";
import { ACTIVE_ASSIGNMENT_STATUS_SQL } from "../assignment-transitions.js";
import {
  canTransitionWorkspaceSpaceGrantStatus,
  isWorkspaceSpaceGrantStatus,
} from "@syntila/core";

import {
  authorizeWorkspaceOwner,
  authorizeSpaceOwner,
} from "@syntila/security";

import {
  HttpError,
  createWorkspaceSpaceGrant,
  grantExpiry,
  grantExecutionPermissions,
  json,
  loadWorkspaceSpaceGrant,
  recordAudit,
  securityContext,
  workspaceSpaceGrantMetadata,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

export async function handleListWorkspaceSpaceGrants(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await authorizeWorkspaceOwner(
    env.SYNTILA_DB,
    context,
    workspaceId,
    "workspace:manage",
  );
  const rows = await dataOf(env).read.rows<Record<string, unknown>>`SELECT g.*, ew.name AS workspace_name, ew.owner_user_id
     FROM workspace_space_grants g JOIN execution_workspaces ew ON ew.id = g.workspace_id
     WHERE g.workspace_id = ${workspaceId} ORDER BY g.created_at DESC`;
  return json({
    grants: rows.map(workspaceSpaceGrantMetadata),
  });
}

export async function handleCreateWorkspaceSpaceGrant(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  spaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  return createWorkspaceSpaceGrant(request, env, context, spaceId, workspaceId);
}

export async function handleUpdateWorkspaceSpaceGrant(
  request: Request,
  env: SecurityEnv,
  grantId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const existing = await loadWorkspaceSpaceGrant(env, grantId);
  if (!existing) throw new HttpError(404, "Workspace Space Grant not found");
  await authorizeWorkspaceOwner(
    env.SYNTILA_DB,
    context,
    String(existing.workspace_id),
    "workspace:manage",
  );
  const body = await readBody(request, WorkspaceGrantUpdateSchema);
  if (
    Object.keys(body).length === 0 ||
    Object.keys(body).some(
      (key) => !["status", "expiresAt", "allowedPermissions"].includes(key),
    )
  ) {
    throw new HttpError(400, "Workspace Grant update fields are invalid");
  }
  const existingStatus = existing.status;
  if (!isWorkspaceSpaceGrantStatus(existingStatus)) {
    throw new HttpError(409, "Workspace Grant has an invalid stored status");
  }
  let status = existingStatus;
  if (body.status !== undefined) {
    if (body.status !== "active" && body.status !== "suspended") {
      throw new HttpError(400, "status must be active or suspended");
    }
    status = body.status;
    if (!canTransitionWorkspaceSpaceGrantStatus(existingStatus, status)) {
      throw new HttpError(409, "Workspace Grant status transition is invalid");
    }
  }
  const now = new Date().toISOString();
  const permissions =
    body.allowedPermissions === undefined
      ? String(existing.allowed_permissions_json)
      : grantExecutionPermissions(body.allowedPermissions);
  const expiresAt = grantExpiry(
    body.expiresAt === undefined ? existing.expires_at : body.expiresAt,
    new Date(now),
  );
  if (existingStatus !== "active" && existingStatus !== "suspended") {
    throw new HttpError(409, "Terminal Workspace Grants cannot be updated");
  }
  const updatedRow = await dataOf(env).read.run`UPDATE workspace_space_grants SET
       status = ${status}, expires_at = ${expiresAt}, updated_at = ${now}, allowed_permissions_json = ${permissions}
     WHERE id = ${grantId} AND status = ${existingStatus}`;
  if (updatedRow === 0) {
    throw new HttpError(409, "Workspace Grant changed concurrently");
  }
  await recordAudit(
    env,
    context,
    "workspace.space_grant.updated",
    "workspace_space_grant",
    grantId,
    { status, allowedPermissions: JSON.parse(permissions) },
  );
  await publishCollaborationEvent(
    env,
    "workspace_space_grant.updated",
    String(existing.space_id),
    grantId,
    { additionalRecipientUserIds: [context.userId] },
  );
  const updated = await loadWorkspaceSpaceGrant(env, grantId);
  return json({
    grant: updated ? workspaceSpaceGrantMetadata(updated) : null,
  });
}

export async function handleRevokeWorkspaceSpaceGrant(
  request: Request,
  env: SecurityEnv,
  grantId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const existing = await loadWorkspaceSpaceGrant(env, grantId);
  if (!existing) throw new HttpError(404, "Workspace Space Grant not found");
  try {
    await authorizeWorkspaceOwner(
      env.SYNTILA_DB,
      context,
      String(existing.workspace_id),
      "workspace:manage",
    );
  } catch {
    await authorizeSpaceOwner(
      env.SYNTILA_DB,
      context,
      String(existing.space_id),
    );
  }
  if (!isWorkspaceSpaceGrantStatus(existing.status)) {
    throw new HttpError(409, "Workspace Grant has an invalid stored status");
  }
  if (existing.status === "revoked") {
    await revokeGrantAssignments(env, grantId);
    return json({ ok: true, revokedAt: existing.updated_at });
  }
  if (!canTransitionWorkspaceSpaceGrantStatus(existing.status, "revoked")) {
    throw new HttpError(409, "Terminal Workspace Grants cannot be revoked");
  }
  const now = new Date().toISOString();
  const revoked = await dataOf(env).read.run`UPDATE workspace_space_grants SET status = 'revoked', updated_at = ${now} WHERE id = ${grantId} AND status = ${existing.status}`;
  if (revoked === 0) {
    const current = await loadWorkspaceSpaceGrant(env, grantId);
    if (current?.status !== "revoked") {
      throw new HttpError(409, "Workspace Grant changed concurrently");
    }
  }
  await revokeGrantAssignments(env, grantId);
  await recordAudit(
    env,
    context,
    "workspace.space_grant.revoked",
    "workspace_space_grant",
    grantId,
    { spaceId: existing.space_id, workspaceId: existing.workspace_id },
  );
  await publishCollaborationEvent(
    env,
    "workspace_space_grant.updated",
    String(existing.space_id),
    grantId,
    { additionalRecipientUserIds: [context.userId] },
  );
  return json({ ok: true, revokedAt: now });
}

async function revokeGrantAssignments(
  env: SecurityEnv,
  grantId: string,
): Promise<void> {
  const { results } = await env.SYNTILA_DB.prepare(
    `SELECT id, attempt_id FROM worker_assignments
      WHERE workspace_space_grant_id = ?1 AND status IN (${ACTIVE_ASSIGNMENT_STATUS_SQL})`,
  )
    .bind(grantId)
    .all<{ id: string; attempt_id: string | null }>();
  await Promise.all(
    (results ?? []).map((row) =>
      revokeAssignment(env, {
        assignmentId: row.id,
        attemptId: row.attempt_id ?? undefined,
        intent: {
          status: "cancelled",
          source: "grant_revoked",
          reason: "Workspace Space Grant revoked",
        },
      }),
    ),
  );
}
