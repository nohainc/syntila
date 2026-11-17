import { atomically, dataOf } from "../../platform/data.js";
import { UpdateWorkspaceSchema } from "@syntila/protocol";
import { readBody } from "./validation.js";
import { paidOwner } from "../account-plan.js";
import {
  HttpError,
  json,
  parseJson,
  recordAudit,
  requireWorkspaceContext,
  securityContext,
  workspaceOwnerContext,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { ACTIVE_ASSIGNMENT_STATUS_SQL } from "../assignment-transitions.js";
import { workspaceNameTaken } from "./workspaces-shared.js";
import { releasedWorkspaceCleanup } from "../workspace-gateway/release-cleanup.js";
import { DEFAULT_WORKSPACE_PARALLEL_SLOTS } from "../assignment-delivery.js";

/** Bounds of the Workspace-wide parallel slot total chosen by the owner. */
export const MIN_PARALLEL_SLOTS = 1;
export const MAX_PARALLEL_SLOTS = 10;

export async function handleListWorkspaces(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const q = dataOf(env).read;
  const rows = await q.rows<Record<string, unknown>>`SELECT execution_workspaces.id, name, status,
            CASE WHEN owner_user_id = ${context.userId} THEN 'owner' ELSE 'member' END AS role,
            CASE WHEN owner_user_id = ${context.userId} THEN 0 ELSE 1 END AS shared,
            CASE WHEN owner_user_id = ${context.userId}
              THEN COALESCE(parallel_slots, ${q.raw(String(DEFAULT_WORKSPACE_PARALLEL_SLOTS))})
            END AS "parallelSlots",
            CASE WHEN owner_user_id = ${context.userId} THEN space_ai_chat END AS "spaceAiChat",
            CASE WHEN owner_user_id = ${context.userId} THEN space_ai_work END AS "spaceAiWork",
            EXISTS (SELECT 1 FROM workspace_runtime_identities identity
                    WHERE identity.workspace_id = execution_workspaces.id
                      AND identity.revoked_at IS NULL) AS "hasRuntimeIdentity",
            (SELECT COUNT(*) FROM workspace_worker_inventory worker
              WHERE worker.workspace_id = execution_workspaces.id) AS "workerCount",
            (SELECT COUNT(*) FROM worker_assignments assignment
              WHERE assignment.execution_workspace_id = execution_workspaces.id
                AND assignment.status IN (${q.raw(ACTIVE_ASSIGNMENT_STATUS_SQL)})) AS "activeTaskCount",
            CASE
              WHEN NOT EXISTS (SELECT 1 FROM workspace_runtime_identities identity
                               WHERE identity.workspace_id = execution_workspaces.id
                                 AND identity.revoked_at IS NULL) THEN NULL
              WHEN f.updated_at IS NULL OR execution_workspaces.updated_at > f.updated_at
                THEN execution_workspaces.updated_at
              ELSE f.updated_at
            END AS "lastSeen",
            f.platform, f.architecture, f.hostname,
            f.app_version AS "appVersion",
            f.runtime_capabilities_json AS "runtimeCapabilitiesJson",
            f.updated_at AS "factsUpdatedAt",
            execution_workspaces.created_at AS "createdAt",
            execution_workspaces.updated_at AS "updatedAt"
       FROM execution_workspaces
       LEFT JOIN workspace_runtime_facts f ON f.workspace_id = execution_workspaces.id
      WHERE status <> 'revoked'
        AND (owner_user_id = ${context.userId}
             OR EXISTS (SELECT 1 FROM workspace_person_grants g
                         WHERE g.workspace_id = execution_workspaces.id
                           AND g.user_id = ${context.userId} AND g.status = 'active'
                           AND ${paidOwner(q, q.raw("execution_workspaces.owner_user_id"))}))
      ORDER BY shared ASC, name ASC`;
  const workspaces = await Promise.all(
    rows.map(async (raw) => {
      const row = raw as Record<string, unknown>;
      const workspaceId = typeof row.id === "string" ? row.id : null;
      let activeTransport: "websocket" | "http_long_poll" | null = null;
      if (
        workspaceId &&
        row.hasRuntimeIdentity &&
        env.SYNTILA_WORKSPACE_GATEWAY
      ) {
        try {
          const response = await env.SYNTILA_WORKSPACE_GATEWAY.getByName(
            workspaceId,
          ).fetch("https://workspace-gateway/status");
          if (response.ok) {
            const status = (await response.json()) as {
              online?: boolean;
              activeTransport?: string | null;
            };
            if (
              status.online &&
              (status.activeTransport === "websocket" ||
                status.activeTransport === "http_long_poll")
            ) {
              activeTransport = status.activeTransport;
            }
          }
        } catch {
          // Connection mode is an operational hint; preserve the Workspace
          // row if its Gateway status cannot be read at this moment.
        }
      }
      return {
        ...row,
        shared: Boolean(row.shared),
        activeTransport,
        connectionMode:
          activeTransport === "websocket"
            ? "Connected · WebSocket"
            : activeTransport === "http_long_poll"
              ? "Connected · HTTPS fallback"
              : null,
      };
    }),
  );
  return json({ workspaces });
}

export async function handleGetWorkspace(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  await requireWorkspaceContext(context, env, workspaceId);
  const row = await dataOf(env).read.row<{
      id: string;
      name: string;
      status: string;
      createdAt: string;
      updatedAt: string;
    }>`SELECT id, name, status, created_at AS "createdAt", updated_at AS "updatedAt" FROM execution_workspaces WHERE id = ${workspaceId} AND owner_user_id = ${context.userId}`;
  if (!row) throw new HttpError(404, "Workspace not found");
  return json({ workspace: row });
}

export async function handleUpdateWorkspace(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceOwnerContext(
    request,
    env,
    workspaceId,
    "workspace:manage",
    accessContext,
  );
  const body = await readBody(request, UpdateWorkspaceSchema);
  const hasName = body.name !== undefined;
  const hasSlots = body.parallelSlots !== undefined;
  const hasChat = body.spaceAiChat !== undefined;
  const hasWork = body.spaceAiWork !== undefined;
  if (!hasName && !hasSlots && !hasChat && !hasWork)
    throw new HttpError(
      400,
      "Provide a name, parallelSlots or Space AI option",
    );
  const name = typeof body.name === "string" ? body.name.trim() : "";
  if (hasName && (name.length < 1 || name.length > 120)) {
    throw new HttpError(400, "Workspace name must be 1 to 120 characters");
  }
  const slots = body.parallelSlots;
  if (
    hasSlots &&
    (typeof slots !== "number" ||
      !Number.isInteger(slots) ||
      slots < MIN_PARALLEL_SLOTS ||
      slots > MAX_PARALLEL_SLOTS)
  ) {
    throw new HttpError(
      400,
      `parallelSlots must be between ${MIN_PARALLEL_SLOTS} and ${MAX_PARALLEL_SLOTS}`,
    );
  }
  if (
    hasName &&
    (await workspaceNameTaken(
      dataOf(env).read,
      context.userId,
      name,
      workspaceId,
    ))
  ) {
    throw new HttpError(409, `You already have a Workspace named "${name}"`);
  }
  const now = new Date().toISOString();
  const result = await dataOf(env).read.run`UPDATE execution_workspaces
        SET name = CASE WHEN ${hasName ? name : null}::text IS NULL THEN name ELSE ${hasName ? name : null}::text END,
            parallel_slots = CASE WHEN ${hasSlots ? slots : null}::bigint IS NULL THEN parallel_slots ELSE ${hasSlots ? slots : null}::bigint END,
            space_ai_chat = COALESCE(${hasChat ? (body.spaceAiChat ? 1 : 0) : null}::int::boolean, space_ai_chat),
            space_ai_work = COALESCE(${hasWork ? (body.spaceAiWork ? 1 : 0) : null}::int::boolean, space_ai_work),
            updated_at = ${now}::timestamptz
      WHERE id = ${workspaceId} AND owner_user_id = ${context.userId} AND status <> 'revoked'`;
  if (result === 0) {
    throw new HttpError(404, "Workspace not found");
  }
  await recordAudit(
    env,
    context,
    "workspace.updated",
    "workspace",
    workspaceId,
    {
      ...(hasName ? { name } : {}),
      ...(hasSlots ? { parallelSlots: slots } : {}),
      ...(hasChat ? { spaceAiChat: body.spaceAiChat } : {}),
      ...(hasWork ? { spaceAiWork: body.spaceAiWork } : {}),
    },
    workspaceId,
  );
  // More slots may let queued work start now; the Gateway enforces the total.
  if (hasSlots && env.SYNTILA_WORKSPACE_GATEWAY) {
    try {
      await env.SYNTILA_WORKSPACE_GATEWAY.getByName(workspaceId).fetch(
        "https://workspace-gateway/flush-queued",
        { method: "POST" },
      );
    } catch {
      // Queued work still starts when the next assignment finishes.
    }
  }
  return json({
    workspace: {
      id: workspaceId,
      ...(hasName ? { name } : {}),
      ...(hasSlots ? { parallelSlots: slots } : {}),
      ...(hasChat ? { spaceAiChat: body.spaceAiChat } : {}),
      ...(hasWork ? { spaceAiWork: body.spaceAiWork } : {}),
      updatedAt: now,
    },
  });
}

export async function handleRevokeWorkspace(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const workspace = await dataOf(env).read.row<{ id: string; status: string }>`SELECT id, status FROM execution_workspaces WHERE id = ${workspaceId} AND owner_user_id = ${context.userId}`;
  if (!workspace) throw new HttpError(404, "Workspace not found");

  const now = new Date().toISOString();
  const alreadyRevoked = workspace.status === "revoked";
  if (!alreadyRevoked) {
    const workspaceUpdate = await dataOf(env).read.run`UPDATE execution_workspaces SET status = 'revoked', updated_at = ${now} WHERE id = ${workspaceId} AND owner_user_id = ${context.userId}`;
    if (workspaceUpdate === 0) {
      throw new HttpError(404, "Workspace not found");
    }
  }

  await dataOf(env).read.run`UPDATE workspace_space_grants SET status = 'revoked', updated_at = ${now} WHERE workspace_id = ${workspaceId} AND status IN ('active', 'suspended')`;

  await dataOf(env).read.run`UPDATE workspace_runtime_identities SET revoked_at = ${now} WHERE workspace_id = ${workspaceId} AND revoked_at IS NULL`;

  await dataOf(env).read.run`UPDATE workspace_installations SET status = 'released', released_at = ${now}, updated_at = ${now} WHERE workspace_id = ${workspaceId} AND status = 'active'`;

  await atomically(env.SYNTILA_DB, "workspace.release-cleanup", (q) =>
    releasedWorkspaceCleanup(q, workspaceId),
  );

  if (!alreadyRevoked) {
    await recordAudit(
      env,
      context,
      "workspace.revoked",
      "workspace",
      workspaceId,
      { revokedAt: now },
      workspaceId,
    );
  }
  return json({ ok: true, revokedAt: now, alreadyRevoked });
}

export async function handleExportWorkspaceAudit(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await workspaceOwnerContext(
    request,
    env,
    workspaceId,
    "audit:read",
    accessContext,
  );
  const url = new URL(request.url);
  const requestedLimit = Number.parseInt(
    url.searchParams.get("limit") ?? "100",
    10,
  );
  const limit = Number.isFinite(requestedLimit)
    ? Math.min(Math.max(requestedLimit, 1), 500)
    : 100;
  const rows = await dataOf(env).read.rows<{
      id: string;
      workspaceId: string;
      actorType: string;
      actorId: string;
      action: string;
      targetType: string;
      targetId: string;
      detailsJson: string;
      createdAt: string;
    }>`SELECT id, workspace_id AS "workspaceId", actor_type AS "actorType",
            actor_id AS "actorId", action, target_type AS "targetType",
            target_id AS "targetId", details_json::text AS "detailsJson",
            created_at AS "createdAt"
     FROM workspace_audit_log
     WHERE workspace_id = ${workspaceId}
     ORDER BY created_at DESC, id DESC
     LIMIT ${limit}`;
  return json({
    format: "syntila-audit-log-v1",
    workspaceId,
    exportedAt: new Date().toISOString(),
    entries: rows.map((row) => ({
      id: row.id,
      workspaceId: row.workspaceId,
      actorType: row.actorType,
      actorId: row.actorId,
      action: row.action,
      targetType: row.targetType,
      targetId: row.targetId,
      details: parseJson<Record<string, unknown>>(row.detailsJson, {}),
      createdAt: row.createdAt,
    })),
  });
}

/**
 * Owner-only: asks the Workspace Service to run the Worker Profile's usage
 * command and returns the provider's raw report. The report belongs to the
 * machine owner's provider account, so it is not shared with Space members.
 */
export async function handleWorkerUsage(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  workerId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await workspaceOwnerContext(
    request,
    env,
    workspaceId,
    "workspace:manage",
    accessContext,
  );
  if (!env.SYNTILA_WORKSPACE_GATEWAY)
    return json(
      { error: "Workspace Gateway is not configured" },
      { status: 503 },
    );
  const response = await env.SYNTILA_WORKSPACE_GATEWAY.getByName(
    workspaceId,
  ).fetch("https://workspace-gateway/worker-usage", {
    method: "POST",
    body: JSON.stringify({ workerId }),
  });
  const body = await response.json().catch(() => ({
    error: "Usage request returned an unreadable response",
  }));
  return json(body, { status: response.status });
}
