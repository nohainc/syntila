import {
  CreateWorkerRequestSchema,
  UpdateWorkerRequestSchema,
  type WorkerInstance,
} from "@syntila/protocol";
import { paidOwnerSql } from "../account-plan.js";
import { dataOf, type Row } from "../../platform/data.js";
import { readBody, readJson } from "./validation.js";
import { spaceWorkerExecutionOptions } from "../worker-execution-options.js";
import { notifyWorkerAgent, publishWorkerChanged } from "../worker-events.js";
import { revokeWorkerCredential } from "../worker-agents.js";
import { HttpError, json, securityContext } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { loadSpacePermissions } from "./space-permissions.js";
import { parseModelAccess, type WorkerSpaceModelAccess } from "../worker-eligibility.js";

/**
 * Worker Instances (ADR-032, phase P1): a durable, user-owned Worker with its
 * own Actor, separate from Workspaces. Owner-only: another person's Worker is
 * answered 404, never 403, so ids reveal nothing. Behind the `worker_identity`
 * flag; with the flag off the routes do not exist.
 *
 * `enabled` is configured here. `online` and `ready` are observed and read-only;
 * On the legacy path they are derived from the Workspace the Worker was
 * adopted from (`legacy_worker_mapping`):
 *  - ready: the inventory row's readiness state is `ready`;
 *  - online: that Workspace has an open session row with a recent heartbeat.
 *    The session row is audit history written every few minutes, so this is an
 *    approximation. On the Worker path online comes from the Agent lease,
 *    matching admission. Agent readiness is not yet reported to the server.
 */
const columns = () => `w.id, w.actor_id AS "actorId", w.worker_type_id AS "workerTypeId",
  c.display_name AS "workerTypeName", w.name, w.description, w.enabled,
  w.default_model AS "defaultModel", w.visibility_json AS "visibilityJson",
  w.created_at AS "createdAt",
  w.updated_at AS "updatedAt", w.revoked_at AS "revokedAt",
  EXISTS (
     SELECT 1 FROM worker_agent_sessions s
      WHERE s.worker_instance_id = w.id AND s.disconnected_at IS NULL
        AND s.lease_expires_at > now() AND s.readiness_json IS NOT NULL) AS "readinessKnown",
  (w.revoked_at IS NULL AND EXISTS (
     SELECT 1 FROM worker_agent_sessions s
      WHERE s.worker_instance_id = w.id AND s.disconnected_at IS NULL
        AND s.lease_expires_at > now() AND s.readiness_json::jsonb ->> 'ready' = 'true')) AS ready,
  (w.revoked_at IS NULL AND EXISTS (
     SELECT 1 FROM worker_agent_sessions s
      WHERE s.worker_instance_id = w.id AND s.disconnected_at IS NULL
        AND s.lease_expires_at > now())) AS online,
  (w.revoked_at IS NULL AND EXISTS (
     SELECT 1 FROM worker_credentials cred
      WHERE cred.worker_instance_id = w.id AND cred.revoked_at IS NULL)) AS paired`;
const FROM = `worker_instances w
  JOIN worker_catalog c ON c.worker_type_id = w.worker_type_id`;

function requireWorkerIdentity(): void {
}

function workerView(row: Row): WorkerInstance {
  const iso = (value: unknown) => (value instanceof Date ? value.toISOString() : String(value));
  const visibility = (() => {
    try {
      const parsed = row.visibilityJson ? JSON.parse(String(row.visibilityJson)) : null;
      if (parsed && typeof parsed === "object") {
        return {
          hiddenModels: Array.isArray(parsed.hiddenModels) ? parsed.hiddenModels : [],
          hiddenEfforts:
            parsed.hiddenEfforts && typeof parsed.hiddenEfforts === "object"
              ? parsed.hiddenEfforts
              : {},
        };
      }
    } catch {
      // ignore malformed JSON
    }
    return { hiddenModels: [], hiddenEfforts: {} };
  })();
  return {
    id: String(row.id),
    actorId: String(row.actorId),
    workerTypeId: String(row.workerTypeId),
    workerTypeName: String(row.workerTypeName),
    name: String(row.name),
    description: String(row.description),
    enabled: row.enabled === true,
    online: row.online === true,
    paired: row.paired === true,
    ready: row.ready === true,
    readinessKnown: row.readinessKnown === true,
    defaultModel: row.defaultModel == null ? null : String(row.defaultModel),
    visibility,
    createdAt: iso(row.createdAt),
    updatedAt: iso(row.updatedAt),
    revokedAt: row.revokedAt == null ? null : iso(row.revokedAt),
  };
}

async function readWorker(env: SecurityEnv, userId: string, workerId: string): Promise<WorkerInstance> {
  const q = dataOf(env).read;
  const row = await q.row`SELECT ${q.raw(columns())} FROM ${q.raw(FROM)}
     WHERE w.id = ${workerId} AND w.owner_user_id = ${userId}`;
  if (!row) throw new HttpError(404, "Worker not found");
  return workerView(row);
}

/** GET /api/workers — the caller's Workers; `?includeRevoked=true` adds removed ones. */
export async function handleListWorkers(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireWorkerIdentity();
  const context = await securityContext(request, env, accessContext);
  const params = new URL(request.url).searchParams;
  const includeRevoked = params.get("includeRevoked") === "true";
  const includeShared = params.get("includeShared") === "true";
  const q = dataOf(env).read;
  const rows = await q.rows`SELECT ${q.raw(columns())} FROM ${q.raw(FROM)}
     WHERE (
       w.owner_user_id = ${context.userId}
       OR (${includeShared}::boolean AND ${q.raw(paidOwnerSql("w.owner_user_id"))} AND EXISTS (
         SELECT 1 FROM worker_space_members wsm
          WHERE wsm.worker_id = w.id
            AND wsm.user_id = ${context.userId}
            AND wsm.enabled = true
       ))
     )
       AND (${includeRevoked}::boolean OR w.revoked_at IS NULL)
     ORDER BY w.created_at, w.id`;
  const views = rows.map(workerView);
  const reports = await agentExecutionOptions(env, views.filter((w) => !w.revokedAt));
  return json({ workers: views.map((w) => (reports.has(w.id) ? { ...w, ...reports.get(w.id) } : w)) });
}

/**
 * The models and efforts each paired Agent's provider CLI offers, as the same
 * normalized options the composer already understands. The Agent reports its
 * discovered catalog with its readiness; it is only used when it names the
 * Type's published Profile (digest) and the CLI version it was discovered for.
 * A Profile with a fixed model list needs no report. The last report stays
 * available after the Agent disconnects.
 */
async function agentExecutionOptions(
  env: SecurityEnv,
  workers: WorkerInstance[],
): Promise<Map<string, { executionOptions?: unknown; modelsStatus?: string; modelsReportedAt?: string; providerToolName?: string; providerToolVersion?: string }>> {
  const result = new Map<string, { executionOptions?: unknown; modelsStatus?: string; modelsReportedAt?: string; providerToolName?: string; providerToolVersion?: string }>();
  if (workers.length === 0) return result;
  const q = dataOf(env).read;
  const ids = workers.map((w) => w.id);
  const sessions = await q.rows<{ worker_instance_id: string; readiness_json: string | null; models_status: string | null; models_reported_at: Date | string | null }>`
    SELECT worker_instance_id, models_json AS readiness_json, models_status, models_reported_at FROM worker_agent_sessions
     WHERE worker_instance_id = ANY(${ids}::text[]) AND models_status IS NOT NULL`;
  for (const row of sessions) {
    const at = row.models_reported_at;
    result.set(row.worker_instance_id, {
      modelsStatus: String(row.models_status),
      ...(at ? { modelsReportedAt: at instanceof Date ? at.toISOString() : String(at) } : {}),
    });
  }
  const reported = new Map<string, { providerToolName?: string; providerToolVersion?: string; modelCatalog?: { profileDigest?: string; providerToolVersion?: string } }>();
  for (const row of sessions) {
    try {
      reported.set(row.worker_instance_id, JSON.parse(String(row.readiness_json)));
    } catch {
      /* A damaged report offers no models. */
    }
  }
  const profileFor = async (typeId: string, digest: string | null) => {
    const row = await q.row<{ profile_json: string; digest: string }>`
      SELECT profile_json, digest FROM worker_profiles
       WHERE worker_type_id = ${typeId} AND (${digest}::text IS NULL OR digest = ${digest})
      UNION ALL
      SELECT profile_json, digest FROM worker_profile_history
       WHERE worker_type_id = ${typeId} AND ${digest}::text IS NOT NULL AND digest = ${digest}
      LIMIT 1`;
    return row ? { json: String(row.profile_json), digest: String(row.digest) } : null;
  };
  for (const worker of workers) {
    const report = reported.get(worker.id);
    // The CLI the Agent last read its models from (name and version).
    const toolName = report?.providerToolName;
    const toolVersion = report?.providerToolVersion ?? report?.modelCatalog?.providerToolVersion;
    if (toolName || toolVersion)
      result.set(worker.id, {
        ...result.get(worker.id),
        ...(toolName ? { providerToolName: toolName } : {}),
        ...(toolVersion ? { providerToolVersion: toolVersion } : {}),
      });
    const catalog = report?.modelCatalog;
    const profile = await profileFor(worker.workerTypeId, catalog?.profileDigest ?? null);
    if (!profile) continue;
    if (!catalog) {
      // Without a report only a Profile with a fixed model list can be offered.
      try {
        if (JSON.parse(profile.json)?.model?.discovery) continue;
      } catch {
        continue;
      }
    }
    const options = spaceWorkerExecutionOptions(
      profile.json,
      catalog?.providerToolVersion,
      catalog,
      profile.digest,
    );
    if (options) result.set(worker.id, { ...result.get(worker.id), executionOptions: options });
  }
  return result;
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
  await publishWorkerChanged(env, context.userId, id, "updated");
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
    const nextVisibilityJson =
      input.visibility !== undefined
        ? JSON.stringify({
            hiddenModels: input.visibility.hiddenModels ?? [],
            hiddenEfforts: input.visibility.hiddenEfforts ?? {},
          })
        : null;
    // defaultModel: undefined keeps it, null clears it.
    await q.run`UPDATE worker_instances
         SET name = COALESCE(${input.name ?? null}::text, name),
             description = COALESCE(${input.description ?? null}::text, description),
             enabled = COALESCE(${input.enabled ?? null}::boolean, enabled),
             default_model = CASE WHEN ${input.defaultModel !== undefined}::boolean
                                  THEN ${input.defaultModel ?? null}::text ELSE default_model END,
             visibility_json = COALESCE(${nextVisibilityJson}::text, visibility_json),
             updated_at = now()
       WHERE id = ${workerId} AND owner_user_id = ${context.userId} AND revoked_at IS NULL`;
    await publishWorkerChanged(env, context.userId, workerId, "updated");
    if (input.name) await notifyWorkerAgent(env, workerId, { workerName: input.name });
    return json({ worker: await readWorker(env, context.userId, workerId) });
  }
  if (request.method === "DELETE") {
    await readWorker(env, context.userId, workerId); // 404 for a stranger's or unknown id
    // Idempotent: removing a removed Worker answers the tombstone again.
    await q.run`UPDATE worker_instances
         SET revoked_at = now(), enabled = false, updated_at = now()
       WHERE id = ${workerId} AND owner_user_id = ${context.userId} AND revoked_at IS NULL`;
    // A removed Worker is also unpaired: its credential ends and its session closes,
    // so the Agent on the device learns it is gone, and any Space member access grants end.
    await q.run`DELETE FROM worker_space_members WHERE worker_id = ${workerId}`;
    await revokeWorkerCredential(env, { ownerUserId: context.userId, workerId });
    await publishWorkerChanged(env, context.userId, workerId, "updated");
    return json({ worker: await readWorker(env, context.userId, workerId) });
  }
  throw new HttpError(405, "Method not allowed");
}

const DIGEST = /^[0-9a-f]{64}$/;

/**
 * GET, PUT, DELETE /api/workers/:workerId/mcp-pin (ADR-041, flag `worker_plugins`).
 * The owner pins the exact MCP Worker version and manifest digest a plugin-Type
 * Worker runs. Only a version in the owner's own library can be pinned. The
 * Agent still runs it only when its local allow list approves the same digest.
 */
export async function handleWorkerMcpPin(
  request: Request,
  env: SecurityEnv,
  workerId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireWorkerIdentity();
  const context = await securityContext(request, env, accessContext);
  const q = dataOf(env).read;
  const worker = await q.row<{ workerTypeId: string; origin: string }>`
    SELECT w.worker_type_id AS "workerTypeId", c.origin
      FROM worker_instances w JOIN worker_catalog c ON c.worker_type_id = w.worker_type_id
     WHERE w.id = ${workerId} AND w.owner_user_id = ${context.userId} AND w.revoked_at IS NULL`;
  if (!worker) throw new HttpError(404, "Worker not found");
  if (worker.origin !== "plugin") throw new HttpError(422, "Only an MCP Worker can be pinned");
  const read = () => q.row<{ version: string; manifestDigest: string }>`
    SELECT version, manifest_digest AS "manifestDigest" FROM worker_instance_mcp_pins WHERE worker_instance_id = ${workerId}`;
  if (request.method === "GET") {
    // `available`: the MCP Workers a connected Agent of this Worker reports it can run.
    const session = await q.row<{ report: string | null }>`SELECT readiness_json AS report FROM worker_agent_sessions
       WHERE worker_instance_id = ${workerId} AND disconnected_at IS NULL AND lease_expires_at > now()
       ORDER BY session_epoch DESC LIMIT 1`;
    const available = (() => {
      try {
        const list = (JSON.parse(session?.report ?? "{}") as { mcpWorkers?: unknown }).mcpWorkers;
        return Array.isArray(list) ? list : [];
      } catch {
        return [];
      }
    })();
    return json({ pin: (await read()) ?? null, available });
  }
  if (request.method === "DELETE") {
    await q.run`DELETE FROM worker_instance_mcp_pins WHERE worker_instance_id = ${workerId}`;
    return json({ pin: null });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Method not allowed");
  const body = (await readJson(request)) as { version?: unknown; manifestDigest?: unknown };
  if (typeof body.version !== "string" || typeof body.manifestDigest !== "string" || !DIGEST.test(body.manifestDigest))
    throw new HttpError(400, "version and a 64-character manifestDigest are required");
  const known = await q.row`SELECT 1 AS ok FROM account_worker_plugin_versions v
     JOIN account_worker_plugins p ON p.plugin_ref = v.plugin_ref
    WHERE v.plugin_ref = ${worker.workerTypeId} AND p.owner_user_id = ${context.userId}
      AND v.version = ${body.version} AND v.manifest_digest = ${body.manifestDigest}`;
  if (!known) throw new HttpError(422, "That version is not in your MCP Worker library");
  await q.run`INSERT INTO worker_instance_mcp_pins (worker_instance_id, plugin_ref, version, manifest_digest)
      VALUES (${workerId}, ${worker.workerTypeId}, ${body.version}, ${body.manifestDigest})
    ON CONFLICT (worker_instance_id) DO UPDATE
      SET version = EXCLUDED.version, manifest_digest = EXCLUDED.manifest_digest, updated_at = now()`;
  return json({ pin: await read() });
}

/**
 * POST /api/workers/:workerId/models/refresh — owner only. Asks the connected
 * Agent to re-read the models its provider CLI offers; it answers on its next
 * heartbeat by publishing them (`PUT /api/worker-agent/models`).
 */
export async function handleWorkerModelsRefresh(
  request: Request,
  env: SecurityEnv,
  workerId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireWorkerIdentity();
  const context = await securityContext(request, env, accessContext);
  const worker = await readWorker(env, context.userId, workerId); // 404 for a stranger's or unknown id
  if (worker.revokedAt) throw new HttpError(409, "A removed Worker cannot refresh");
  const q = dataOf(env).read;
  const updated = await q.row<{ at: Date | string }>`UPDATE worker_agent_sessions
       SET models_refresh_requested_at = now()
     WHERE worker_instance_id = ${workerId} AND disconnected_at IS NULL AND lease_expires_at > now()
     RETURNING models_refresh_requested_at AS at`;
  if (!updated) throw new HttpError(409, "The Worker is offline; start its service and try again");
  const at = updated.at;
  await notifyWorkerAgent(env, workerId, { refreshModels: true });
  return json({ requestedAt: at instanceof Date ? at.toISOString() : String(at) }, { status: 202 });
}

/**
 * POST /api/workers/:workerId/usage — owner only. Asks the connected Agent to
 * run its Profile's usage command and returns the provider's report verbatim.
 * The report belongs to the owner's provider account; nothing is stored.
 */
export async function handleWorkerUsageRead(
  request: Request,
  env: SecurityEnv,
  workerId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireWorkerIdentity();
  if (request.method !== "POST") throw new HttpError(405, "Method not allowed");
  const context = await securityContext(request, env, accessContext);
  const worker = await readWorker(env, context.userId, workerId); // 404 for a stranger's or unknown id
  if (worker.revokedAt) throw new HttpError(409, "A removed Worker has no usage");
  const gateways = (env as { SYNTILA_WORKER_GATEWAY?: DurableObjectNamespace }).SYNTILA_WORKER_GATEWAY;
  if (!gateways) return json({ error: "Worker gateway is not configured" }, { status: 503 });
  const response = await gateways
    .get(gateways.idFromName(`worker:${workerId}`))
    .fetch("http://gateway/usage-request", { method: "POST" });
  const body = await response.json().catch(() => ({ error: "Usage request returned an unreadable response" }));
  return json(body, { status: response.status, headers: { "Cache-Control": "no-store" } });
}

/**
 * Narrows a Worker's options to the models and efforts its owner allows
 * members (the Worker-wide allow-list, ADR-042). Nothing ticked offers nothing.
 */
export function memberExecutionOptions(options: unknown, access: WorkerSpaceModelAccess): unknown {
  if (!options || typeof options !== "object") return options;
  const value = options as { models?: Record<string, unknown> };
  const models = value.models;
  if (!models || typeof models !== "object") return options;
  const allowed = new Set(access.allowedModels);
  const list = (raw: unknown) => (Array.isArray(raw) ? raw : []);
  const entries = list(models.options)
    .filter((entry: { id?: unknown }) => typeof entry?.id === "string" && allowed.has(entry.id))
    .map((entry: { id: string; efforts?: unknown; defaultEffort?: unknown }) => {
      const efforts = list(entry.efforts).filter((e) => access.allowedEfforts[entry.id]?.includes(e as string));
      return { ...entry, efforts, defaultEffort: efforts.includes(entry.defaultEffort) ? entry.defaultEffort : null };
    });
  return {
    ...value,
    models: {
      ...models,
      allowsCustomModel: false,
      allowedModelIds: list(models.allowedModelIds).filter((id) => allowed.has(id as string)),
      defaultModelId: allowed.has(models.defaultModelId as string) ? models.defaultModelId : null,
      options: entries,
    },
  };
}

/**
 * GET /api/spaces/:spaceId/workers — the Space owner's Workers, for a member
 * whose Space rights allow Chat or Work. They are the Space's AI: the member's
 * Space rights decide the workflow at admission, and only the models and
 * efforts the owner allows members are offered. The owner gets an empty list
 * (their Workers are already their own).
 */
export async function handleListSpaceWorkers(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireWorkerIdentity();
  const context = await securityContext(request, env, accessContext);
  const policy = await loadSpacePermissions(env, context.userId, spaceId);
  const q = dataOf(env).read;
  const owner = await q.row<{ ownerUserId: string }>`SELECT owner_user_id AS "ownerUserId" FROM spaces WHERE id = ${spaceId}`;
  if (
    !owner ||
    owner.ownerUserId === context.userId ||
    policy.kind === "direct" ||
    policy.isSupport ||
    !(policy.rights.chat || policy.rights.work)
  ) {
    return json({ workers: [] });
  }
  // A member the owner explicitly turned off for a Worker does not see it.
  const rows = await q.rows`SELECT ${q.raw(columns())},
       wmma.allowed_models_json AS "allowedModelsJson", wmma.allowed_efforts_json AS "allowedEffortsJson"
     FROM ${q.raw(FROM)}
     LEFT JOIN worker_member_model_access wmma ON wmma.worker_id = w.id
     WHERE w.owner_user_id = ${owner.ownerUserId} AND w.revoked_at IS NULL AND w.enabled
       AND NOT EXISTS (
         SELECT 1 FROM worker_space_members wsm
          WHERE wsm.worker_id = w.id AND wsm.space_id = ${spaceId}
            AND wsm.user_id = ${context.userId} AND wsm.enabled = false)
     ORDER BY w.created_at, w.id`;
  const views = rows.map(workerView);
  const reports = await agentExecutionOptions(env, views);
  return json({
    workers: views.map((w, i) => {
      const report = reports.get(w.id);
      const access = parseModelAccess(rows[i]!.allowedModelsJson, rows[i]!.allowedEffortsJson);
      return {
        ...w,
        // The owner's own picker visibility is not the member's concern.
        visibility: { hiddenModels: [], hiddenEfforts: {} },
        defaultModel: w.defaultModel && access.allowedModels.includes(w.defaultModel) ? w.defaultModel : null,
        ...(report ?? {}),
        ...(report?.executionOptions ? { executionOptions: memberExecutionOptions(report.executionOptions, access) } : {}),
      };
    }),
  });
}

/**
 * GET /api/workers/shared-with-me — Workers other people shared with the
 * caller through a Person Share (ADR-043). Chat only, in the caller's own
 * Spaces and personal Threads; only the models and efforts the owner allows
 * members are offered. `sharedByName` names the owner.
 */
export async function handleListWorkersSharedWithMe(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  requireWorkerIdentity();
  const context = await securityContext(request, env, accessContext);
  const q = dataOf(env).read;
  const rows = await q.rows`SELECT ${q.raw(columns())},
       owner.display_name AS "sharedByName",
       wmma.allowed_models_json AS "allowedModelsJson", wmma.allowed_efforts_json AS "allowedEffortsJson"
     FROM ${q.raw(FROM)}
     JOIN worker_person_shares wps ON wps.worker_id = w.id AND wps.user_id = ${context.userId}
     JOIN users owner ON owner.id = w.owner_user_id
     LEFT JOIN worker_member_model_access wmma ON wmma.worker_id = w.id
     WHERE w.revoked_at IS NULL AND w.enabled AND ${q.raw(paidOwnerSql("w.owner_user_id"))}
     ORDER BY w.created_at, w.id`;
  const views = rows.map(workerView);
  const reports = await agentExecutionOptions(env, views);
  return json({
    workers: views.map((w, i) => {
      const report = reports.get(w.id);
      const access = parseModelAccess(rows[i]!.allowedModelsJson, rows[i]!.allowedEffortsJson);
      return {
        ...w,
        sharedByName: String(rows[i]!.sharedByName ?? ""),
        visibility: { hiddenModels: [], hiddenEfforts: {} },
        defaultModel: w.defaultModel && access.allowedModels.includes(w.defaultModel) ? w.defaultModel : null,
        ...(report ?? {}),
        ...(report?.executionOptions ? { executionOptions: memberExecutionOptions(report.executionOptions, access) } : {}),
      };
    }),
  });
}
