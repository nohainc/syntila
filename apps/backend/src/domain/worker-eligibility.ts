import { EXECUTION_PERMISSIONS, WORKFLOW_CAPABILITIES } from "@syntila/core";
import { spaceMemberPermissions } from "@syntila/security";
import type { Query } from "../platform/data.js";
import { spaceModelOptions } from "./worker-execution-options.js";

/**
 * Who may run what, on which Worker (ADR-035 decisions 2 and 3).
 *
 * v1 eligibility, checked on the server at admission and again for every
 * Workflow step, never only in a picker:
 *   1. the Worker is the requester's own and has not been removed;
 *   2. the Worker is enabled;
 *   3. its Type is active, visible and runs on the Worker path (a plugin Type
 *      still needs a Workspace pin and is not supported yet), and the Thread's
 *      execution policy does not exclude it;
 *   4. the requester holds execute rights in the Thread.
 * A Worker that fails 1 is reported exactly like one that does not exist, so a
 * request can never learn that someone else's Worker ID is real.
 *
 * `acceptWorkerTarget` also returns the snapshot taken at acceptance: Worker,
 * Actor, Type, Profile digest and revision, model, effort and permissions.
 * Later renames, Profile changes or removal never change an accepted request.
 */

export type WorkerEligibilityCode =
  | "worker_not_found"
  | "worker_disabled"
  | "worker_type_unavailable"
  | "worker_type_not_allowed"
  | "model_not_supported"
  | "effort_not_supported"
  | "execute_not_permitted"
  | "worker_offline";

export interface WorkerTargetSnapshot {
  readonly schemaVersion: 1;
  readonly workerId: string;
  readonly actorId: string;
  readonly workerName: string;
  readonly ownerUserId: string;
  readonly workerTypeId: string;
  readonly workerTypeName: string;
  /** The published Profile current at acceptance. Null only for an unprofiled Type. */
  readonly profile: {
    readonly definitionId: string | null;
    readonly revision: number;
    readonly digest: string;
  } | null;
  readonly model: string | null;
  readonly reasoningEffort: string | null;
  readonly permissions: readonly string[];
  readonly readOnly: boolean;
  readonly requestedByUserId: string;
  readonly spaceId: string;
  readonly threadId: string;
  readonly acceptedAt: string;
}

export type WorkerEligibility =
  | { readonly ok: true; readonly snapshot: WorkerTargetSnapshot }
  | { readonly ok: false; readonly code: WorkerEligibilityCode };

export interface WorkerTargetRequest {
  readonly workerId: string;
  readonly requesterUserId: string;
  readonly spaceId: string;
  readonly threadId: string;
  /** Workflow id of the request (`chat` needs the chat right, others the work right). */
  readonly workflowId: string;
  readonly model?: string | null;
  readonly reasoningEffort?: string | null;
  readonly readOnly?: boolean;
  /** Required capabilities of the step; `test_execution` keeps shell access when read-only. */
  readonly capabilities?: readonly string[];
  /** When true an offline Worker is refused with `worker_offline`. */
  readonly requireOnline?: boolean;
}

const MAX_MODEL_LENGTH = 200;

function record(value: unknown): Record<string, unknown> {
  if (typeof value === "string") {
    try {
      return record(JSON.parse(value));
    } catch {
      return {};
    }
  }
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function parsed(value: unknown): unknown {
  if (typeof value !== "string") return value;
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function strings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

/**
 * Whether the Agent of a Worker has a live session: one connected row whose
 * lease has not lapsed. This is the only offline signal; it never looks at a
 * Workspace.
 */
export async function workerIsOnline(q: Query, workerId: string): Promise<boolean> {
  const row = await q.row<{ ok: number }>`SELECT 1 AS ok FROM worker_agent_sessions
     WHERE worker_instance_id = ${workerId} AND disconnected_at IS NULL
       AND lease_expires_at > now()`;
  return row !== null;
}

/**
 * The requester's right to execute in a Thread: an active member whose role
 * allows the workflow, and, for a non-owner, the Thread's access policy. The
 * same rules the Workspace path applies when it selects a target.
 */
export async function requesterMayExecute(
  q: Query,
  input: { spaceId: string; threadId: string; requesterUserId: string; workflowId: string },
): Promise<{ allowed: false } | { allowed: true; canWrite: boolean }> {
  const membership = await q.row<{ role: string; settingsJson: string }>`SELECT sm.role, s.settings_json AS "settingsJson"
     FROM space_memberships sm
     JOIN spaces s ON s.id = sm.space_id
     JOIN users u ON u.id = sm.user_id
    WHERE u.status = 'active' AND sm.space_id = ${input.spaceId} AND sm.user_id = ${input.requesterUserId}`;
  if (!membership) return { allowed: false };
  const rights = spaceMemberPermissions(membership.role, membership.settingsJson, input.requesterUserId);
  if (input.workflowId === "chat" ? !rights.chat : !rights.work) return { allowed: false };
  const thread = await q.row<{ spaceId: string; accessPolicy: unknown }>`SELECT ws.space_id AS "spaceId", ws.access_policy_json AS "accessPolicy"
     FROM threads ws WHERE ws.id = ${input.threadId}`;
  if (!thread || thread.spaceId !== input.spaceId) return { allowed: false };
  if (membership.role !== "owner") {
    const policy = record(thread.accessPolicy);
    const users = strings(policy.allowedUserIds);
    const roles = strings(policy.allowedSpaceRoles);
    if (
      (users.length > 0 && !users.includes(input.requesterUserId)) ||
      (roles.length > 0 && !roles.includes(membership.role)) ||
      !strings(policy.allowedPermissions).includes("execute")
    ) {
      return { allowed: false };
    }
  }
  return { allowed: true, canWrite: rights.work };
}

/**
 * Resolves and authorizes the Worker for one request or Workflow step.
 * Returns the acceptance snapshot, or the first reason the Worker is not
 * eligible. Reads only; it never changes state.
 */
export async function acceptWorkerTarget(
  q: Query,
  request: WorkerTargetRequest,
  now: Date = new Date(),
): Promise<WorkerEligibility> {
  // Own, live Workers only. Someone else's Worker, a removed one and an unknown
  // ID all read the same.
  const worker = await q.row<{
    id: string;
    actorId: string;
    name: string;
    ownerUserId: string;
    enabled: boolean;
    defaultModel: string | null;
    workerTypeId: string;
    typeName: string;
    lifecycle: string;
    visibility: string;
    origin: string;
    profileRevision: number | null;
    profileDigest: string | null;
    profileDefinitionId: string | null;
    profileJson: string | null;
  }>`SELECT w.id, w.actor_id AS "actorId", w.name, w.owner_user_id AS "ownerUserId", w.enabled,
            w.default_model AS "defaultModel", w.worker_type_id AS "workerTypeId",
            c.display_name AS "typeName", c.lifecycle_state AS lifecycle,
            c.visibility_state AS visibility, c.origin,
            p.revision::int AS "profileRevision", p.digest AS "profileDigest", p.profile_json AS "profileJson",
            COALESCE(p.profile_json::jsonb ->> 'profileDefinitionId', c.profile_definition_id) AS "profileDefinitionId"
       FROM worker_instances w
       JOIN worker_catalog c ON c.worker_type_id = w.worker_type_id
       LEFT JOIN worker_profiles p ON p.worker_type_id = w.worker_type_id
      WHERE w.id = ${request.workerId} AND w.owner_user_id = ${request.requesterUserId}
        AND w.revoked_at IS NULL`;
  if (!worker) return { ok: false, code: "worker_not_found" };
  if (!worker.enabled) return { ok: false, code: "worker_disabled" };
  // The Agent runs a published Profile; a Type without one cannot be accepted.
  if (
    worker.lifecycle !== "active" ||
    worker.visibility !== "visible" ||
    worker.origin === "plugin" ||
    worker.profileRevision == null ||
    worker.profileDigest == null ||
    worker.profileDefinitionId == null
  ) {
    return { ok: false, code: "worker_type_unavailable" };
  }

  const policy = await q.row<{ allowedTypes: unknown }>`SELECT allowed_worker_type_ids_json AS "allowedTypes"
     FROM thread_execution_policies WHERE thread_id = ${request.threadId}`;
  const allowedTypes = strings(parsed(policy?.allowedTypes));
  if (allowedTypes.length > 0 && !allowedTypes.includes(worker.workerTypeId)) {
    return { ok: false, code: "worker_type_not_allowed" };
  }

  const rights = await requesterMayExecute(q, request);
  if (rights.allowed === false) return { ok: false, code: "execute_not_permitted" };

  const model = (request.model ?? worker.defaultModel ?? "").trim();
  if (model.length > MAX_MODEL_LENGTH) return { ok: false, code: "worker_type_unavailable" };
  // A model or effort the person chose must be one the Type's Profile lists.
  // A Profile that discovers its models on the Agent has no list here; the
  // Agent is then the authority and refuses at run time.
  const chosenEffort = request.reasoningEffort?.trim();
  if ((request.model?.trim() || chosenEffort) && worker.profileJson) {
    const options = spaceModelOptions(worker.profileJson, undefined, undefined, worker.profileDigest);
    if (options && options.catalog.length > 0) {
      const entry = request.model?.trim() ? options.catalog.find((c) => c.id === request.model!.trim()) : undefined;
      if (request.model?.trim() && !entry) return { ok: false, code: "model_not_supported" };
      const efforts = entry?.supportedReasoningEfforts ?? options.supportedReasoningEfforts;
      if (chosenEffort && efforts.length > 0 && !efforts.includes(chosenEffort)) return { ok: false, code: "effort_not_supported" };
    }
  }
  const readOnly = request.readOnly === true;
  const base = rights.canWrite ? [...EXECUTION_PERMISSIONS] : ["repository:read"];
  const canRunTests = (request.capabilities ?? []).includes("test_execution");
  const permissions = readOnly
    ? base.filter((p) => p !== "repository:write" && (p !== "shell:execute" || canRunTests))
    : base;
  // These capabilities are Workflow requirements, not provider claims. Cloud
  // maps them to its execution permissions and fails closed for unknown ones.
  // The current Worker catalog has no per-Type capability advertisement.
  const required = new Set<string>(["repository:read"]);
  for (const capability of request.capabilities ?? []) {
    if (!(WORKFLOW_CAPABILITIES as readonly string[]).includes(capability))
      return { ok: false, code: "worker_type_unavailable" };
    if (capability === "thread_write") required.add("repository:write");
    if (capability === "test_execution") required.add("shell:execute");
  }
  if (![...required].every((permission) => permissions.includes(permission)))
    return { ok: false, code: "execute_not_permitted" };

  if (request.requireOnline && !(await workerIsOnline(q, worker.id))) {
    return { ok: false, code: "worker_offline" };
  }

  return {
    ok: true,
    snapshot: {
      schemaVersion: 1,
      workerId: worker.id,
      actorId: worker.actorId,
      workerName: worker.name,
      ownerUserId: worker.ownerUserId,
      workerTypeId: worker.workerTypeId,
      workerTypeName: worker.typeName,
      profile:
        worker.profileRevision != null && worker.profileDigest != null
          ? {
              definitionId: worker.profileDefinitionId,
              revision: worker.profileRevision,
              digest: worker.profileDigest,
            }
          : null,
      model: model || null,
      reasoningEffort: request.reasoningEffort?.trim() || null,
      permissions,
      readOnly,
      requestedByUserId: request.requesterUserId,
      spaceId: request.spaceId,
      threadId: request.threadId,
      acceptedAt: now.toISOString(),
    },
  };
}

/** HTTP status and a stable message for each refusal; none reveals another user's Worker. */
export function workerEligibilityResponse(code: WorkerEligibilityCode): { status: number; message: string } {
  switch (code) {
    case "worker_not_found":
      return { status: 404, message: "Worker not found" };
    case "worker_disabled":
      return { status: 422, message: "This Worker is turned off" };
    case "worker_type_unavailable":
      return { status: 422, message: "This Worker's type cannot run this request" };
    case "worker_type_not_allowed":
      return { status: 422, message: "This Thread does not allow this Worker type" };
    case "model_not_supported":
      return { status: 422, message: "This Worker's Profile does not offer that model" };
    case "effort_not_supported":
      return { status: 422, message: "This model does not offer that reasoning effort" };
    case "execute_not_permitted":
      return { status: 403, message: "You cannot run work in this Thread" };
    case "worker_offline":
      return { status: 409, message: "This Worker is offline" };
  }
}
