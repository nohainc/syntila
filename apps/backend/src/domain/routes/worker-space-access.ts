import { dataOf } from "../../platform/data.js";
import { requirePaidFeature } from "../account-plan.js";
import { isFeatureEnabled } from "../../feature-flags.js";
import { HttpError, json, securityContext } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { readJson } from "./validation.js";
import { parseModelAccess, type WorkerSpaceModelAccess } from "../worker-eligibility.js";
/** What a Space member may do with a shared Worker (ADR-042). */
export const WORKER_ACCESS_MODES = ["chat", "work", "work+shell"] as const;
export type WorkerAccessMode = (typeof WORKER_ACCESS_MODES)[number];

const MAX_MEMBERS = 200;
const MAX_MODEL_ENTRIES = 500;

export interface WorkerSpaceMemberPermissions {
  readonly mode: WorkerAccessMode;
}

export interface WorkerSpaceMemberAccessEntry {
  readonly userId: string;
  readonly displayName: string;
  readonly email: string;
  readonly role: string;
  readonly enabled: boolean;
  readonly permissions: WorkerSpaceMemberPermissions;
}

function parsePermissions(raw: unknown): WorkerSpaceMemberPermissions {
  if (typeof raw === "string") {
    try {
      return parsePermissions(JSON.parse(raw));
    } catch {
      return { mode: "chat" };
    }
  }
  if (raw && typeof raw === "object" && !Array.isArray(raw)) {
    const mode = (raw as { mode?: unknown }).mode;
    if (typeof mode === "string" && WORKER_ACCESS_MODES.includes(mode as WorkerAccessMode)) {
      return { mode: mode as WorkerAccessMode };
    }
  }
  return { mode: "chat" };
}

function validatePutPermissions(raw: unknown): WorkerSpaceMemberPermissions {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new HttpError(400, "permissions must be an object");
  }
  const obj = raw as Record<string, unknown>;
  const keys = Object.keys(obj);
  if (keys.some((k) => k !== "mode")) {
    throw new HttpError(400, "Unknown permissions field");
  }
  if (typeof obj.mode !== "string" || !WORKER_ACCESS_MODES.includes(obj.mode as WorkerAccessMode)) {
    throw new HttpError(400, "permissions.mode must be chat, work or work+shell");
  }
  return { mode: obj.mode as WorkerAccessMode };
}

function validateModelAccess(raw: unknown): WorkerSpaceModelAccess {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new HttpError(400, "modelAccess must be an object");
  const obj = raw as Record<string, unknown>;
  if (Object.keys(obj).some((k) => k !== "allowedModels" && k !== "allowedEfforts")) {
    throw new HttpError(400, "Unknown modelAccess field");
  }
  if (obj.allowedModels !== undefined && !Array.isArray(obj.allowedModels)) {
    throw new HttpError(400, "modelAccess.allowedModels must be an array");
  }
  const efforts = obj.allowedEfforts ?? {};
  if (!efforts || typeof efforts !== "object" || Array.isArray(efforts)) {
    throw new HttpError(400, "modelAccess.allowedEfforts must be an object");
  }
  const parsed = parseModelAccess(obj.allowedModels ?? [], efforts);
  if (parsed.allowedModels.length + Object.keys(parsed.allowedEfforts).length > MAX_MODEL_ENTRIES) {
    throw new HttpError(400, "Too many model entries");
  }
  return parsed;
}

async function readModelAccess(env: SecurityEnv, workerId: string): Promise<WorkerSpaceModelAccess> {
  const row = await dataOf(env).read.row<{ models: string; efforts: string }>`
    SELECT allowed_models_json AS models, allowed_efforts_json AS efforts
      FROM worker_member_model_access WHERE worker_id = ${workerId}`;
  return parseModelAccess(row?.models, row?.efforts);
}

async function requireOwnedActiveWorker(env: SecurityEnv, userId: string, workerId: string): Promise<void> {
  const q = dataOf(env).read;
  const worker = await q.row<{ ownerUserId: string; revokedAt: string | null }>`
    SELECT owner_user_id AS "ownerUserId", revoked_at AS "revokedAt"
      FROM worker_instances
     WHERE id = ${workerId}`;
  if (!worker) throw new HttpError(404, "Worker not found");
  if (worker.ownerUserId !== userId) {
    throw new HttpError(403, "Only the Worker owner can manage Space member access");
  }
  if (worker.revokedAt !== null) {
    throw new HttpError(409, "A removed Worker cannot change");
  }
}

async function requireSpaceManageAccess(env: SecurityEnv, userId: string, spaceId: string): Promise<void> {
  const q = dataOf(env).read;
  const space = await q.row<{ id: string }>`SELECT id FROM spaces WHERE id = ${spaceId}`;
  if (!space) throw new HttpError(404, "Space not found");
  const membership = await q.row<{ role: string }>`
    SELECT role FROM space_memberships WHERE space_id = ${spaceId} AND user_id = ${userId}`;
  if (!membership || (membership.role !== "owner" && membership.role !== "collaborator")) {
    throw new HttpError(403, "You do not have permission to manage Worker access in this Space");
  }
}

async function readSpaceAccess(
  env: SecurityEnv,
  workerId: string,
  spaceId: string,
): Promise<WorkerSpaceMemberAccessEntry[]> {
  const q = dataOf(env).read;
  const rows = await q.rows<{
    userId: string;
    displayName: string;
    email: string;
    role: string;
    enabled: boolean | null;
    permissionsJson: string | null;
  }>`
    SELECT sm.user_id AS "userId",
           u.display_name AS "displayName",
           u.email,
           sm.role,
           wsm.enabled,
           wsm.permissions_json AS "permissionsJson"
      FROM space_memberships sm
      JOIN users u ON u.id = sm.user_id
      LEFT JOIN worker_space_members wsm
        ON wsm.worker_id = ${workerId}
       AND wsm.space_id = sm.space_id
       AND wsm.user_id = sm.user_id
     WHERE sm.space_id = ${spaceId}
       AND u.status = 'active'
     ORDER BY CASE sm.role WHEN 'owner' THEN 0 WHEN 'collaborator' THEN 1 ELSE 2 END, u.display_name, sm.user_id`;

  return rows.map((row) => ({
    userId: String(row.userId),
    displayName: String(row.displayName),
    email: String(row.email),
    role: String(row.role),
    enabled: row.enabled === true,
    permissions: parsePermissions(row.permissionsJson),
  }));
}

/**
 * GET, PUT /api/workers/:workerId/space-access?spaceId=...
 * Owner-only read and replace of per-Space member access for a Worker Instance (ADR-042).
 */
export async function handleWorkerSpaceAccess(
  request: Request,
  env: SecurityEnv,
  workerId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  await requireOwnedActiveWorker(env, context.userId, workerId);

  if (request.method === "GET") {
    const spaceId = new URL(request.url).searchParams.get("spaceId")?.trim() ?? "";
    if (!spaceId) throw new HttpError(400, "spaceId query parameter is required");
    await requireSpaceManageAccess(env, context.userId, spaceId);
    const members = await readSpaceAccess(env, workerId, spaceId);
    return json({ workerId, spaceId, members });
  }

  if (request.method !== "PUT") throw new HttpError(405, "Method not allowed");

  const body = (await readJson(request)) as {
    spaceId?: unknown;
    members?: unknown;
  };
  const spaceId = typeof body?.spaceId === "string" ? body.spaceId.trim() : "";
  if (!spaceId) throw new HttpError(400, "spaceId is required");
  await requireSpaceManageAccess(env, context.userId, spaceId);

  if (!Array.isArray(body.members)) {
    throw new HttpError(400, "members must be an array");
  }
  if (body.members.length > MAX_MEMBERS) {
    throw new HttpError(400, `At most ${MAX_MEMBERS} members may be configured at once`);
  }

  const normalized: Array<{
    userId: string;
    enabled: boolean;
    permissions: WorkerSpaceMemberPermissions;
  }> = [];
  const seenUserIds = new Set<string>();

  for (const item of body.members) {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new HttpError(400, "Invalid member entry");
    }
    const entry = item as Record<string, unknown>;
    const userId = typeof entry.userId === "string" ? entry.userId.trim() : "";
    if (!userId) throw new HttpError(400, "Each member entry requires userId");
    if (seenUserIds.has(userId)) {
      throw new HttpError(400, `Duplicate userId: ${userId}`);
    }
    seenUserIds.add(userId);
    if (typeof entry.enabled !== "boolean") {
      throw new HttpError(400, `enabled must be a boolean for user ${userId}`);
    }
    const permissions = validatePutPermissions(entry.permissions);
    normalized.push({ userId, enabled: entry.enabled, permissions });
  }

  // Sharing a Worker is a Plus feature; turning access off stays free.
  if (normalized.some((entry) => entry.enabled)) {
    await requirePaidFeature(env as unknown as Env, context.userId, "worker.sharing");
  }

  const q = dataOf(env).read;
  if (normalized.length > 0) {
    const memberRows = await q.rows<{ userId: string }>`
      SELECT sm.user_id AS "userId"
        FROM space_memberships sm
        JOIN users u ON u.id = sm.user_id
       WHERE sm.space_id = ${spaceId}
         AND u.status = 'active'`;
    const validMembers = new Set(memberRows.map((r) => String(r.userId)));
    const invalid = normalized.filter((m) => !validMembers.has(m.userId)).map((m) => m.userId);
    if (invalid.length > 0) {
      throw new HttpError(422, `Users are not active members of this Space: ${invalid.join(", ")}`);
    }
  }

  await dataOf(env).tx("worker.space_access.put", async (tx) => {
    await tx.run`DELETE FROM worker_space_members
      WHERE worker_id = ${workerId} AND space_id = ${spaceId}`;
    for (const entry of normalized) {
      await tx.run`INSERT INTO worker_space_members
          (worker_id, space_id, user_id, enabled, permissions_json)
        VALUES (${workerId}, ${spaceId}, ${entry.userId}, ${entry.enabled}, ${JSON.stringify(entry.permissions)})`;
    }
  });

  const members = await readSpaceAccess(env, workerId, spaceId);
  return json({ workerId, spaceId, members });
}

/**
 * GET, PUT /api/workers/:workerId/member-model-access
 * Owner-only. One allow-list of models and efforts that applies to every
 * non-owner member of every Space the Worker is shared with (ADR-042).
 */
export async function handleWorkerMemberModelAccess(
  request: Request,
  env: SecurityEnv,
  workerId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  await requireOwnedActiveWorker(env, context.userId, workerId);
  if (request.method === "GET") return json({ workerId, modelAccess: await readModelAccess(env, workerId) });
  if (request.method !== "PUT") throw new HttpError(405, "Method not allowed");
  const body = (await readJson(request)) as { modelAccess?: unknown };
  const modelAccess = validateModelAccess(body?.modelAccess);
  const q = dataOf(env).read;
  if (modelAccess.allowedModels.length === 0 && Object.keys(modelAccess.allowedEfforts).length === 0) {
    await q.run`DELETE FROM worker_member_model_access WHERE worker_id = ${workerId}`;
  } else {
    await q.run`INSERT INTO worker_member_model_access (worker_id, allowed_models_json, allowed_efforts_json)
      VALUES (${workerId}, ${JSON.stringify(modelAccess.allowedModels)}, ${JSON.stringify(modelAccess.allowedEfforts)})
      ON CONFLICT (worker_id) DO UPDATE
        SET allowed_models_json = EXCLUDED.allowed_models_json,
            allowed_efforts_json = EXCLUDED.allowed_efforts_json,
            updated_at = now()`;
  }
  return json({ workerId, modelAccess: await readModelAccess(env, workerId) });
}

export interface WorkerPersonShareEntry {
  readonly userId: string;
  readonly displayName: string;
  readonly email: string;
  readonly maxConcurrentRequests: number;
  readonly maxRunSecondsPerMonth: number | null;
}

async function readPersonShares(env: SecurityEnv, workerId: string): Promise<WorkerPersonShareEntry[]> {
  const rows = await dataOf(env).read.rows<{
    userId: string; displayName: string; email: string; maxConcurrent: number; maxRunSeconds: number | null;
  }>`SELECT s.user_id AS "userId", u.display_name AS "displayName", u.email,
            s.max_concurrent_requests AS "maxConcurrent", s.max_run_seconds_per_month AS "maxRunSeconds"
       FROM worker_person_shares s JOIN users u ON u.id = s.user_id
      WHERE s.worker_id = ${workerId}
      ORDER BY u.display_name, s.user_id`;
  return rows.map((row) => ({
    userId: String(row.userId),
    displayName: String(row.displayName),
    email: String(row.email),
    maxConcurrentRequests: Number(row.maxConcurrent),
    maxRunSecondsPerMonth: row.maxRunSeconds == null ? null : Number(row.maxRunSeconds),
  }));
}

/**
 * GET, PUT, DELETE /api/workers/:workerId/person-shares (ADR-043).
 * Owner only. A Person Share lets one person from the owner's People use the
 * Worker for Chat in their own Spaces and personal Threads. PUT adds or
 * updates one share: `{ userId, maxConcurrentRequests?, maxRunSecondsPerMonth? }`;
 * DELETE `?userId=` revokes it. Models and efforts follow the Worker's
 * member allow-list.
 */
export async function handleWorkerPersonShares(
  request: Request,
  env: SecurityEnv,
  workerId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  await requireOwnedActiveWorker(env, context.userId, workerId);
  const q = dataOf(env).read;
  if (request.method === "GET") return json({ workerId, shares: await readPersonShares(env, workerId) });
  if (request.method === "DELETE") {
    const userId = new URL(request.url).searchParams.get("userId")?.trim() ?? "";
    if (!userId) throw new HttpError(400, "userId query parameter is required");
    await q.run`DELETE FROM worker_person_shares WHERE worker_id = ${workerId} AND user_id = ${userId}`;
    return json({ workerId, shares: await readPersonShares(env, workerId) });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Method not allowed");
  const body = (await readJson(request)) as Record<string, unknown> | null;
  if (!body || typeof body !== "object" || Array.isArray(body)) throw new HttpError(400, "Body must be an object");
  if (Object.keys(body).some((k) => !["userId", "maxConcurrentRequests", "maxRunSecondsPerMonth"].includes(k))) {
    throw new HttpError(400, "Unknown share field");
  }
  const userId = typeof body.userId === "string" ? body.userId.trim() : "";
  if (!userId) throw new HttpError(400, "userId is required");
  if (userId === context.userId) throw new HttpError(400, "You already own this Worker");
  // Sharing a Worker is a Plus feature; revoking a share stays free.
  await requirePaidFeature(env as unknown as Env, context.userId, "worker.sharing");
  const maxConcurrent = body.maxConcurrentRequests ?? 1;
  if (!Number.isInteger(maxConcurrent) || (maxConcurrent as number) < 1 || (maxConcurrent as number) > 10) {
    throw new HttpError(400, "maxConcurrentRequests must be a whole number from 1 to 10");
  }
  const maxRunSeconds = body.maxRunSecondsPerMonth ?? null;
  if (maxRunSeconds !== null && (!Number.isInteger(maxRunSeconds) || (maxRunSeconds as number) < 1)) {
    throw new HttpError(400, "maxRunSecondsPerMonth must be a positive whole number or null");
  }
  // Only someone already in the owner's People can be chosen.
  const [low, high] = context.userId < userId ? [context.userId, userId] : [userId, context.userId];
  const peer = await q.row<{ ok: number }>`SELECT 1 AS ok FROM people_relationships
      WHERE user_low_id = ${low} AND user_high_id = ${high}
     UNION ALL SELECT 1 AS ok FROM person_connections
      WHERE user_low_id = ${low} AND user_high_id = ${high} AND status = 'connected'
     LIMIT 1`;
  if (!peer) {
    throw new HttpError(422, "Choose a person from your People");
  }
  await q.run`INSERT INTO worker_person_shares (worker_id, user_id, max_concurrent_requests, max_run_seconds_per_month)
    VALUES (${workerId}, ${userId}, ${maxConcurrent as number}, ${maxRunSeconds as number | null})
    ON CONFLICT (worker_id, user_id) DO UPDATE
      SET max_concurrent_requests = EXCLUDED.max_concurrent_requests,
          max_run_seconds_per_month = EXCLUDED.max_run_seconds_per_month,
          updated_at = now()`;
  return json({ workerId, shares: await readPersonShares(env, workerId) });
}
