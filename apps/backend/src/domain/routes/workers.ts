import {
  CreateWorkerRequestSchema,
  UpdateWorkerRequestSchema,
  type WorkerInstance,
} from "@syntila/protocol";
import { dataOf, type Row } from "../../platform/data.js";
import { FEATURE_FLAGS, isFeatureEnabled } from "../../feature-flags.js";
import { readBody } from "./validation.js";
import { HttpError, json, securityContext } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

/**
 * Worker Instances (ADR-032, phase P1): a durable, user-owned Worker with its
 * own Actor, separate from Workspaces. Owner-only: another person's Worker is
 * answered 404, never 403, so ids reveal nothing. Behind the `worker_identity`
 * flag; with the flag off the routes do not exist.
 *
 * `enabled` is configured here. `online` and `ready` are observed and read-only;
 * until Worker Agents connect on their own (P3) they are derived from the
 * Workspace the Worker was adopted from (`legacy_worker_mapping`):
 *  - ready: the inventory row's readiness state is `ready`;
 *  - online: that Workspace has an open session row with a recent heartbeat.
 *    The session row is audit history written every few minutes, so this is an
 *    approximation until sessions are first-class.
 */
const ONLINE_WINDOW = "10 minutes";

const COLUMNS = `w.id, w.actor_id AS "actorId", w.worker_type_id AS "workerTypeId",
  c.display_name AS "workerTypeName", w.name, w.description, w.enabled,
  w.default_model AS "defaultModel", w.created_at AS "createdAt",
  w.updated_at AS "updatedAt", w.revoked_at AS "revokedAt",
  (w.revoked_at IS NULL AND COALESCE(inv.readiness_state = 'ready', false)) AS ready,
  (w.revoked_at IS NULL AND EXISTS (
     SELECT 1 FROM workspace_sessions s
      WHERE s.workspace_id = inv.workspace_id AND s.disconnected_at IS NULL
        AND s.last_heartbeat_at > now() - interval '${ONLINE_WINDOW}')) AS online`;
const FROM = `worker_instances w
  JOIN worker_catalog c ON c.worker_type_id = w.worker_type_id
  LEFT JOIN legacy_worker_mapping m ON m.worker_instance_id = w.id
  LEFT JOIN workspace_worker_inventory inv ON inv.worker_id = m.legacy_worker_id`;

function requireWorkerIdentity(): void {
  if (!isFeatureEnabled("worker_identity")) throw new HttpError(404, "Not found");
}

function workerView(row: Row): WorkerInstance {
  const iso = (value: unknown) => (value instanceof Date ? value.toISOString() : String(value));
  return {
    id: String(row.id),
    actorId: String(row.actorId),
    workerTypeId: String(row.workerTypeId),
    workerTypeName: String(row.workerTypeName),
    name: String(row.name),
    description: String(row.description),
    enabled: row.enabled === true,
    online: row.online === true,
    ready: row.ready === true,
    defaultModel: row.defaultModel == null ? null : String(row.defaultModel),
    createdAt: iso(row.createdAt),
    updatedAt: iso(row.updatedAt),
    revokedAt: row.revokedAt == null ? null : iso(row.revokedAt),
  };
}

async function readWorker(env: SecurityEnv, userId: string, workerId: string): Promise<WorkerInstance> {
  const q = dataOf(env).read;
  const row = await q.row`SELECT ${q.raw(COLUMNS)} FROM ${q.raw(FROM)}
     WHERE w.id = ${workerId} AND w.owner_user_id = ${userId}`;
  if (!row) throw new HttpError(404, "Worker not found");
  return workerView(row);
}

/** GET /api/features: the rollout flags that are on. */
export async function handleListFeatures(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await securityContext(request, env, accessContext);
  return json({ flags: FEATURE_FLAGS.filter((flag) => isFeatureEnabled(flag)) });
}

/** GET /api/workers — the caller's Workers; `?includeRevoked=true` adds removed ones. */
export async function handleListWorkers(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireWorkerIdentity();
  const context = await securityContext(request, env, accessContext);
  const includeRevoked = new URL(request.url).searchParams.get("includeRevoked") === "true";
  const q = dataOf(env).read;
  const rows = await q.rows`SELECT ${q.raw(COLUMNS)} FROM ${q.raw(FROM)}
     WHERE w.owner_user_id = ${context.userId}
       AND (${includeRevoked}::boolean OR w.revoked_at IS NULL)
     ORDER BY w.created_at, w.id`;
  return json({ workers: rows.map(workerView) });
}

/** POST /api/workers — a new Worker of an existing Type. The name need not be unique. */
export async function handleCreateWorker(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireWorkerIdentity();
  const context = await securityContext(request, env, accessContext);
  const input = await readBody(request, CreateWorkerRequestSchema);
  const q = dataOf(env).read;
  const type = await q.row<{ origin: string; owner_user_id: string | null }>`
    SELECT origin, owner_user_id FROM worker_catalog
     WHERE worker_type_id = ${input.workerTypeId}
       AND lifecycle_state = 'active' AND visibility_state = 'visible'`;
  // A custom plugin Type belongs to its owner (ADR-027).
  if (!type || (type.origin === "plugin" && type.owner_user_id !== context.userId))
    throw new HttpError(422, "Unknown Worker Type");
  const id = `wrk-${crypto.randomUUID()}`;
  await q.run`INSERT INTO worker_instances
      (id, owner_user_id, worker_type_id, name, description, default_model)
    VALUES (${id}, ${context.userId}, ${input.workerTypeId}, ${input.name},
            ${input.description ?? ""}, ${input.defaultModel ?? null})`;
  return json({ worker: await readWorker(env, context.userId, id) }, { status: 201 });
}

/** GET, PATCH, DELETE /api/workers/:workerId — owner only. DELETE removes the Worker (tombstone). */
export async function handleWorker(
  request: Request,
  env: SecurityEnv,
  workerId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireWorkerIdentity();
  const context = await securityContext(request, env, accessContext);
  if (request.method === "GET")
    return json({ worker: await readWorker(env, context.userId, workerId) });
  const q = dataOf(env).read;
  if (request.method === "PATCH") {
    const input = await readBody(request, UpdateWorkerRequestSchema);
    const current = await readWorker(env, context.userId, workerId);
    if (current.revokedAt) throw new HttpError(409, "A removed Worker cannot change");
    // defaultModel: undefined keeps it, null clears it.
    await q.run`UPDATE worker_instances
         SET name = COALESCE(${input.name ?? null}::text, name),
             description = COALESCE(${input.description ?? null}::text, description),
             enabled = COALESCE(${input.enabled ?? null}::boolean, enabled),
             default_model = CASE WHEN ${input.defaultModel !== undefined}::boolean
                                  THEN ${input.defaultModel ?? null}::text ELSE default_model END,
             updated_at = now()
       WHERE id = ${workerId} AND owner_user_id = ${context.userId} AND revoked_at IS NULL`;
    return json({ worker: await readWorker(env, context.userId, workerId) });
  }
  if (request.method === "DELETE") {
    await readWorker(env, context.userId, workerId); // 404 for a stranger's or unknown id
    // Idempotent: removing a removed Worker answers the tombstone again.
    await q.run`UPDATE worker_instances
         SET revoked_at = now(), enabled = false, updated_at = now()
       WHERE id = ${workerId} AND owner_user_id = ${context.userId} AND revoked_at IS NULL`;
    return json({ worker: await readWorker(env, context.userId, workerId) });
  }
  throw new HttpError(405, "Method not allowed");
}
