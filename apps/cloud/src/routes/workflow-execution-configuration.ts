import { paidOwnerSql } from "../account-plan.js";
import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import {
  parseUserWorkflowConfiguration,
  resolveUserWorkflowConfiguration,
  type WorkflowSelection,
  type BuiltinWorkflowDefinition,
} from "@syntila/core";
import { HttpError, type SecurityEnv } from "./http-security.js";
import { loadSpacePermissions } from "./space-permissions.js";
import { validateWorkflowWorkerEligibility } from "./handlers.js";
import {
  MONTHLY_RUN_SECONDS_SQL,
  monthStartIso,
} from "./workspace-invitations.js";
import {
  loadEffectiveMemberAccess,
  loadMemberAccessOverride,
  memberModeError,
  memberSelectionError,
} from "./workspace-member-access.js";

export interface WorkflowExecutionSelectionOverride {
  readonly workerId?: string | null;
  readonly model?: string | null;
  readonly reasoningEffort?: string | null;
  readonly catalogRevision?: string | null;
}

export function parseWorkflowExecutionSelection(
  value: unknown,
): WorkflowExecutionSelectionOverride | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new HttpError(400, "executionSelection must be an object");
  const object = value as Record<string, unknown>;
  if (
    Object.keys(object).some(
      (key) =>
        !["workerId", "model", "reasoningEffort", "catalogRevision"].includes(
          key,
        ),
    )
  )
    throw new HttpError(400, "executionSelection contains an unknown field");
  const stringOrNull = (key: string) => {
    const selected = object[key];
    if (selected === undefined || selected === null) return selected;
    if (typeof selected !== "string" || selected.trim().length === 0)
      throw new HttpError(400, `executionSelection.${key} is invalid`);
    if (selected.length > 200)
      throw new HttpError(400, `executionSelection.${key} is too long`);
    if (key === "catalogRevision" && !/^[a-f0-9]{64}$/.test(selected))
      throw new HttpError(400, "executionSelection.catalogRevision is invalid");
    if (selected === "Auto" || selected === "Automatic") {
      if (key === "workerId")
        throw new HttpError(400, "Worker must be selected explicitly");
      if (selected === "Automatic")
        throw new HttpError(400, "Use Auto for model and effort defaults");
      return null;
    }
    return selected.trim();
  };
  return {
    ...(Object.hasOwn(object, "catalogRevision")
      ? { catalogRevision: stringOrNull("catalogRevision") }
      : {}),
    ...(Object.hasOwn(object, "workerId")
      ? { workerId: stringOrNull("workerId") }
      : {}),
    ...(Object.hasOwn(object, "model") ? { model: stringOrNull("model") } : {}),
    ...(Object.hasOwn(object, "reasoningEffort")
      ? { reasoningEffort: stringOrNull("reasoningEffort") }
      : {}),
  };
}

/** Resolve configured Workers at acceptance, using the same admission rules as execution. */
export async function resolveWorkflowExecutionBindings(
  env: SecurityEnv,
  userId: string,
  spaceId: string,
  threadId: string,
  definition: BuiltinWorkflowDefinition,
  stepInstructions: Record<
    string,
    {
      additionalInstructions?: string;
    }
  >,
  attachments: readonly unknown[],
  executionSelection?: unknown,
) {
  const override = parseWorkflowExecutionSelection(executionSelection);
  if (override && definition.steps.length !== 1)
    throw new HttpError(
      400,
      "Execution overrides are available only for one-step Workflows",
    );
  const space = await loadSpaceWorkflowConfigurations(
    env,
    spaceId,
    definition.id,
  );
  const configuration = space.configurations[0]
    ? parseUserWorkflowConfiguration(definition, space.configurations[0])
    : undefined;
  const effective = resolveUserWorkflowConfiguration(definition, configuration);
  if (!effective.enabled)
    throw new HttpError(422, "Workflow is disabled in this Space");
  const ownWorkspaceId = await ownChatWorkerWorkspace(
    env,
    userId,
    spaceId,
    space.workspaceId,
    definition,
    override?.workerId,
  );
  if (ownWorkspaceId) {
    await ensureOwnChatWorkspaceGrant(env, userId, spaceId, ownWorkspaceId);
  } else if (!space.workspaceId)
    throw new HttpError(
      422,
      "Choose a Workspace in Workflows before sending a request",
    );
  const inventory = await env.SYNTILA_DB.prepare(
    `SELECT i.worker_id AS workerId, i.workspace_id AS workspaceId
     FROM workspace_worker_inventory i
     WHERE i.workspace_id = ?1 ORDER BY i.workspace_id, i.worker_id`,
  )
    .bind(ownWorkspaceId ?? space.workspaceId)
    .all<{ workerId: string; workspaceId: string }>();
  // Invited members may only use what the Workspace owner shares with them.
  const workspaceOwner = await env.SYNTILA_DB.prepare(
    "SELECT owner_user_id AS ownerUserId FROM execution_workspaces WHERE id = ?1",
  )
    .bind(space.workspaceId)
    .first<{ ownerUserId: string }>();
  // A Workspace lent to the Space owner is used only by people who hold their
  // own Person Grant (ADR-020); Space membership and the Space owner's grant
  // never extend to other members.
  const spaceOwner = await env.SYNTILA_DB.prepare(
    "SELECT owner_user_id AS ownerUserId FROM spaces WHERE id = ?1",
  )
    .bind(spaceId)
    .first<{ ownerUserId: string }>();
  const lent = Boolean(
    !ownWorkspaceId &&
      workspaceOwner &&
      spaceOwner &&
      workspaceOwner.ownerUserId !== spaceOwner.ownerUserId,
  );
  // A lent Workspace answers only the borrower, who owns the Space, and only
  // their Chat. Space members never use it, for any workflow.
  if (lent && userId !== spaceOwner!.ownerUserId)
    throw new HttpError(
      403,
      "This Space runs on a shared Workspace that only the Space owner may use",
    );
  if (lent && definition.id !== "chat")
    throw new HttpError(
      403,
      "A shared Workspace runs Chat only; choose your own Workspace for this Workflow",
    );
  if (lent && workspaceOwner!.ownerUserId !== userId) {
    const grant = await env.SYNTILA_DB.prepare(
      `SELECT g.max_concurrent_requests AS maxConcurrent,
              g.max_run_seconds_per_month AS maxRunSeconds,
              ${paidOwnerSql("ew.owner_user_id")} AS ownerShares
       FROM workspace_person_grants g
       JOIN execution_workspaces ew ON ew.id = g.workspace_id
       WHERE g.workspace_id = ?1 AND g.user_id = ?2 AND g.status = 'active'`,
    )
      .bind(space.workspaceId, userId)
      .first<{
        maxConcurrent: number;
        maxRunSeconds: number | null;
        ownerShares: number;
      }>();
    if (!grant)
      throw new HttpError(
        403,
        "You do not have access to this Workspace; ask its owner to invite you",
      );
    // The grant is kept but paused while the owner's plan lacks sharing.
    if (!grant.ownerShares)
      throw new HttpError(
        403,
        "This Workspace is no longer shared; its owner's plan does not include sharing",
      );
    const inFlight = await env.SYNTILA_DB.prepare(
      "SELECT COUNT(*) AS n FROM work_requests WHERE requested_by_user_id = ?1 AND primary_workspace_id = ?2 AND status IN ('queued','running','waiting')",
    )
      .bind(userId, space.workspaceId)
      .first<{ n: number }>();
    if (grant.maxRunSeconds !== null) {
      const used = await env.SYNTILA_DB.prepare(MONTHLY_RUN_SECONDS_SQL)
        .bind(space.workspaceId, userId, monthStartIso())
        .first<{ seconds: number }>();
      if ((used?.seconds ?? 0) >= grant.maxRunSeconds)
        throw new HttpError(
          429,
          "You have used this month's run time on this Workspace; ask its owner for more",
        );
    }
    if ((inFlight?.n ?? 0) >= grant.maxConcurrent)
      throw new HttpError(
        429,
        `You already have ${grant.maxConcurrent} request(s) running on this Workspace; wait for one to finish`,
      );
  }
  const memberPolicy =
    !ownWorkspaceId &&
    space.workspaceId &&
    workspaceOwner &&
    workspaceOwner.ownerUserId !== userId
      ? await loadEffectiveMemberAccess(env, space.workspaceId, userId)
      : null;
  // On the Space owner's own Workspace, the Space's Chat/Work permissions
  // (checked before admission) decide the workflow; the Workspace default
  // policy only limits Workers, models and efforts. A per-person override, or
  // a borrowed Workspace, still caps the mode (ADR-020).
  const modePolicy =
    memberPolicy &&
    workspaceOwner!.ownerUserId === spaceOwner?.ownerUserId
      ? await loadMemberAccessOverride(env, space.workspaceId!, userId)
      : memberPolicy;
  const requested: Record<
    string,
    {
      workerId?: string;
      model?: string;
      reasoningEffort?: string;
      additionalInstructions?: string;
      catalogRevision?: string;
    }
  > = {};
  let pinnedWorkspace: string | null = null;
  for (const step of definition.steps) {
    const id = definition.id === "direct" ? "direct" : step.kind;
    const configuredSelection = effective.steps[step.kind] ?? {};
    const selection: WorkflowSelection = {
      ...configuredSelection,
      ...(override &&
      Object.hasOwn(override, "workerId") &&
      override.workerId !== configuredSelection.worker
        ? { catalogRevision: undefined }
        : {}),
      ...(override && Object.hasOwn(override, "catalogRevision")
        ? { catalogRevision: override.catalogRevision ?? undefined }
        : {}),
      ...(override && Object.hasOwn(override, "workerId")
        ? { worker: override.workerId ?? undefined }
        : {}),
      ...(override && Object.hasOwn(override, "model")
        ? { model: override.model ?? undefined }
        : {}),
      ...(override && Object.hasOwn(override, "reasoningEffort")
        ? { effort: override.reasoningEffort ?? undefined }
        : {}),
    };
    const instructions = stepInstructions[id]?.additionalInstructions;
    if (!selection.worker)
      throw new HttpError(
        422,
        `${step.kind}: Select a Worker before sending this Workflow`,
      );
    if (
      !inventory.results.some(
        (candidate) => candidate.workerId === selection.worker,
      )
    )
      throw new HttpError(
        422,
        `${step.kind}: Configured Worker is unavailable for this Space`,
      );
    const notShared =
      memberSelectionError(memberPolicy, selection) ??
      memberModeError(modePolicy, step.requiredCapabilities);
    if (notShared) throw new HttpError(403, `${step.kind}: ${notShared}`);
    // Preferences and composer choices are intent. Admission validates against
    // current capabilities, then pins that revision for acceptance and dispatch.
    const value: (typeof requested)[string] = {
      ...(selection.worker ? { workerId: selection.worker } : {}),
      ...(selection.model ? { model: selection.model } : {}),
      ...(selection.effort ? { reasoningEffort: selection.effort } : {}),
      ...(instructions ? { additionalInstructions: instructions } : {}),
    };
    requested[id] = value;
    if (value.workerId) {
      const admission = await validateWorkflowWorkerEligibility(
        env,
        spaceId,
        threadId,
        { ...definition, steps: [step] },
        { [id]: value },
      );
      if (admission.issues.length)
        throw new HttpError(
          422,
          admission.issues.map((issue) => issue.message).join(" "),
        );
      const currentRevision = admission.workerCatalogRevisions?.[id];
      if (currentRevision) value.catalogRevision = currentRevision;
      if (pinnedWorkspace && admission.primaryWorkspaceId !== pinnedWorkspace)
        throw new HttpError(
          422,
          "Workflow Workers must execute in the same Workspace",
        );
      pinnedWorkspace = admission.primaryWorkspaceId;
    }
  }
  return requested;
}

/**
 * Chat may run on a Worker from a Workspace the requester owns, outside the
 * Space's Workflow Workspace, when the Space grants `useOwnWorkers`. Workers
 * other people share with the requester never qualify. Returns that
 * Workspace, or null when the Space Workspace rules apply.
 */
async function ownChatWorkerWorkspace(
  env: SecurityEnv,
  userId: string,
  spaceId: string,
  spaceWorkspaceId: string | null,
  definition: BuiltinWorkflowDefinition,
  workerId: string | null | undefined,
): Promise<string | null> {
  if (definition.id !== "chat" || !workerId) return null;
  const worker = await env.SYNTILA_DB.prepare(
    `SELECT i.workspace_id AS workspaceId
       FROM workspace_worker_inventory i
       JOIN execution_workspaces ew ON ew.id = i.workspace_id
      WHERE i.worker_id = ?1 AND ew.owner_user_id = ?2
        AND ew.status != 'revoked'`,
  )
    .bind(workerId, userId)
    .first<{ workspaceId: string }>();
  if (!worker?.workspaceId || worker.workspaceId === spaceWorkspaceId)
    return null;
  const policy = await loadSpacePermissions(env, userId, spaceId);
  if (!policy.rights.useOwnWorkers)
    throw new HttpError(
      403,
      "chat: Using your own Workers is not allowed in this Space",
    );
  return worker.workspaceId;
}

/**
 * The requester's own Workspace answers Chat in the Space through a
 * read-only grant they make; it never allows writes or shell execution.
 */
async function ensureOwnChatWorkspaceGrant(
  env: SecurityEnv,
  userId: string,
  spaceId: string,
  workspaceId: string,
) {
  const existing = await env.SYNTILA_DB.prepare(
    "SELECT status, expires_at AS expiresAt FROM workspace_space_grants WHERE space_id=?1 AND workspace_id=?2 AND status IN ('active','suspended')",
  )
    .bind(spaceId, workspaceId)
    .first<{ status: string; expiresAt: string | null }>();
  const now = new Date().toISOString();
  if (existing) {
    if (
      existing.status === "suspended" ||
      (existing.expiresAt && existing.expiresAt <= now)
    )
      throw new HttpError(
        409,
        "chat: Your Workspace grant for this Space is suspended or expired",
      );
    return;
  }
  await env.SYNTILA_DB.batch([
    env.SYNTILA_DB.prepare(
      "INSERT INTO workspace_space_grants(id,space_id,workspace_id,granted_by_user_id,status,allowed_permissions_json,concurrency_json,created_at,updated_at) VALUES(?1,?2,?3,?4,'active','[\"repository:read\"]','{\"maxConcurrentAssignments\":1}',?5,?5)",
    ).bind(crypto.randomUUID(), spaceId, workspaceId, userId, now),
    env.SYNTILA_DB.prepare(
      "INSERT INTO space_audit_log(id,space_id,actor_type,actor_id,action,target_type,target_id,details_json,created_at) VALUES(?1,?2,'user',?3,'chat.own_workspace.authorized','execution_workspace',?4,?5,?6)",
    ).bind(
      crypto.randomUUID(),
      spaceId,
      userId,
      workspaceId,
      JSON.stringify({ workspaceId, permissions: ["repository:read"] }),
      now,
    ),
  ]);
}
