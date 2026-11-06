import { stepInstanceId, type ModelIdentityCatalog } from "@syntila/core";
import { loadSpacePermissions } from "./space-permissions.js";
import {
  pluginExecutionOptions,
  spaceWorkerExecutionOptions,
} from "../worker-execution-options.js";
import { supportsPluginExecutor } from "../execution-selection-snapshot.js";
import { pluginOwnerEntitledSql } from "../account-plan.js";
import { PluginInventoryExecutorSchema } from "@syntila/workspace-runtime-protocol";
import {
  AuthorizationError,
  authorizeSpaceMembership,
  type AuthenticatedUser,
  type Permission,
  type SecurityContext,
} from "@syntila/security";
import {
  validateWorkerExecutionSelection,
  canDiscussThread,
  canExecuteThread,
  canManageThread,
  canViewThread,
  DEFAULT_THREAD_ACCESS_POLICY,
  type SpaceKind,
  type SpaceMembership,
  type Thread,
  type BuiltinWorkflowDefinition,
  type WorkflowId,
  WORKFLOW_IDS,
  THREAD_BINDING_IDS,
  validateWorkspaceGrantPermissions,
  validateWorkspaceGrantWorkerIds,
} from "@syntila/core";

import type { SecurityEnv } from "./http-security.js";
import { authorizeRequest } from "./http-security.js";

import { HttpError, parseJson } from "./http-security.js";

/** Thread configuration owns authored context, never global execution choices. */
export function normalizeThreadWorkConfig(value: unknown): {
  config: Record<string, unknown>;
} {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new HttpError(400, "workConfig must be an object");
  const input = value as Record<string, unknown>;
  if (
    Object.keys(input).some(
      (key) =>
        !["defaultWorkflowId", "threadInstructions", "bindings"].includes(key),
    ) ||
    typeof input.defaultWorkflowId !== "string" ||
    !WORKFLOW_IDS.includes(input.defaultWorkflowId as WorkflowId) ||
    !input.bindings ||
    typeof input.bindings !== "object" ||
    Array.isArray(input.bindings)
  )
    throw new HttpError(400, "workConfig is invalid");
  const text = (value: unknown): string | undefined => {
    if (value === undefined) return undefined;
    if (typeof value !== "string" || value.length > 4000)
      throw new HttpError(400, "workConfig instructions are invalid");
    return value.trim() || undefined;
  };
  const threadInstructions = text(input.threadInstructions);
  const bindings: Record<string, { additionalInstructions: string }> = {};
  for (const [id, raw] of Object.entries(
    input.bindings as Record<string, unknown>,
  )) {
    if (
      !(THREAD_BINDING_IDS as readonly string[]).includes(id) ||
      !raw ||
      typeof raw !== "object" ||
      Array.isArray(raw)
    )
      throw new HttpError(400, "workConfig binding is invalid");
    const binding = raw as Record<string, unknown>;
    if (Object.keys(binding).some((key) => key !== "additionalInstructions"))
      throw new HttpError(
        400,
        "Thread execution preferences are not supported; use Workflows",
      );
    const instructions = text(binding.additionalInstructions);
    if (instructions) bindings[id] = { additionalInstructions: instructions };
  }
  return {
    config: {
      defaultWorkflowId: input.defaultWorkflowId,
      ...(threadInstructions ? { threadInstructions } : {}),
      bindings,
    },
  };
}

const VIEW_STATE_STRING_KEYS = [
  "workflowReference",
  "workerId",
  "workerTypeId",
  "model",
  "reasoningEffort",
  "catalogRevision",
  "selectionUpdatedAt",
] as const;

/**
 * Validates a Thread metadata patch. Values are merged with JSON merge-patch
 * semantics, so `null` clears a key. Only presentation state is accepted.
 *
 * View state is personal: the caller's `viewState` is stored under
 * `viewStates[userId]`, so one member's selection never replaces another's.
 * A `selectionUpdatedAt` ahead of the server clock is clamped to it, so a
 * device with a fast clock cannot outrank later choices made elsewhere.
 */
export function normalizeThreadMetadataPatch(
  value: unknown,
  userId: string,
  now: string = new Date().toISOString(),
): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new HttpError(400, "metadata must be an object");
  const input = value as Record<string, unknown>;
  if (Object.keys(input).some((key) => key !== "viewState"))
    throw new HttpError(400, "metadata contains unsupported keys");
  if (input.viewState === undefined) return {};
  if (input.viewState === null) return { viewStates: { [userId]: null } };
  if (typeof input.viewState !== "object" || Array.isArray(input.viewState))
    throw new HttpError(400, "metadata.viewState must be an object");
  const viewState = input.viewState as Record<string, unknown>;
  const allowed = new Set<string>(["tabIndex", ...VIEW_STATE_STRING_KEYS]);
  if (Object.keys(viewState).some((key) => !allowed.has(key)))
    throw new HttpError(400, "metadata.viewState contains unsupported keys");
  const patch: Record<string, unknown> = {};
  if (viewState.tabIndex !== undefined) {
    if (viewState.tabIndex !== 0 && viewState.tabIndex !== 1)
      throw new HttpError(400, "metadata.viewState.tabIndex is invalid");
    patch.tabIndex = viewState.tabIndex;
  }
  for (const key of VIEW_STATE_STRING_KEYS) {
    const entry = viewState[key];
    if (entry === undefined) continue;
    if (
      entry !== null &&
      (typeof entry !== "string" || entry.length === 0 || entry.length > 200)
    )
      throw new HttpError(400, `metadata.viewState.${key} is invalid`);
    patch[key] = entry;
  }
  const at = patch.selectionUpdatedAt;
  if (typeof at === "string") {
    const time = Date.parse(at);
    if (Number.isNaN(time))
      throw new HttpError(
        400,
        "metadata.viewState.selectionUpdatedAt is invalid",
      );
    if (time > Date.parse(now)) patch.selectionUpdatedAt = now;
  }
  return { viewStates: { [userId]: patch } };
}

/** JSON merge-patch (RFC 7386), matching SQLite json_patch. */
export function mergeMetadata(
  target: Record<string, unknown>,
  patch: Record<string, unknown>,
): Record<string, unknown> {
  const result = { ...target };
  for (const [key, value] of Object.entries(patch)) {
    if (value === null) delete result[key];
    else if (typeof value === "object" && !Array.isArray(value)) {
      const current = result[key];
      result[key] = mergeMetadata(
        current && typeof current === "object" && !Array.isArray(current)
          ? (current as Record<string, unknown>)
          : {},
        value as Record<string, unknown>,
      );
    } else result[key] = value;
  }
  return result;
}

/** Returns only the viewer's own view state, as `viewState`. */
function viewerMetadata(
  metadata: Record<string, unknown>,
  viewerUserId: string,
): Record<string, unknown> {
  // A shared top-level `viewState` predates per-user storage and is ignored.
  const { viewStates, viewState: _shared, ...rest } = metadata;
  const own =
    viewStates && typeof viewStates === "object" && !Array.isArray(viewStates)
      ? (viewStates as Record<string, unknown>)[viewerUserId]
      : undefined;
  return own && typeof own === "object" ? { ...rest, viewState: own } : rest;
}

export function threadMetadata(
  row: Record<string, unknown>,
  viewerUserId: string,
): Record<string, unknown> {
  const accessPolicy = parseJson<Record<string, unknown>>(
    row.accessPolicyJson ?? row.access_policy_json,
    {},
  );
  return {
    id: String(row.id),
    spaceId: String(row.spaceId ?? row.space_id),
    name: String(row.name),
    status: String(row.status),
    createdByUserId: row.leadUserId ?? row.lead_user_id ?? null,
    creatorEmail: row.creatorEmail ?? null,
    creatorIsOwner: row.creatorIsOwner === 1,
    lead: row.leadUserId ?? row.lead_user_id ?? null,
    leadDisplayName:
      row.leadDisplayName ?? row.lead_display_name ?? row.leadName ?? null,
    brief: row.brief ?? row.lastMessageSnippet ?? "",
    briefAuthorName: row.briefAuthorName ?? null,
    accessPolicy,
    workConfig: parseJson(row.workConfigJson ?? row.configJson, {
      defaultWorkflowId: "full_cycle",
      bindings: {},
    }),
    metadata: viewerMetadata(
      parseJson<Record<string, unknown>>(
        row.metadataJson ?? row.metadata_json,
        {},
      ),
      viewerUserId,
    ),
    primaryWorkspace:
      accessPolicy.primaryWorkspaceId ??
      accessPolicy.primary_workspace_id ??
      null,
    queueStatus: "Idle",
    hasActiveWork: row.hasActiveWork === 1,
    hasUnread: row.hasUnread === 1,
    isGeneral:
      row.isGeneral === 1 ||
      row.is_general === 1 ||
      row.isGeneral === true ||
      row.is_general === true,
    pinnedAt: typeof row.pinnedAt === "string" ? row.pinnedAt : null,
    pinPosition: typeof row.pinPosition === "number" ? row.pinPosition : 0,
    createdAt: String(row.createdAt ?? row.created_at),
    updatedAt: String(row.updatedAt ?? row.updated_at),
  };
}

export function sortThreads<T extends Record<string, unknown>>(
  threads: T[],
): T[] {
  return [...threads].sort((a, b) => {
    const aId = String(a.id ?? "");
    const bId = String(b.id ?? "");
    const aUpdated = String(
      a.updatedAt ?? a.updated_at ?? a.createdAt ?? a.created_at ?? "",
    );
    const bUpdated = String(
      b.updatedAt ?? b.updated_at ?? b.createdAt ?? b.created_at ?? "",
    );
    const byUpdated = bUpdated.localeCompare(aUpdated);
    return byUpdated !== 0 ? byUpdated : bId.localeCompare(aId);
  });
}

export function discussionReferences(value: unknown): readonly string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value))
    throw new HttpError(400, "references must be an array");
  return value.flatMap((reference) => {
    if (typeof reference === "string" && reference.trim())
      return [reference.trim()];
    if (reference && typeof reference === "object") {
      const id = (reference as Record<string, unknown>).id;
      if (typeof id === "string" && id.trim()) return [id.trim()];
    }
    throw new HttpError(400, "references must contain non-empty identifiers");
  });
}

export type ThreadAccess = "view" | "discuss" | "execute" | "manage";

async function loadThreadRow(env: SecurityEnv, threadId: string) {
  const row = await env.SYNTILA_DB.prepare(
    `SELECT t.id, t.space_id AS spaceId, t.name, t.status,
            t.access_policy_json AS accessPolicyJson, t.lead_user_id AS leadUserId,
            COALESCE(t.is_general, 0) AS isGeneral,
            t.created_at AS createdAt, t.updated_at AS updatedAt,
            COALESCE(s.kind, 'group') AS spaceKind
     FROM threads t
     JOIN spaces s ON s.id = t.space_id
     WHERE t.id = ?1`,
  )
    .bind(threadId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Thread not found");
  return row;
}

function threadAccessPermission(access: ThreadAccess): Permission {
  return access === "view"
    ? "spaces:read"
    : access === "discuss"
      ? "spaces:write"
      : access === "execute"
        ? "run.start"
        : "spaces:write";
}

export async function authorizeThreadAccess(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  access: ThreadAccess,
  accessContext?: ExecutionContext,
): Promise<{
  context: SecurityContext;
  thread: Thread;
  spaceId: string;
}> {
  const row = await loadThreadRow(env, threadId);
  const context = await authorizeRequest(
    request,
    env,
    threadAccessPermission(access),
    String(row.spaceId),
    accessContext,
  );
  return threadAccessForContext(env, context, row, access);
}

/**
 * Thread access for a person who is not making this HTTP request, such as
 * the author of a queued request Cloud sends on their behalf. Checks the same
 * account status, Space membership and Thread rules as a live request.
 */
export async function authorizeThreadAccessAsUser(
  env: SecurityEnv,
  userId: string,
  threadId: string,
  access: ThreadAccess,
): Promise<{
  context: SecurityContext;
  thread: Thread;
  spaceId: string;
}> {
  const row = await loadThreadRow(env, threadId);
  const user = await env.SYNTILA_DB.prepare(
    "SELECT id, email, display_name AS displayName, status FROM users WHERE id = ?1",
  )
    .bind(userId)
    .first<AuthenticatedUser>();
  if (!user) throw new HttpError(403, `Thread ${access} access is required`);
  const spaceId = String(row.spaceId);
  try {
    const { role } = await authorizeSpaceMembership(
      env.SYNTILA_DB,
      { userId, user },
      spaceId,
      threadAccessPermission(access),
    );
    const context: SecurityContext = {
      userId,
      user,
      spaceRoles: { [spaceId]: role },
      sessionId: "thread-request-queue",
      clientType: "web",
    };
    return await threadAccessForContext(env, context, row, access);
  } catch (error) {
    if (error instanceof AuthorizationError)
      throw new HttpError(403, `Thread ${access} access is required`);
    throw error;
  }
}

async function threadAccessForContext(
  env: SecurityEnv,
  context: SecurityContext,
  row: Record<string, unknown>,
  access: ThreadAccess,
) {
  const membership = await env.SYNTILA_DB.prepare(
    `SELECT id, space_id AS spaceId, user_id AS userId, role,
            created_at AS createdAt, updated_at AS updatedAt
     FROM space_memberships WHERE space_id = ?1 AND user_id = ?2`,
  )
    .bind(String(row.spaceId), context.userId)
    .first<SpaceMembership>();
  const policy = await loadSpacePermissions(
    env,
    context.userId,
    String(row.spaceId),
  );
  const effectiveMembership = membership
    ? { ...membership, permissions: policy.rights }
    : null;
  const thread: Thread = {
    id: String(row.id),
    spaceId: String(row.spaceId),
    name: String(row.name),
    status: String(row.status) as Thread["status"],
    accessPolicy: {
      ...DEFAULT_THREAD_ACCESS_POLICY,
      ...parseJson(row.accessPolicyJson, {}),
    },
    lead: {
      userId: String(row.leadUserId),
      assignedAt: String(row.createdAt),
      assignedByUserId: String(row.leadUserId),
    },
    createdAt: String(row.createdAt),
    updatedAt: String(row.updatedAt),
  };
  const spaceKind = (row.spaceKind as SpaceKind) ?? "group";
  const allowed =
    access === "view"
      ? canViewThread(context.userId, effectiveMembership, thread)
      : access === "discuss"
        ? canDiscussThread(context.userId, effectiveMembership, thread)
        : access === "execute"
          ? canExecuteThread(context.userId, effectiveMembership, thread)
          : canManageThread(
              context.userId,
              effectiveMembership,
              thread,
              spaceKind,
            );
  if (!allowed) throw new HttpError(403, `Thread ${access} access is required`);
  return { context, thread, spaceId: String(row.spaceId) };
}

export type WorkEligibilityIssue = {
  stepKind: string;
  workerTypeId: string | null;
  code: string;
  message: string;
};

export function eligibilityMessage(
  stepKind: string,
  workerTypeId: string | null,
  code: string,
  readinessIssueCode?: string | null,
  displayName?: string | null,
): string {
  const step = stepKind[0]?.toUpperCase() + stepKind.slice(1);
  const worker =
    displayName?.trim() || (workerTypeId ? "Selected Worker" : "Worker");
  if (code === "binding_missing") return `${step}: choose a Worker.`;
  if (code === "worker_missing")
    return `${step}: the selected Worker is no longer available.`;
  if (code === "space_workspace_grant_missing")
    return `${step}: select this Worker's Workspace in the Space Workflows tab.`;
  if (code === "worker_disabled") return `${step}: ${worker} is disabled.`;
  if (code === "worker_not_ready") {
    if (
      readinessIssueCode === "sign_in_required" ||
      readinessIssueCode === "provider_authentication_required"
    ) {
      return `${step}: ${worker} needs sign-in.`;
    }
    return `${step}: ${worker} is not Ready${readinessIssueCode ? ` (${readinessIssueCode.replaceAll("_", " ")})` : ""}.`;
  }
  if (code === "worker_catalog_unavailable")
    return `${step}: this Worker is no longer available in the Workspace catalog.`;
  if (code === "plugin_entitlement_required")
    return `${step}: ${worker} is a custom plugin and needs an active Syntila Plus plan.`;
  if (code === "plugin_not_enabled")
    return `${step}: ${worker} is not enabled on this Workspace.`;
  if (code === "plugin_digest_not_pinned")
    return `${step}: ${worker} changed since it was enabled; enable the current version again.`;
  if (code === "worker_engine_update_required")
    return `${step}: ${worker} needs a newer Syntila Workspace (Engine 1.4.0 or newer).`;
  if (code === "worker_scheduling_disabled")
    return `${step}: ${worker} is not enabled for scheduling.`;
  if (code === "permission_not_granted")
    return `${step}: the Space Workspace grant does not allow the access this Step needs.`;
  if (code === "worker_not_allowed_by_grant")
    return `${step}: this Worker is not included in the Space Workspace grant.`;
  if (code === "worker_type_not_allowed_by_thread")
    return `${step}: this Worker type is not allowed by the Thread execution policy.`;
  if (code === "workspace_offline")
    return `${step}: the Worker's Workspace is offline.`;
  if (code === "workspace_mismatch")
    return `${step}: all Steps in this Workflow must use Workers from the same Workspace.`;
  if (code === "workspace_not_primary")
    return `${step}: the Worker must be on this Thread's primary Workspace.`;
  if (code === "engine_profile_unavailable")
    return `${step}: the Worker has no compatible Engine and Tool Profile release.`;
  if (code === "model_not_allowed")
    return `${step}: the selected model is not allowed by this Thread.`;
  if (code === "model_required")
    return `${step}: choose a model allowed by this Thread.`;
  if (code === "runtime_coordinator_unavailable")
    return "Thread execution coordination is unavailable. Try again later.";
  return `${step}: ${worker} is not eligible to run this Work.`;
}

export async function validateWorkflowWorkerEligibility(
  env: SecurityEnv,
  spaceId: string,
  threadId: string,
  workflow: BuiltinWorkflowDefinition,
  bindings: Record<
    string,
    {
      workerId?: string;
      model?: string;
      reasoningEffort?: string;
      catalogRevision?: string;
    }
  >,
): Promise<{
  issues: WorkEligibilityIssue[];
  primaryWorkspaceId: string | null;
  workerCatalogRevisions: Record<string, string>;
  /** Model identity metadata per binding, for Research model diversity. */
  workerModelCatalogs: Record<string, ModelIdentityCatalog>;
  workerProfiles: Record<
    string,
    { profileId: string; profileReleaseVersion: number }
  >;
}> {
  const workerCatalogRevisions: Record<string, string> = {};
  const workerModelCatalogs: Record<string, ModelIdentityCatalog> = {};
  const issues: WorkEligibilityIssue[] = [];
  const workerProfiles: Record<
    string,
    { profileId: string; profileReleaseVersion: number }
  > = {};
  let primaryWorkspaceId: string | null = null;
  const now = new Date().toISOString();
  for (const step of workflow.steps) {
    // A tool call has no Worker; the Workspace admits it when it runs.
    if (step.kind === "tool_call") continue;
    // A step-instance binding (Research v2 role) wins over the kind binding.
    const bindingId =
      workflow.id === "direct"
        ? "direct"
        : bindings[stepInstanceId(step)]
          ? stepInstanceId(step)
          : step.kind;
    const binding = bindings[bindingId];
    if (!binding?.workerId) {
      issues.push({
        stepKind: step.kind,
        workerTypeId: null,
        code: "binding_missing",
        message: eligibilityMessage(step.kind, null, "binding_missing"),
      });
      continue;
    }
    const row = await env.SYNTILA_DB.prepare(
      `SELECT i.workspace_id AS workspaceId, i.worker_type_id AS workerTypeId,
              i.activation_state AS activationState, i.readiness_state AS readinessState,
              i.readiness_issue_code AS readinessIssueCode,
              i.engine_version AS engineVersion,
              COALESCE(i.profile_definition_id,
                       CASE WHEN catalog.origin = 'plugin' THEN i.worker_type_id END)
                AS profileDefinitionId,
              COALESCE(i.profile_release_version,
                       CASE WHEN catalog.origin = 'plugin' THEN 1 END)
                AS profileReleaseVersion,
              i.provider_tool_version AS providerToolVersion,
              catalog.origin AS workerCatalogOrigin,
              catalog.owner_user_id AS workerCatalogOwnerUserId,
              ew.owner_user_id AS workspaceOwnerUserId,
              i.executor_json AS executorJson,
              pe.version AS pluginPinVersion,
              pe.manifest_digest AS pluginPinDigest,
              pe.intent AS pluginPinIntent,
              ${pluginOwnerEntitledSql("ew.owner_user_id")} AS pluginOwnerEntitled,
              COALESCE(currentProfile.profile_json, history.profile_json) AS executionProfileJson,
              COALESCE(currentProfile.digest, history.digest) AS executionProfileDigest,
              i.model_catalog_json AS modelCatalogJson,
              catalog.lifecycle_state AS workerCatalogLifecycleState,
              catalog.visibility_state AS workerCatalogVisibilityState,
              catalog.display_name AS workerDisplayName,
              vs.state AS schedulingState,
              g.id AS grantId, g.status AS grantStatus, g.expires_at AS grantExpiresAt,
              g.allowed_worker_ids_json AS allowedWorkerIdsJson,
              g.allowed_permissions_json AS grantPermissionsJson,
              ep.allowed_models_json AS allowedModelsJson,
              ep.primary_workspace_id AS primaryWorkspaceId,
              ep.allowed_worker_type_ids_json AS allowedThreadWorkerTypesJson,
              ew.status AS workspaceStatus,
              wri.id AS runtimeIdentityId
         FROM workspace_worker_inventory i
         LEFT JOIN worker_catalog catalog
           ON catalog.worker_type_id = i.worker_type_id
         LEFT JOIN worker_profiles currentProfile
           ON currentProfile.worker_type_id = i.worker_type_id
          AND currentProfile.revision = i.profile_release_version
         LEFT JOIN worker_profile_history history
           ON history.worker_type_id = i.worker_type_id
          AND history.revision = i.profile_release_version
         LEFT JOIN worker_scheduling vs ON vs.worker_id = i.worker_id
         LEFT JOIN workspace_worker_plugin_enablements pe
           ON pe.workspace_id = i.workspace_id AND pe.plugin_ref = i.worker_type_id
         -- Revoked and expired grants stay as history; only a live grant
         -- (active or suspended) may answer, never an older revoked row.
         LEFT JOIN workspace_space_grants g
           ON g.workspace_id = i.workspace_id AND g.space_id = ?2
          AND g.status IN ('active','suspended')
         LEFT JOIN thread_execution_policies ep ON ep.thread_id = ?3
         LEFT JOIN execution_workspaces ew ON ew.id = i.workspace_id
         LEFT JOIN workspace_runtime_identities wri ON wri.workspace_id = i.workspace_id AND wri.revoked_at IS NULL
        WHERE i.worker_id = ?1`,
    )
      .bind(binding.workerId, spaceId, threadId)
      .first<Record<string, unknown>>();
    if (!row) {
      const code = "worker_missing";
      issues.push({
        stepKind: step.kind,
        workerTypeId: null,
        code,
        message: eligibilityMessage(step.kind, null, code),
      });
      continue;
    }
    const workerTypeId = String(row.workerTypeId);
    const push = (code: string) =>
      issues.push({
        stepKind: step.kind,
        workerTypeId,
        code,
        message: eligibilityMessage(
          step.kind,
          workerTypeId,
          code,
          row.readinessIssueCode == null
            ? null
            : String(row.readinessIssueCode),
          row.workerDisplayName == null ? null : String(row.workerDisplayName),
        ),
      });
    const isPlugin = row.workerCatalogOrigin === "plugin";
    let pluginDigest: string | null = null;
    if (
      row.workerCatalogLifecycleState !== "active" ||
      row.workerCatalogVisibilityState !== "visible" ||
      (isPlugin && row.workerCatalogOwnerUserId !== row.workspaceOwnerUserId)
    ) {
      push("worker_catalog_unavailable");
    }
    if (isPlugin) {
      // Plugins have no Tool Profile: Cloud checks the owner's plan, the pin
      // and the digest the Service reported (ADR-027).
      const reported = (() => {
        try {
          const parsed = PluginInventoryExecutorSchema.safeParse(
            JSON.parse(String(row.executorJson)),
          );
          return parsed.success ? parsed.data : null;
        } catch {
          return null;
        }
      })();
      if (!Number(row.pluginOwnerEntitled)) push("plugin_entitlement_required");
      if (row.pluginPinIntent !== "enabled") push("plugin_not_enabled");
      if (
        !reported ||
        !reported.artifactDigest ||
        reported.manifestDigest !== row.pluginPinDigest ||
        reported.version !== row.pluginPinVersion
      )
        push("plugin_digest_not_pinned");
      else pluginDigest = reported.manifestDigest;
      if (!supportsPluginExecutor(row.engineVersion))
        push("worker_engine_update_required");
    } else if (
      row.executionProfileJson == null ||
      typeof row.executionProfileDigest !== "string"
    )
      push("engine_profile_unavailable");
    if (
      row.grantId == null ||
      row.grantStatus !== "active" ||
      (row.grantExpiresAt != null && String(row.grantExpiresAt) <= now)
    )
      push("space_workspace_grant_missing");
    if (row.activationState !== "enabled") push("worker_disabled");
    if (row.readinessState !== "ready") push("worker_not_ready");
    if (row.schedulingState !== "enabled") push("worker_scheduling_disabled");
    if (
      typeof row.engineVersion !== "string" ||
      !row.engineVersion ||
      typeof row.profileDefinitionId !== "string" ||
      !row.profileDefinitionId ||
      !Number.isSafeInteger(Number(row.profileReleaseVersion)) ||
      Number(row.profileReleaseVersion) < 1
    )
      push("engine_profile_unavailable");
    if (row.workspaceStatus !== "online") push("workspace_offline");
    if (row.runtimeIdentityId == null) push("workspace_offline");
    // Worker/Profile capability metadata is intentionally not part of
    // eligibility. Workflow enablement and access policy are owned by Cloud;
    // the selected Profile only supplies the engine invocation contract.
    const rawGrantPermissions = parseJson<unknown>(
      row.grantPermissionsJson,
      null,
    );
    if (!validateWorkspaceGrantPermissions(rawGrantPermissions)) {
      push("workspace_grant_policy_invalid");
    }
    const grantPermissions = validateWorkspaceGrantPermissions(
      rawGrantPermissions,
    )
      ? rawGrantPermissions
      : [];
    const requiredPermissions = new Set<string>(["repository:read"]);
    if (step.requiredCapabilities.includes("thread_write"))
      requiredPermissions.add("repository:write");
    if (step.requiredCapabilities.includes("test_execution"))
      requiredPermissions.add("shell:execute");
    const grantPermissionSet = new Set<string>(grantPermissions);
    if (
      ![...requiredPermissions].every((permission) =>
        grantPermissionSet.has(permission),
      )
    )
      push("permission_not_granted");
    const rawAllowedWorkerIds = parseJson<unknown>(
      row.allowedWorkerIdsJson,
      null,
    );
    if (!validateWorkspaceGrantWorkerIds(rawAllowedWorkerIds)) {
      push("workspace_grant_policy_invalid");
    }
    const allowedWorkerIds = validateWorkspaceGrantWorkerIds(
      rawAllowedWorkerIds,
    )
      ? rawAllowedWorkerIds
      : [];
    if (
      allowedWorkerIds.length > 0 &&
      !allowedWorkerIds.includes(binding.workerId)
    )
      push("worker_not_allowed_by_grant");
    const allowedThreadTypes = parseJson<unknown[]>(
      row.allowedThreadWorkerTypesJson,
      [],
    ).filter((value): value is string => typeof value === "string");
    if (
      allowedThreadTypes.length > 0 &&
      !allowedThreadTypes.includes(workerTypeId)
    )
      push("worker_type_not_allowed_by_thread");
    const executionOptions = isPlugin
      ? pluginDigest
        ? pluginExecutionOptions(
            pluginDigest,
            row.modelCatalogJson,
            row.providerToolVersion,
          )
        : null
      : spaceWorkerExecutionOptions(
          row.executionProfileJson,
          row.providerToolVersion,
          row.modelCatalogJson,
          row.executionProfileDigest,
        );
    if (!executionOptions) {
      issues.push({
        stepKind: step.kind,
        workerTypeId,
        code: "profile_execution_option_unavailable",
        message: `${step.kind}: Worker capabilities are unavailable; refresh the Workspace catalog.`,
      });
    }
    if (executionOptions) {
      if (executionOptions.schemaVersion === 2) {
        workerCatalogRevisions[bindingId] = executionOptions.catalogRevision;
        // Catalogs carry no alias metadata yet, so identity is the listed ID
        // (case-insensitive); pass-through Workers accept custom IDs.
        workerModelCatalogs[bindingId] = {
          models: [
            ...executionOptions.models.allowedModelIds,
            ...executionOptions.models.options.map((option) => option.id),
          ],
          allowsCustomModels: executionOptions.models.allowsCustomModel,
        };
      }
      const error = validateWorkerExecutionSelection(
        executionOptions,
        binding.model ?? null,
        binding.reasoningEffort ?? null,
        binding.catalogRevision,
      );
      if (error)
        issues.push({
          stepKind: step.kind,
          workerTypeId,
          code: "profile_execution_option_unavailable",
          message: `${step.kind}: ${error}.`,
        });
    }
    const allowedModels = parseJson<unknown[]>(
      row.allowedModelsJson,
      [],
    ).filter((value): value is string => typeof value === "string");
    if (allowedModels.length > 0 && !binding.model?.trim())
      push("model_required");
    else if (
      binding.model?.trim() &&
      allowedModels.length > 0 &&
      !allowedModels.includes(binding.model)
    )
      push("model_not_allowed");
    if (
      typeof row.profileDefinitionId === "string" &&
      Number.isSafeInteger(Number(row.profileReleaseVersion))
    ) {
      workerProfiles[bindingId] = {
        profileId: row.profileDefinitionId,
        profileReleaseVersion: Number(row.profileReleaseVersion),
      };
    }
    if (primaryWorkspaceId == null)
      primaryWorkspaceId = String(row.workspaceId);
    else if (primaryWorkspaceId !== String(row.workspaceId))
      push("workspace_mismatch");
    if (
      row.primaryWorkspaceId != null &&
      String(row.primaryWorkspaceId) !== String(row.workspaceId)
    )
      push("workspace_not_primary");
  }
  return {
    issues,
    primaryWorkspaceId,
    workerProfiles,
    workerCatalogRevisions,
    workerModelCatalogs,
  };
}

export function summarizeTestCounts(text: string): string | null {
  const counts: string[] = [];
  for (const status of ["failed", "passed", "skipped"] as const) {
    const matches = text.matchAll(
      new RegExp(`\\b(\\d+)\\s+(?:tests?\\s+)?${status}\\b`, "gi"),
    );
    const match = [...matches].at(-1);
    if (match) counts.push(`${match[1]} ${status}`);
  }
  return counts.length > 0 ? counts.join(", ") : null;
}
