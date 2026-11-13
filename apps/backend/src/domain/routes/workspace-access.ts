import { publishCollaborationEvent } from "../collaboration-events.js";
import {
  authorizeWorkspaceOwner,
  type SecurityContext,
} from "@syntila/security";
import {
  DEFAULT_SPACE_MAX_CONCURRENT_ASSIGNMENTS,
  validateWorkspaceConcurrencyPolicy,
  validateWorkspaceGrantPermissions,
  validateWorkspaceGrantWorkerIds,
  validateWorkspaceNetworkPolicy,
} from "@syntila/core";

import type { SecurityEnv } from "./http-security.js";
import { parseJson, recordAudit } from "./http-security.js";

import { HttpError, json } from "./http-security.js";

export async function disconnectWorkspaceRuntime(
  env: SecurityEnv,
  workspaceId: string,
  runtimeId: string,
): Promise<boolean> {
  const gateway = env.SYNTILA_WORKSPACE_GATEWAY;
  if (!gateway) return false;
  try {
    const response = await gateway
      .getByName(workspaceId)
      .fetch("https://workspace-gateway/disconnect-runtime", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ runtimeId }),
      });
    if (!response.ok) return false;
    return response.ok;
  } catch {
    return false;
  }
}

export async function getWorkspaceGatewayStatus(
  env: SecurityEnv,
  workspaceId: string,
): Promise<{ online: boolean } | null> {
  const gateway = env.SYNTILA_WORKSPACE_GATEWAY;
  if (!gateway) return null;
  try {
    const response = await gateway
      .getByName(workspaceId)
      .fetch("https://workspace-gateway/status");
    if (!response.ok) return null;
    const status = (await response.json()) as { online?: unknown };
    if (typeof status.online !== "boolean") return null;
    return { online: status.online };
  } catch {
    return null;
  }
}

export function workspaceSpaceGrantMetadata(
  row: Record<string, unknown>,
): Record<string, unknown> {
  return {
    id: String(row.id),
    spaceId: String(row.space_id),
    workspaceId: String(row.workspace_id),
    workspaceName:
      row.workspace_name == null ? null : String(row.workspace_name),
    workspaceOwnerUserId:
      row.owner_user_id == null ? null : String(row.owner_user_id),
    grantedByUserId: String(row.granted_by_user_id),
    status: String(row.status),
    allowedWorkerIds: parseJson(row.allowed_worker_ids_json, []),
    allowedPermissions: parseJson(row.allowed_permissions_json, []),
    networkPolicy: parseJson(row.network_policy_json, {}),
    concurrency: parseJson(row.concurrency_json, {}),
    expiresAt: row.expires_at ?? null,
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export async function loadWorkspaceSpaceGrant(
  env: SecurityEnv,
  grantId: string,
): Promise<Record<string, unknown> | null> {
  return env.SYNTILA_DB.prepare(
    `SELECT g.*, ew.name AS workspace_name, ew.owner_user_id
     FROM workspace_space_grants g
     JOIN execution_workspaces ew ON ew.id = g.workspace_id
     WHERE g.id = ?1`,
  )
    .bind(grantId)
    .first<Record<string, unknown>>();
}

export function grantStringArray(value: unknown, field: string): string {
  if (value === undefined) return "[]";
  const valid = validateWorkspaceGrantWorkerIds(value);
  if (!valid) {
    throw new HttpError(400, `${field} contains invalid or duplicate values`);
  }
  return JSON.stringify(value);
}

export function grantExecutionPermissions(value: unknown): string {
  if (value === undefined) return "[]";
  if (!validateWorkspaceGrantPermissions(value)) {
    throw new HttpError(
      400,
      "allowedPermissions contains invalid or duplicate permissions",
    );
  }
  return JSON.stringify(value);
}

function recordBody(
  value: unknown,
  allowedKeys: readonly string[],
): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "Request body must be an object");
  }
  const body = value as Record<string, unknown>;
  if (Object.keys(body).some((key) => !allowedKeys.includes(key))) {
    throw new HttpError(400, "Request body contains unsupported fields");
  }
  return body;
}

export function grantExpiry(value: unknown, now: Date): string | null {
  if (value === undefined || value === null) return null;
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(
      value,
    )
  ) {
    throw new HttpError(400, "expiresAt must be a valid timestamp or null");
  }
  const timestamp = Date.parse(value);
  if (
    !Number.isFinite(timestamp) ||
    new Date(`${value.slice(0, 10)}T00:00:00.000Z`)
      .toISOString()
      .slice(0, 10) !== value.slice(0, 10) ||
    timestamp <= now.getTime()
  ) {
    throw new HttpError(400, "expiresAt must be in the future");
  }
  return new Date(timestamp).toISOString();
}

export async function createWorkspaceSpaceGrant(
  request: Request,
  env: SecurityEnv,
  context: SecurityContext,
  spaceId: string,
  workspaceId: string,
): Promise<Response> {
  const body = recordBody(await request.json().catch(() => null), [
    "allowedWorkerIds",
    "allowedPermissions",
    "networkPolicy",
    "concurrency",
    "expiresAt",
    "confirmContribution",
    "workspaceId",
  ]);
  if (
    body.confirmContribution !== undefined &&
    typeof body.confirmContribution !== "boolean"
  ) {
    throw new HttpError(400, "confirmContribution must be a boolean");
  }
  if (body.workspaceId !== undefined && body.workspaceId !== workspaceId) {
    throw new HttpError(400, "workspaceId does not match the grant target");
  }
  const space = await env.SYNTILA_DB.prepare(
    "SELECT id FROM spaces WHERE id = ?1",
  )
    .bind(spaceId)
    .first<{ id: string }>();
  if (!space) throw new HttpError(404, "Space not found");
  const workspace = await env.SYNTILA_DB.prepare(
    "SELECT id, owner_user_id, status FROM execution_workspaces WHERE id = ?1",
  )
    .bind(workspaceId)
    .first<{ id: string; owner_user_id: string; status: string }>();
  if (!workspace) throw new HttpError(404, "Workspace not found");
  if (
    workspace.owner_user_id !== context.userId ||
    workspace.status === "revoked"
  ) {
    throw new HttpError(
      403,
      "Only the Workspace owner can grant this Workspace",
    );
  }
  const rawMembership = await env.SYNTILA_DB.prepare(
    "SELECT role FROM space_memberships WHERE space_id = ?1 AND user_id = ?2",
  )
    .bind(spaceId, context.userId)
    .first<{ role: string }>();
  const membership = rawMembership;
  if (!membership && body.confirmContribution !== true) {
    throw new HttpError(
      403,
      "Workspace contribution must be explicitly authorized",
    );
  }
  await authorizeWorkspaceOwner(
    env.SYNTILA_DB,
    context,
    workspaceId,
    "workspace:manage",
  );
  const existingGrant = await env.SYNTILA_DB.prepare(
    `SELECT id FROM workspace_space_grants
     WHERE space_id = ?1 AND workspace_id = ?2
       AND status IN ('active', 'suspended')
     LIMIT 1`,
  )
    .bind(spaceId, workspaceId)
    .first<{ id: string }>();
  if (existingGrant) {
    throw new HttpError(
      409,
      "This Workspace is already connected to the Space",
    );
  }
  if (membership?.role !== "owner" && body.confirmContribution !== true) {
    throw new HttpError(
      400,
      "Collaborators must explicitly confirm Workspace contribution",
    );
  }
  const workerIdsValue =
    body.allowedWorkerIds === undefined ? [] : body.allowedWorkerIds;
  if (!validateWorkspaceGrantWorkerIds(workerIdsValue)) {
    throw new HttpError(
      400,
      "allowedWorkerIds contains invalid or duplicate Worker IDs",
    );
  }
  const allowedWorkerIds = JSON.stringify(workerIdsValue);
  if (workerIdsValue.length > 0) {
    const placeholders = workerIdsValue.map((_, index) => `?${index + 2}`);
    const rows = await env.SYNTILA_DB.prepare(
      `SELECT worker_id FROM workspace_worker_inventory
       WHERE workspace_id = ?1 AND worker_id IN (${placeholders.join(", ")})`,
    )
      .bind(workspaceId, ...workerIdsValue)
      .all<{ worker_id: string }>();
    const found = new Set((rows.results ?? []).map((row) => row.worker_id));
    if (workerIdsValue.some((workerId) => !found.has(workerId))) {
      throw new HttpError(
        400,
        "allowedWorkerIds must identify Workers on this Workspace",
      );
    }
  }
  const now = new Date().toISOString();
  const allowedPermissions = grantExecutionPermissions(body.allowedPermissions);
  const networkPolicyValue =
    body.networkPolicy === undefined
      ? { mode: "deny_all", allowedHosts: [] }
      : body.networkPolicy;
  if (!validateWorkspaceNetworkPolicy(networkPolicyValue)) {
    throw new HttpError(400, "networkPolicy is invalid");
  }
  const networkPolicy = JSON.stringify(networkPolicyValue);
  const concurrencyValue =
    body.concurrency === undefined
      ? { maxConcurrentAssignments: DEFAULT_SPACE_MAX_CONCURRENT_ASSIGNMENTS }
      : body.concurrency;
  if (!validateWorkspaceConcurrencyPolicy(concurrencyValue)) {
    throw new HttpError(400, "concurrency is invalid");
  }
  const concurrency = JSON.stringify(concurrencyValue);
  const expiresAt = grantExpiry(body.expiresAt, new Date(now));
  const id = `workspace-space-grant-${crypto.randomUUID().slice(0, 16)}`;
  await env.SYNTILA_DB.prepare(
    `INSERT INTO workspace_space_grants
       (id, space_id, workspace_id, granted_by_user_id, status,
        allowed_worker_ids_json, allowed_permissions_json,
        network_policy_json, concurrency_json,
        expires_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, 'active', ?5, ?6, ?7, ?8, ?9, ?10, ?10)
     ON CONFLICT(id, space_id, workspace_id) DO NOTHING`,
  )
    .bind(
      id,
      spaceId,
      workspaceId,
      context.userId,
      allowedWorkerIds,
      allowedPermissions,
      networkPolicy,
      concurrency,
      expiresAt,
      now,
    )
    .run();
  await recordAudit(
    env,
    context,
    "workspace.space_grant.created",
    "workspace_space_grant",
    id,
    {
      spaceId,
      workspaceId,
    },
  );
  await publishCollaborationEvent(
    env,
    "workspace_space_grant.updated",
    spaceId,
    id,
    { additionalRecipientUserIds: [context.userId] },
  );
  const grant = await loadWorkspaceSpaceGrant(env, id);
  return json(
    {
      grant: grant
        ? workspaceSpaceGrantMetadata(grant)
        : { id, spaceId, workspaceId },
    },
    { status: 201 },
  );
}
