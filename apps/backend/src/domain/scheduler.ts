import {
  canRevalidateAcceptedSelection,
  resolveExecutionSelectionSnapshot,
  supportsExecutionCatalogPin,
  supportsPluginExecutor,
} from "./execution-selection-snapshot.js";
import {
  pluginExecutionOptions,
  spaceWorkerExecutionOptions,
} from "./worker-execution-options.js";
import { pluginOwnerEntitledSql } from "./account-plan.js";
import {
  PluginInventoryExecutorSchema,
  type PluginSnapshotExecutor,
} from "@syntila/workspace-runtime-protocol";
import { validateWorkerExecutionSelection } from "@syntila/core";
import { spaceMemberPermissions } from "@syntila/security";
import {
  EXECUTION_PERMISSIONS,
  isWorkspaceSpaceGrantStatus,
  resolveExecutionPermissions,
  validateWorkspaceConcurrencyPolicy,
  validateWorkspaceGrantPermissions,
  validateWorkspaceGrantWorkerIds,
  validateWorkspaceNetworkPolicy,
} from "@syntila/core";
import { ACTIVE_ASSIGNMENT_STATUS_SQL } from "./assignment-transitions.js";

export interface SpaceExecutionSelectionRequest {
  readonly spaceId: string;
  readonly requesterUserId: string;
  readonly role: string;
  readonly capabilities: readonly string[];
  readonly workspaceId?: string;
  readonly workerId?: string;
  readonly excludeIndependenceKeys?: readonly string[];
  readonly model?: string;
  readonly reasoningEffort?: string;
  readonly catalogRevision?: string;
  readonly executionClass?: "stateless_read" | "stateful_thread";
  /** Read-only capability policy independent of Thread lease ownership. */
  readonly readOnly?: boolean;
  readonly threadId?: string;
  readonly workRequestId?: string;
  /** Accepted binding key: a legacy binding or a Research step-instance ID. */
  readonly workBindingId?: string;
  /** Dispatchers may admit a durable local queue; the Service still enforces
   * the returned effective limit before starting a process. */
  readonly allowQueue?: boolean;
}

export interface ExecutionTarget {
  readonly spaceId: string;
  readonly workspaceId: string;
  readonly workspaceRuntimeIdentityId: string;
  readonly workspaceSpaceGrantId: string;
  /** Local Worker identity selected for this assignment. */
  readonly workerId: string;
  /** Product Worker Type ID reported by Workspace and selected by policy. */
  readonly workerTypeId: string;
  readonly engineVersion: string;
  readonly profileDefinitionId: string;
  readonly profileReleaseVersion: number;
  readonly providerToolName: string | null;
  readonly providerToolVersion: string | null;
  readonly model: string | null;
  readonly reasoningEffort?: string | null;
  readonly effectivePermissions: readonly string[];
  /** Immutable effective capacity enforced by the Workspace Service. */
  readonly maxConcurrentAssignments: number;
  readonly permissionSnapshot: Record<string, unknown>;
  readonly selectionExplanation: Record<string, unknown>;
  readonly executionClass: "stateless_read" | "stateful_thread";
  readonly readOnly: boolean;
  readonly threadId?: string;
  readonly workRequestId?: string;
  readonly conversationId?: string;
  readonly baseContextRevision?: number;
  readonly leaseId?: string;
  readonly fencingToken?: number;
}

/**
 * Service availability as the scheduler needs it. `ready` (or `true`) means
 * the Service will handle a command immediately; `connected` means the
 * transport is live but the Service is still synchronizing, paused or
 * draining, so work may only be queued; `false` means disconnected.
 */
export type WorkspaceLiveState = boolean | "connected" | "ready";

export type WorkspaceLiveCheck = (
  workspaceId: string,
  runtimeIdentityId: string,
) => Promise<WorkspaceLiveState>;

type Row = Record<string, unknown>;

function strings(value: unknown): string[] {
  if (typeof value !== "string") return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === "string")
      : [];
  } catch {
    return [];
  }
}

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== "string") return {};
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : {};
  } catch {
    return {};
  }
}

function number(value: unknown, fallback = 0): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function parsedGrantJson<T>(
  value: unknown,
  validate: (parsed: unknown) => parsed is T,
): T | null {
  if (typeof value !== "string") return null;
  try {
    const parsed: unknown = JSON.parse(value);
    return validate(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function allowedByJson(row: Row, key: string, value: string): boolean {
  const allowed = strings(row[key]);
  return allowed.length === 0 || allowed.includes(value);
}

/**
 * Resolves an execution target for a Space. The returned explanation is
 * persisted with the assignment.
 */
export async function selectSpaceExecutionTarget(
  db: D1Database,
  request: SpaceExecutionSelectionRequest,
  now = new Date(),
  isWorkspaceLive?: WorkspaceLiveCheck,
  onRejection?: (reasons: readonly string[]) => void,
): Promise<ExecutionTarget | null> {
  const membership = await db
    .prepare(
      `SELECT sm.role, s.settings_json AS settingsJson FROM space_memberships sm JOIN spaces s ON s.id = sm.space_id JOIN users u ON u.id = sm.user_id WHERE u.status = 'active' AND sm.space_id = ?1 AND sm.user_id = ?2`,
    )
    .bind(request.spaceId, request.requesterUserId)
    .first<{ role: string; settingsJson: string }>();
  if (!membership) return null;
  const rights = spaceMemberPermissions(
    membership.role,
    membership.settingsJson,
    request.requesterUserId,
  );
  let workflowId = request.workBindingId === "chat" ? "chat" : "direct";
  if (request.workRequestId) {
    const work = await db
      .prepare(
        "SELECT workflow_id AS workflowId, requested_by_user_id AS requesterUserId, thread_id AS threadId FROM work_requests WHERE id = ?1",
      )
      .bind(request.workRequestId)
      .first<{
        workflowId: string;
        requesterUserId: string;
        threadId: string;
      }>();
    if (
      !work ||
      work.requesterUserId !== request.requesterUserId ||
      work.threadId !== request.threadId
    )
      return null;
    workflowId = work.workflowId;
  }
  if (workflowId === "chat" ? !rights.chat : !rights.work) return null;

  if (request.threadId) {
    const thread = await db
      .prepare(
        `SELECT ws.space_id, ws.lead_user_id, ws.access_policy_json
           FROM threads ws
          WHERE ws.id = ?1`,
      )
      .bind(request.threadId)
      .first<Record<string, unknown>>();
    if (
      !thread ||
      typeof thread.space_id !== "string" ||
      thread.space_id !== request.spaceId
    ) {
      return null;
    }
    if (membership.role !== "owner") {
      const policy = object(thread.access_policy_json);
      const allowedUsers = Array.isArray(policy.allowedUserIds)
        ? policy.allowedUserIds.filter(
            (value): value is string => typeof value === "string",
          )
        : [];
      const allowedRoles = Array.isArray(policy.allowedSpaceRoles)
        ? policy.allowedSpaceRoles.filter(
            (value): value is string => typeof value === "string",
          )
        : [];
      const allowedPermissions = Array.isArray(policy.allowedPermissions)
        ? policy.allowedPermissions.filter(
            (value): value is string => typeof value === "string",
          )
        : [];
      if (
        (allowedUsers.length > 0 &&
          !allowedUsers.includes(request.requesterUserId)) ||
        (allowedRoles.length > 0 && !allowedRoles.includes(membership.role)) ||
        !allowedPermissions.includes("execute")
      ) {
        return null;
      }
    }
  }

  const executionClass = request.executionClass ?? "stateless_read";
  let statefulLease: {
    threadId: string;
    workRequestId: string;
    workspaceId: string;
    leaseId: string;
    fencingToken: number;
  } | null = null;
  if (executionClass === "stateful_thread") {
    if (!request.threadId || !request.workRequestId) return null;
    statefulLease = await db
      .prepare(
        `SELECT wr.thread_id AS threadId, wr.id AS workRequestId,
              wr.primary_workspace_id AS workspaceId,
              l.id AS leaseId, l.fencing_token AS fencingToken
       FROM work_requests wr
       JOIN thread_runtime_leases l ON l.work_request_id = wr.id
        AND l.thread_id = wr.thread_id AND l.status = 'active'
       WHERE wr.id = ?1 AND wr.thread_id = ?2
         AND wr.mode = 'stateful' AND wr.status = 'running'
       LIMIT 1`,
      )
      .bind(request.workRequestId, request.threadId)
      .first<Record<string, unknown>>()
      .then((row) => {
        if (!row) return null;
        return {
          threadId: String(row.threadId),
          workRequestId: String(row.workRequestId),
          workspaceId: String(row.workspaceId),
          leaseId: String(row.leaseId),
          fencingToken: number(row.fencingToken),
        };
      });
    if (
      !statefulLease ||
      (request.workspaceId && request.workspaceId !== statefulLease.workspaceId)
    )
      return null;
  }

  const candidateRows = await db
    .prepare(
      `SELECT g.id AS grant_id, g.space_id, g.workspace_id, g.status AS grant_status,
            g.allowed_worker_ids_json,
            g.allowed_permissions_json, g.network_policy_json,
            g.concurrency_json, g.expires_at,
            ep.allowed_worker_type_ids_json,
            ep.allowed_models_json,
            wr.snapshot_json AS work_request_snapshot_json,
            (SELECT conversation_id FROM conversation_work_requests WHERE work_request_id = wr.id) AS conversation_id,
            (SELECT cr.conversation_revision - 1 FROM conversation_work_requests cr WHERE cr.work_request_id = wr.id) AS base_context_revision,
            ew.name AS workspace_name, ew.owner_user_id, ew.status AS workspace_status,
            owner_user.display_name AS workspace_owner_name,
            (SELECT sws.workspace_id FROM space_workflow_settings sws
              WHERE sws.space_id = g.space_id) AS space_workflow_workspace_id,
            wri.id AS runtime_identity_id,
            i.worker_id, i.worker_type_id,
            catalog.display_name AS worker_display_name,
            catalog.lifecycle_state AS worker_catalog_lifecycle_state,
            catalog.visibility_state AS worker_catalog_visibility_state,
            catalog.origin AS worker_catalog_origin,
            catalog.owner_user_id AS worker_catalog_owner_user_id,
            i.engine_version AS engine_version,
            -- A plugin has no Tool Profile; its stable identity is its ref.
            COALESCE(i.profile_definition_id,
                     CASE WHEN catalog.origin = 'plugin' THEN i.worker_type_id END)
              AS profile_definition_id,
            COALESCE(i.profile_release_version,
                     CASE WHEN catalog.origin = 'plugin' THEN 1 END)
              AS profile_release_version,
            i.executor_json AS executor_json,
            pe.version AS plugin_pin_version,
            pe.manifest_digest AS plugin_pin_digest,
            pe.intent AS plugin_pin_intent,
            pe.shareable AS plugin_pin_shareable,
            ${pluginOwnerEntitledSql("ew.owner_user_id")} AS plugin_owner_entitled,
            i.provider_tool_name,
            i.provider_tool_version,
            i.model_catalog_json,
            COALESCE(current_profile.profile_json, history.profile_json)
              AS execution_profile_json,
            COALESCE(current_profile.digest, history.digest)
              AS execution_profile_digest,
            i.activation_state AS local_worker_activation_state,
            i.readiness_state AS local_worker_readiness_state,
            vs.state AS cloud_scheduling_state,
            vs.cloud_concurrency_limit,
            -- One Workspace-wide slot total; the per-Worker value is only a
            -- fallback for a Service that has not reported it yet.
            COALESCE(ew.parallel_slots, i.local_concurrency_limit)
              AS local_concurrency_limit,
            (SELECT COUNT(*) FROM worker_assignments wa
             WHERE wa.execution_workspace_id = g.workspace_id
               AND wa.workspace_worker_id = i.worker_id
               AND wa.status IN (${ACTIVE_ASSIGNMENT_STATUS_SQL})) AS active_assignments,
            (SELECT COUNT(*) FROM worker_assignments wa
             WHERE wa.execution_workspace_id = g.workspace_id
               AND wa.status IN (${ACTIVE_ASSIGNMENT_STATUS_SQL})) AS workspace_active_assignments
     FROM workspace_space_grants g
     LEFT JOIN thread_execution_policies ep ON ep.thread_id = ?4
     JOIN execution_workspaces ew ON ew.id = g.workspace_id
     LEFT JOIN users owner_user ON owner_user.id = ew.owner_user_id
     LEFT JOIN work_requests wr ON wr.id = ?5 AND wr.thread_id = ?4
     JOIN workspace_runtime_identities wri ON wri.workspace_id = ew.id AND wri.revoked_at IS NULL
     JOIN workspace_worker_inventory i ON i.workspace_id = ew.id
     JOIN worker_catalog catalog
       ON catalog.worker_type_id = i.worker_type_id
      AND catalog.lifecycle_state = 'active'
      AND catalog.visibility_state = 'visible'
      -- A plugin is only ever schedulable on its owner's own Workspace.
      AND (catalog.origin = 'official' OR catalog.owner_user_id = ew.owner_user_id)
     LEFT JOIN workspace_worker_plugin_enablements pe
       ON pe.workspace_id = i.workspace_id AND pe.plugin_ref = i.worker_type_id
     LEFT JOIN worker_profiles current_profile
       ON current_profile.worker_type_id = i.worker_type_id
      AND current_profile.revision = i.profile_release_version
     LEFT JOIN worker_profile_history history
       ON history.worker_type_id = i.worker_type_id
      AND history.revision = i.profile_release_version
     JOIN worker_scheduling vs ON vs.worker_id = i.worker_id
     WHERE g.space_id = ?1 AND g.status = 'active'
       AND (g.expires_at IS NULL OR g.expires_at > ?3)
       AND ew.status <> 'revoked'
       AND (catalog.origin = 'plugin'
            OR current_profile.worker_type_id IS NOT NULL
            OR history.worker_type_id IS NOT NULL)
       ${isWorkspaceLive ? "" : "AND ew.status = 'online'"}
     ORDER BY CASE WHEN i.owner_user_id = ?2 THEN 0 ELSE 1 END,
              active_assignments, ew.id, i.worker_id`,
    )
    .bind(
      request.spaceId,
      request.requesterUserId,
      now.toISOString(),
      request.threadId ?? "",
      request.workRequestId ?? "",
    )
    .all<Row>()
    .catch(() => ({ results: [] as Row[] }));

  const excluded = new Set(request.excludeIndependenceKeys ?? []);
  const rejected: Array<Record<string, unknown>> = [];
  const liveWorkspaceChecks = new Map<string, Promise<WorkspaceLiveState>>();
  // A ready Service always wins. A connected-but-unready one is used only
  // when no ready candidate qualifies, and then the work is queued durably.
  let sawUnreadyService = false;
  const bindingFor = (row: Row): Record<string, unknown> => {
    const snapshot = object(row.work_request_snapshot_json);
    const snapshotBindings =
      snapshot.resolvedBindings && typeof snapshot.resolvedBindings === "object"
        ? (snapshot.resolvedBindings as Record<string, unknown>)
        : {};
    const bindings = request.workRequestId ? snapshotBindings : {};
    const raw = request.workBindingId
      ? bindings[request.workBindingId]
      : undefined;
    return raw && typeof raw === "object" && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : {};
  };
  const candidates = [...(candidateRows.results ?? [])].sort((left, right) => {
    const preference = (row: Row): number => {
      const value = bindingFor(row);
      const preferred = [
        ...(typeof value.workerId === "string" ? [value.workerId] : []),
      ];
      const index = preferred.indexOf(String(row.worker_id));
      return index < 0 ? Number.MAX_SAFE_INTEGER : index;
    };
    const configuredFirst = preference(left) - preference(right);
    if (configuredFirst) return configuredFirst;
    const load =
      number(left.active_assignments) - number(right.active_assignments);
    return (
      load ||
      String(left.workspace_id).localeCompare(String(right.workspace_id))
    );
  });
  for (const allowUnready of [false, true]) {
    if (allowUnready && !sawUnreadyService) break;
    if (allowUnready) rejected.length = 0;
    for (const row of candidates) {
      const workspaceId = String(row.workspace_id);
      const workerId = String(row.worker_id);
      const workerTypeId = String(row.worker_type_id);
      const binding = bindingFor(row);
      const acceptedSnapshot = object(row.work_request_snapshot_json);
      const stepConfigs = acceptedSnapshot.stepExecutionConfigs as
        Record<string, unknown> | undefined;
      // Work's binding is `direct`, but its executable step is `implement`.
      // Research binds and freezes each repeated step under its instance ID.
      const stepConfigId =
        request.workBindingId === "direct"
          ? request.role
          : (request.workBindingId ?? request.role);
      const turnConfig = request.workRequestId
        ? ((stepConfigs?.[stepConfigId] ??
            acceptedSnapshot.turnExecutionConfig) as
            Record<string, unknown> | undefined)
        : undefined;
      if (stepConfigs && !stepConfigs[stepConfigId]) {
        rejected.push({
          workspaceId,
          workerId,
          reason: "step_configuration_unavailable",
        });
        continue;
      }
      if (
        turnConfig &&
        (turnConfig.schemaVersion !== 1 ||
          turnConfig.workerId !== workerId ||
          turnConfig.profileId !== row.profile_definition_id ||
          turnConfig.profileReleaseVersion !==
            Number(row.profile_release_version))
      ) {
        rejected.push({
          workspaceId,
          workerId,
          reason: "turn_configuration_unavailable",
        });
        continue;
      }
      const hasBinding = Object.keys(binding).length > 0;
      const preferredWorkerIds = [
        ...(typeof binding.workerId === "string" ? [binding.workerId] : []),
      ];
      // Worker/Profile capability metadata is legacy and is deliberately not
      // consulted for scheduling. Cloud workflow policy and explicit grant
      // permissions determine the effective execution scope.
      let selectedModel = turnConfig
        ? typeof turnConfig.modelId === "string"
          ? turnConfig.modelId
          : null
        : request.threadId &&
            typeof binding.model === "string" &&
            binding.model.trim().length > 0
          ? binding.model
          : (request.model ??
            (typeof binding.model === "string" ? binding.model : undefined));
      let selectedReasoningEffort = turnConfig
        ? typeof turnConfig.effort === "string"
          ? turnConfig.effort
          : null
        : request.threadId &&
            typeof binding.reasoningEffort === "string" &&
            binding.reasoningEffort.trim().length > 0
          ? binding.reasoningEffort
          : (request.reasoningEffort ??
            (typeof binding.reasoningEffort === "string"
              ? binding.reasoningEffort
              : undefined));
      const independenceKey = workerTypeId;
      const grantWorkerIds = parsedGrantJson(
        row.allowed_worker_ids_json,
        validateWorkspaceGrantWorkerIds,
      );
      const grantPermissions = parsedGrantJson(
        row.allowed_permissions_json,
        validateWorkspaceGrantPermissions,
      );
      const networkPolicy = parsedGrantJson(
        row.network_policy_json,
        validateWorkspaceNetworkPolicy,
      );
      const concurrency = parsedGrantJson(
        row.concurrency_json,
        validateWorkspaceConcurrencyPolicy,
      );
      const grantPolicyValid =
        isWorkspaceSpaceGrantStatus(row.grant_status) &&
        row.grant_status === "active" &&
        grantWorkerIds !== null &&
        grantPermissions !== null &&
        networkPolicy !== null &&
        concurrency !== null;
      // The Workspace reports one shared parallel slot total on every Worker
      // (`local_concurrency_limit`); it caps all Workers together, while the
      // Cloud and grant limits stay per Worker.
      const workspaceSlots = number(row.local_concurrency_limit, 0);
      const maxConcurrent = grantPolicyValid
        ? Math.min(
            workspaceSlots,
            row.cloud_concurrency_limit == null
              ? 1024
              : number(row.cloud_concurrency_limit, 0),
            concurrency.maxConcurrentAssignments,
          )
        : 0;

      const reject = (reason: string) =>
        rejected.push({ workspaceId, workerId, reason });
      if (
        row.worker_catalog_lifecycle_state !== "active" ||
        row.worker_catalog_visibility_state !== "visible"
      ) {
        reject("worker_catalog_unavailable");
        continue;
      }
      if (!grantPolicyValid) {
        reject("workspace_grant_policy_invalid");
        continue;
      }
      // Outside the Space's Workflow Workspace, Chat runs only on a Workspace
      // the requester owns, and only while the Space allows own Workers.
      if (
        workflowId === "chat" &&
        workspaceId !== String(row.space_workflow_workspace_id ?? "") &&
        (String(row.owner_user_id) !== request.requesterUserId ||
          !rights.useOwnWorkers)
      ) {
        reject("own_worker_not_allowed");
        continue;
      }
      if (statefulLease && workspaceId !== statefulLease.workspaceId) {
        reject("stateful_primary_workspace_required");
        continue;
      }
      if (!isWorkspaceLive && String(row.workspace_status) !== "online") {
        reject("workspace_offline");
        continue;
      }
      if (String(row.grant_status) !== "active") {
        reject("grant_inactive");
        continue;
      }
      if (row.cloud_scheduling_state === "draining") {
        reject("cloud_scheduling_draining");
        continue;
      }
      if (row.cloud_scheduling_state !== "enabled") {
        reject("cloud_scheduling_disabled");
        continue;
      }
      if (String(row.local_worker_activation_state) !== "enabled") {
        reject("local_worker_disabled");
        continue;
      }
      if (String(row.local_worker_readiness_state) !== "ready") {
        reject("local_worker_not_ready");
        continue;
      }
      // Custom plugin Workers (ADR-027): Cloud, not the Service, decides.
      const isPlugin = row.worker_catalog_origin === "plugin";
      let pluginExecutor: PluginSnapshotExecutor | null = null;
      if (isPlugin) {
        const reported = (() => {
          try {
            const parsed = PluginInventoryExecutorSchema.safeParse(
              JSON.parse(String(row.executor_json)),
            );
            return parsed.success ? parsed.data : null;
          } catch {
            return null;
          }
        })();
        const pluginRejection = ((): string | null => {
          if (row.worker_catalog_owner_user_id !== row.owner_user_id)
            return "worker_catalog_unavailable";
          // Live plan check; also repeated inside the assignment INSERT.
          if (!number(row.plugin_owner_entitled))
            return "plugin_entitlement_required";
          if (row.plugin_pin_intent !== "enabled") return "plugin_not_enabled";
          if (
            !reported ||
            !reported.artifactDigest ||
            reported.manifestDigest !== row.plugin_pin_digest ||
            reported.version !== row.plugin_pin_version
          )
            return "plugin_digest_not_pinned";
          if (!supportsPluginExecutor(row.engine_version))
            return "worker_engine_update_required";
          // Someone else's request on the owner's Workspace needs an opt-in.
          if (
            String(row.owner_user_id) !== request.requesterUserId &&
            number(row.plugin_pin_shareable) !== 1
          )
            return "plugin_not_shareable";
          // No isolation tier proves read-only for an External Worker yet. A
          // read-only Step still runs on one: the Engine passes
          // `access: restricted` and states it in the request (simulated,
          // not enforced), which the owner accepted in the consent document.
          return null;
        })();
        if (pluginRejection || !reported) {
          reject(pluginRejection ?? "plugin_digest_not_pinned");
          continue;
        }
        pluginExecutor = {
          schemaVersion: 1,
          kind: "plugin",
          pluginRef: workerTypeId,
          pluginId: reported.pluginId,
          version: reported.version,
          manifestDigest: reported.manifestDigest,
          artifactDigest: reported.artifactDigest!,
          pluginProtocol: reported.pluginProtocol,
          isolation: reported.isolation,
        };
      }
      if (
        typeof row.engine_version !== "string" ||
        !row.engine_version ||
        typeof row.profile_definition_id !== "string" ||
        !row.profile_definition_id ||
        !Number.isSafeInteger(Number(row.profile_release_version)) ||
        Number(row.profile_release_version) < 1
      ) {
        reject("engine_profile_unavailable");
        continue;
      }
      const executionOptions = pluginExecutor
        ? pluginExecutionOptions(
            pluginExecutor.manifestDigest,
            row.model_catalog_json,
            row.provider_tool_version,
          )
        : spaceWorkerExecutionOptions(
            row.execution_profile_json,
            row.provider_tool_version,
            row.model_catalog_json,
            row.execution_profile_digest,
          );
      let expectedRevision =
        typeof binding.catalogRevision === "string"
          ? binding.catalogRevision
          : request.catalogRevision;
      // Acceptance freezes Worker/Profile/model/effort, not unrelated catalog
      // entries. A later step can use a refreshed catalog if its exact explicit
      // selection is still supported. Pin the new revision for this assignment;
      // never substitute a Worker, Profile, model, effort, or Auto default.
      const catalogRevalidated =
        canRevalidateAcceptedSelection(executionOptions, turnConfig, {
          workerId,
          profileId: String(row.profile_definition_id),
          profileReleaseVersion: Number(row.profile_release_version),
        }) &&
        executionOptions?.schemaVersion === 2 &&
        expectedRevision != null &&
        expectedRevision !== executionOptions.catalogRevision;
      if (catalogRevalidated)
        expectedRevision = executionOptions.catalogRevision;
      const selectionError = executionOptions
        ? validateWorkerExecutionSelection(
            executionOptions,
            selectedModel ?? null,
            selectedReasoningEffort ?? null,
            expectedRevision,
          )
        : "Worker capabilities are unavailable";
      if (selectionError) {
        reject(`profile_execution_option_unavailable: ${selectionError}`);
        continue;
      }
      if (
        executionOptions?.schemaVersion === 2 &&
        executionOptions.models.discovery === "provider_catalog" &&
        !supportsExecutionCatalogPin(row.engine_version)
      ) {
        reject(
          "worker_engine_update_required: catalog-pinned execution requires Engine 1.3.0 or newer",
        );
        continue;
      }
      let executionSelection;
      try {
        executionSelection = resolveExecutionSelectionSnapshot(
          executionOptions!,
          {
            modelId: selectedModel ?? null,
            effort: selectedReasoningEffort ?? null,
            catalogRevision: expectedRevision,
          },
          {
            workerTypeId,
            workerDisplayName: String(row.worker_display_name ?? workerTypeId),
            profileReleaseVersion: Number(row.profile_release_version),
          },
        );
        // The admitted plugin identity is frozen with the selection, so a
        // later update, retry or queue wait cannot change what runs.
        if (pluginExecutor)
          executionSelection = {
            ...executionSelection,
            executor: pluginExecutor,
          };
        selectedModel = executionSelection.modelId;
        selectedReasoningEffort = executionSelection.effort;
      } catch (error) {
        reject(`profile_execution_option_unavailable: ${String(error)}`);
        continue;
      }
      if (request.threadId && !hasBinding) {
        reject("thread_step_binding_missing");
        continue;
      }
      if (request.workspaceId && request.workspaceId !== workspaceId) {
        reject("explicit_workspace_mismatch");
        continue;
      }
      if (
        request.threadId &&
        (preferredWorkerIds.length === 0 ||
          !preferredWorkerIds.includes(workerId))
      ) {
        reject(
          preferredWorkerIds.length === 0
            ? "no_worker_selected_for_step"
            : "worker_not_selected_for_step",
        );
        continue;
      }
      if (request.workerId && request.workerId !== workerId) {
        reject("explicit_worker_mismatch");
        continue;
      }
      if (grantWorkerIds.length > 0 && !grantWorkerIds.includes(workerId)) {
        reject("worker_not_allowed_by_grant");
        continue;
      }
      if (!allowedByJson(row, "allowed_worker_type_ids_json", workerTypeId)) {
        reject("worker_type_not_allowed_by_thread");
        continue;
      }
      const allowedModels = strings(row.allowed_models_json);
      if (
        allowedModels.length > 0 &&
        (!selectedModel || !allowedModels.includes(selectedModel))
      ) {
        reject("model_not_allowed_by_thread");
        continue;
      }
      if (excluded.has(independenceKey)) {
        reject("provider_independence_conflict");
        continue;
      }
      if (
        !request.allowQueue &&
        (number(row.active_assignments) >= maxConcurrent ||
          number(row.workspace_active_assignments) >= workspaceSlots)
      ) {
        reject("worker_concurrency_limit");
        continue;
      }

      const resolvedPermissions = resolveExecutionPermissions(
        rights.work ? [...EXECUTION_PERMISSIONS] : ["repository:read"],
        grantPermissions,
      );
      // Read-only steps may keep the active Thread lease so they inspect its
      // current filesystem, while dropping repository writes. Test alone retains
      // shell execution so it can run validation commands inside the read-only
      // provider sandbox.
      const canRunTestCommands =
        request.capabilities.includes("test_execution");
      const permissions =
        executionClass === "stateless_read" || request.readOnly === true
          ? resolvedPermissions.filter(
              (permission) =>
                permission !== "repository:write" &&
                (permission !== "shell:execute" || canRunTestCommands),
            )
          : resolvedPermissions;
      if (permissions.length === 0) {
        reject("effective_permission_intersection_empty");
        continue;
      }
      let workspaceIsLive = false;
      let workspaceReadiness: "ready" | "connected" = "ready";
      if (isWorkspaceLive) {
        const runtimeIdentityId = String(row.runtime_identity_id);
        const key = `${workspaceId}:${runtimeIdentityId}`;
        let liveCheck = liveWorkspaceChecks.get(key);
        if (!liveCheck) {
          liveCheck = isWorkspaceLive(workspaceId, runtimeIdentityId).catch(
            () => false,
          );
          liveWorkspaceChecks.set(key, liveCheck);
        }
        const liveState = await liveCheck;
        workspaceIsLive = liveState !== false;
        if (!workspaceIsLive) {
          reject("workspace_offline");
          continue;
        }
        if (liveState === "connected") {
          if (!allowUnready) {
            sawUnreadyService = true;
            reject("workspace_not_ready");
            continue;
          }
          workspaceReadiness = "connected";
        }
      }
      const snapshotAt = now.toISOString();
      const permissionSnapshot = {
        executionSelection,
        spaceId: request.spaceId,
        workspaceId,
        workerId,
        workerTypeId,
        grantId: String(row.grant_id),
        workerDisplayName: String(row.worker_display_name ?? workerTypeId),
        workerOwnerUserId: String(row.owner_user_id),
        // Named only for a Worker outside the Space Workflow Workspace, so
        // the header calls out a member's own Worker but not the Space's.
        workerOwnerName:
          workspaceId !== String(row.space_workflow_workspace_id ?? "") &&
          typeof row.workspace_owner_name === "string"
            ? row.workspace_owner_name
            : null,
        engineVersion: String(row.engine_version),
        profileDefinitionId: String(row.profile_definition_id),
        profileReleaseVersion: Number(row.profile_release_version),
        model: selectedModel ?? null,
        reasoningEffort: selectedReasoningEffort ?? null,
        providerToolName:
          typeof row.provider_tool_name === "string"
            ? row.provider_tool_name
            : null,
        providerToolVersion:
          typeof row.provider_tool_version === "string"
            ? row.provider_tool_version
            : null,
        requesterUserId: request.requesterUserId,
        permissions,
        networkPolicy,
        concurrency,
        threadPolicy: {
          allowedWorkerTypeIds: strings(row.allowed_worker_type_ids_json),
          allowedModels,
        },
        snapshotAt,
      };
      return {
        spaceId: request.spaceId,
        workspaceId,
        workspaceRuntimeIdentityId: String(row.runtime_identity_id),
        workspaceSpaceGrantId: String(row.grant_id),
        workerId,
        workerTypeId,
        engineVersion: String(row.engine_version),
        profileDefinitionId: String(row.profile_definition_id),
        profileReleaseVersion: Number(row.profile_release_version),
        providerToolName:
          typeof row.provider_tool_name === "string"
            ? row.provider_tool_name
            : null,
        providerToolVersion:
          typeof row.provider_tool_version === "string"
            ? row.provider_tool_version
            : null,
        model: selectedModel ?? null,
        reasoningEffort: selectedReasoningEffort ?? null,
        effectivePermissions: permissions,
        maxConcurrentAssignments: maxConcurrent,
        permissionSnapshot,
        selectionExplanation: {
          spaceMembership: membership.role,
          workspace: {
            id: workspaceId,
            status: isWorkspaceLive ? "online" : row.workspace_status,
            readiness: workspaceReadiness,
            connectionSource: isWorkspaceLive
              ? "workspace_gateway"
              : "database",
            grantId: row.grant_id,
          },
          worker: {
            id: workerId,
            workerTypeId,
            engineVersion: row.engine_version,
            profileDefinitionId: row.profile_definition_id,
            profileReleaseVersion: row.profile_release_version,
            providerToolName:
              typeof row.provider_tool_name === "string"
                ? row.provider_tool_name
                : null,
            providerToolVersion:
              typeof row.provider_tool_version === "string"
                ? row.provider_tool_version
                : null,
            activationState: row.local_worker_activation_state,
            readinessState: row.local_worker_readiness_state,
            workBindingId: request.workBindingId ?? null,
            selection: preferredWorkerIds.includes(workerId)
              ? "configured_preference"
              : "eligible_fallback",
          },
          filters: [
            "space_authorized",
            "grant_active",
            "workspace_online",
            "workspace_worker_owned",
            "local_worker_ready",
            "cloud_scheduling_enabled",
            "permissions_intersected",
            "capacity_available",
            ...(statefulLease ? ["primary_workspace", "lease_active"] : []),
          ],
          rejectedAlternatives: rejected,
          catalogRevalidated,
        },
        ...(typeof row.conversation_id === "string"
          ? {
              conversationId: row.conversation_id,
              baseContextRevision: number(row.base_context_revision),
            }
          : {}),
        executionClass,
        readOnly:
          executionClass === "stateless_read" || request.readOnly === true,
        ...(statefulLease
          ? {
              threadId: statefulLease.threadId,
              workRequestId: statefulLease.workRequestId,
              leaseId: statefulLease.leaseId,
              fencingToken: statefulLease.fencingToken,
            }
          : {}),
      };
    }
  }
  onRejection?.([...new Set(rejected.map((entry) => String(entry.reason)))]);
  return null;
}
