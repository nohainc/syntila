import { loadConversationBootstrap } from "./routes/conversation-bootstrap.js";
import { createHash } from "node:crypto";
import {
  type AssignmentResultPayload,
  type AssignmentFailurePayload,
} from "@syntila/workspace-runtime-protocol";
import {
  ASSIGNMENT_LIFECYCLE_STATUSES,
  ContextLimitError,
  canTransitionAssignment,
  isRevocationAssignmentStatus,
  isTerminalAssignmentStatus,
  type AssignmentLifecycleStatus,
  type ThreadBindingId,
} from "@syntila/core";
import {
  canonicalExecutionErrorCode,
  executionErrorMessage,
} from "@syntila/protocol";
import {
  selectSpaceExecutionTarget,
  type ExecutionTarget,
} from "./scheduler.js";
import { recordExecutionWorkspaceAudit } from "./workspace-audit.js";
import { tryLogDiagnosticEvent } from "./observability.js";
import { publishAssignmentPhase } from "./assignment-phase-events.js";
import {
  ASSIGNMENT_REVOCATION_CONFIRMATION_MS,
  DEFAULT_QUEUE_WAIT_TIMEOUT_MS,
  assignmentDeadlineViolation,
} from "./assignment-delivery.js";
import {
  beginAssignmentRevocation,
  deliverRevocation,
  escalateUnconfirmedRevocations,
  finalizeRevocationsOfRevokedRuntimes,
  revokeAssignment,
  type RevocationEnv,
  type RevocationIntent,
} from "./assignment-revocation.js";
import {
  ACTIVE_ASSIGNMENT_STATUS_SQL,
  assignmentSourceStatusList,
} from "./assignment-transitions.js";

const MAX_FAILURE_DIAGNOSTIC_LENGTH = 2048;

function safeFailureDiagnostic(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value
    .replace(/(bearer\s+)[a-z0-9._~+/-]+=*/gi, "$1[REDACTED]")
    .replace(
      /((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|cookie|authorization|secret)\s*[:=]\s*)[^\s,;]+/gi,
      "$1[REDACTED]",
    )
    // eslint-disable-next-line no-control-regex -- Remove control bytes from diagnostic text.
    .replace(/[\u0000-\u001f\u007f]+/g, " ")
    .replace(
      /(?<![A-Za-z0-9])(?:\/Users|\/home|\/private\/var|\/tmp)\/[^\s,;]+/g,
      "[PATH]",
    )
    .replace(/(?<![A-Za-z0-9])[A-Za-z]:[\\/][^\s,;]+/g, "[PATH]")
    .trim();
  if (!normalized) return null;
  return normalized.length > MAX_FAILURE_DIAGNOSTIC_LENGTH
    ? `${normalized.slice(0, MAX_FAILURE_DIAGNOSTIC_LENGTH)}…`
    : normalized;
}

function safeFailureDetails(
  value: unknown,
): { diagnostic?: string; processExitCode?: number } | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value))
    return undefined;
  const record = value as Record<string, unknown>;
  const diagnostic = safeFailureDiagnostic(record.diagnostic);
  const processExitCode =
    typeof record.processExitCode === "number" &&
    Number.isInteger(record.processExitCode) &&
    record.processExitCode >= 0 &&
    record.processExitCode <= 255
      ? record.processExitCode
      : undefined;
  return diagnostic || processExitCode !== undefined
    ? {
        ...(diagnostic ? { diagnostic } : {}),
        ...(processExitCode !== undefined ? { processExitCode } : {}),
      }
    : undefined;
}

function cloudFailureDiagnostic(
  stage: string,
  code: string,
  detail: string,
): { diagnostic: string } {
  return {
    diagnostic: JSON.stringify({
      schemaVersion: 1,
      component: "cloud",
      stage,
      errorCode: code,
      providerStarted: false,
      detail,
    }),
  };
}

/** Syntila scope reference only; does not expose or certify a native CLI thread. */
export function conversationWorkerSessionReference(
  target: Pick<
    ExecutionTarget,
    | "workspaceId"
    | "workerId"
    | "profileDefinitionId"
    | "profileReleaseVersion"
    | "conversationId"
  >,
  sessionPolicy: string,
  sessionKey: unknown,
): string | null {
  return sessionPolicy === "durable_session"
    ? `worker-session-${createHash("sha256")
        .update(
          JSON.stringify([
            target.workspaceId,
            target.workerId,
            target.profileDefinitionId,
            target.conversationId ?? null,
            sessionKey,
          ]),
        )
        .digest("hex")}`
    : null;
}

export interface TaskToDispatch {
  readonly id: string;
  readonly role: string;
  readonly objective: string;
  readonly capabilities?: readonly string[];
  readonly input?: Record<string, unknown>;
  readonly contextArtifactIds?: readonly string[];
  readonly timeoutMs?: number;
  /** Time admitted work may wait for a local Worker slot. */
  readonly queueWaitTimeoutMs?: number;
  /** Syntila logical execution-session policy; never provider-specific. */
  readonly sessionPolicy?: unknown;
  /** Opaque Syntila key used only for package-local session mapping. */
  readonly sessionKey?: unknown;
  readonly spaceId?: string;
  /** Human-readable label used only to choose a stable local Space directory. */
  readonly spaceName?: string;
  readonly spaceOwnerUserId?: string;
  /** The user confirmed that the Workspace may use an existing, non-empty
   * folder for this Space. Only set by an explicit retry after
   * `space_folder_exists`. */
  readonly spaceFolderAdoptionConfirmed?: boolean;
  /** Compact the resumed Worker session before running this task. */
  readonly contextCompaction?: boolean;
  readonly requestedByUserId?: string;
  readonly model?: string;
  readonly reasoningEffort?: string;
  readonly requiresIndependentVerification?: boolean;
  readonly threadId?: string;
  readonly workRequestId?: string;
  readonly workBindingId?: ThreadBindingId;
  readonly leaseId?: string;
  readonly fencingToken?: number;
  readonly executionClass?: "stateless_read" | "stateful_thread";
  /** Restricts Worker/provider access while retaining a Thread lease. */
  readonly readOnly?: boolean;
}

export interface DispatchAssignmentParams {
  readonly workspaceId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly task: TaskToDispatch;
  readonly explicitWorkerId?: string;
  readonly explicitAttemptNumber?: number;
  readonly excludeIndependenceKeys?: readonly string[];
}

export interface DispatchAssignmentResult {
  readonly assignmentId: string;
  readonly attemptId: string;
  readonly workerId: string;
  readonly workspaceRuntimeId: string;
  readonly workerCatalogId: string;
  /**
   * `queued`: persisted, but the Service is connected and not ready, so no
   * command has been sent. The Gateway flushes it when the Service is ready.
   */
  readonly status: "dispatched" | "queued" | "failed" | "cancelled";
  readonly accepted: boolean;
  readonly error?: string;
}

export interface AssignmentDispatcherEnv {
  readonly SYNTILA_DB: D1Database;
  readonly SYNTILA_WORKSPACE_GATEWAY?: DurableObjectNamespace;
}

/**
 * Selects an eligible, online Worker matching task requirements and policy.
 * Queue admission is durable; the Workspace Service enforces the returned
 * effective capacity before it starts a process.
 */
async function dispatchWorkspaceWorkerAssignment(
  env: AssignmentDispatcherEnv,
  params: DispatchAssignmentParams,
): Promise<DispatchAssignmentResult> {
  const { runId, taskId, task } = params;
  const target = await selectSpaceExecutionTarget(
    env.SYNTILA_DB,
    {
      spaceId: task.spaceId!,
      requesterUserId: task.requestedByUserId!,
      role: task.role,
      capabilities: task.capabilities ?? [],
      workspaceId: params.workspaceId || undefined,
      workerId: params.explicitWorkerId,
      excludeIndependenceKeys: params.excludeIndependenceKeys,
      model: task.model,
      reasoningEffort: task.reasoningEffort,
      executionClass: task.executionClass,
      readOnly: task.readOnly,
      threadId: task.threadId,
      workRequestId: task.workRequestId,
      workBindingId: task.workBindingId,
      allowQueue: true,
    },
    new Date(),
    async (workspaceId, runtimeIdentityId) => {
      const gatewayNamespace = env.SYNTILA_WORKSPACE_GATEWAY;
      if (!gatewayNamespace) return false;
      const gateway = gatewayNamespace.get(
        gatewayNamespace.idFromName(workspaceId),
      );
      const response = await gateway.fetch("http://gateway/status");
      if (!response.ok) return false;
      const status = (await response.json()) as {
        online?: boolean;
        readyForAssignments?: boolean;
        // `online` describes the logical runtime session. Transport is
        // diagnostic only; both WebSocket and long-poll are dispatchable.
        activeTransport?: "websocket" | "http_long_poll" | null;
        workspaceRuntimeId?: string | null;
        executionWorkspaceId?: string | null;
      };
      if (
        status.online !== true ||
        status.workspaceRuntimeId !== runtimeIdentityId ||
        status.executionWorkspaceId !== workspaceId
      ) {
        return false;
      }
      // Liveness is not readiness: a Service that is still synchronizing, or
      // paused/draining, is connected but must not be handed a command.
      return status.readyForAssignments === true ? "ready" : "connected";
    },
  );
  if (!target) {
    tryLogDiagnosticEvent({
      requestId: task.workRequestId,
      workspaceId: params.workspaceId,
      runId,
      taskId,
      component: "cloud",
      operation: "assignment",
      stage: "admission",
      severity: "warning",
      errorCode: "worker_not_ready",
      retryable: true,
      context: { status: "no_eligible_worker" },
    });
    return {
      assignmentId: "",
      attemptId: "",
      workerId: "",
      workspaceRuntimeId: "",
      workerCatalogId: "",
      status: "failed",
      accepted: false,
      error:
        "No Workspace-owned Worker satisfied the active Workspace Grant, execution policy, readiness, capacity, and permission filters",
    };
  }
  const now = new Date().toISOString();
  const attemptNumber = params.explicitAttemptNumber ?? 1;
  const randomPart = crypto.randomUUID().slice(0, 8);
  const attemptId = `att-${taskId}-${attemptNumber}-${Date.now()}-${randomPart}`;
  const assignmentId = `asg-${taskId}-${attemptNumber}-${Date.now()}-${randomPart}`;
  const idempotencyKey = `idem-${assignmentId}`;
  tryLogDiagnosticEvent({
    requestId: task.workRequestId,
    assignmentId,
    workspaceId: target.workspaceId,
    workerId: target.workerId,
    workerTypeId: target.workerTypeId,
    runId,
    taskId,
    attemptId,
    workspaceRuntimeId: target.workspaceRuntimeIdentityId,
    component: "cloud",
    operation: "assignment",
    stage: "admission",
    severity: "info",
    retryable: false,
    context: {
      engineVersion: target.engineVersion,
      ...(target.model ? { modelId: target.model } : {}),
      ...(target.reasoningEffort ? { effort: target.reasoningEffort } : {}),
      ...(typeof target.selectionExplanation.source === "string"
        ? { selectionSource: target.selectionExplanation.source }
        : {}),
    },
  });
  const timeoutMs = task.timeoutMs || 15 * 60_000;
  const queueWaitTimeoutMs =
    task.queueWaitTimeoutMs ?? DEFAULT_QUEUE_WAIT_TIMEOUT_MS;
  if (
    !Number.isSafeInteger(queueWaitTimeoutMs) ||
    queueWaitTimeoutMs < 1_000 ||
    queueWaitTimeoutMs > 2_147_483_647
  ) {
    throw new Error(
      "Assignment queueWaitTimeoutMs is outside the allowed range",
    );
  }
  const sessionPolicy = task.sessionPolicy as string;
  const sessionKey = task.sessionKey;
  const assignmentInput = { ...(task.input ?? {}) };
  delete assignmentInput.sessionPolicy;
  delete assignmentInput.sessionKey;
  delete assignmentInput.additionalFolderIds;
  const additionalFolderIds = await loadAssignmentAdditionalFolderIds(
    env.SYNTILA_DB,
    target.spaceId,
    target.workspaceId,
  );
  if (additionalFolderIds.length > 0)
    assignmentInput.additionalFolderIds = additionalFolderIds;
  let bootstrap;
  if (target.conversationId) {
    const requestId = target.workRequestId ?? task.workRequestId;
    if (!requestId)
      throw new Error("Conversation bootstrap requires a Work request");
    try {
      bootstrap = await loadConversationBootstrap(
        env.SYNTILA_DB,
        target.conversationId,
        requestId,
        target.baseContextRevision ?? 0,
        sessionPolicy === "stateless" ? "stateless" : "bootstrap",
        taskId,
      );
    } catch (error) {
      if (!(error instanceof ContextLimitError)) throw error;
      return {
        assignmentId: "",
        attemptId: "",
        workerId: target.workerId,
        workspaceRuntimeId: target.workspaceRuntimeIdentityId,
        workerCatalogId: "",
        status: "failed",
        accepted: false,
        error: "context_limit_exceeded",
      };
    }
  }
  const snapshot = {
    ...target.permissionSnapshot,
    ...(bootstrap
      ? {
          contextSnapshot: {
            schemaVersion: 1,
            baseContextRevision: bootstrap.contextRevision,
            turnRevision: bootstrap.turnRevision,
            throughSequence: bootstrap.throughSequence,
            digest: createHash("sha256").update(bootstrap.text).digest("hex"),
          },
        }
      : {}),
    selectionExplanation: target.selectionExplanation,
    baseContextRevision: target.baseContextRevision ?? 0,
    workerSessionId: conversationWorkerSessionReference(
      target,
      sessionPolicy,
      sessionKey,
    ),
  };
  const insertion = await env.SYNTILA_DB.prepare(
    `INSERT INTO worker_assignments
       (id, space_id, execution_workspace_id, workspace_space_grant_id,
        run_id, task_id, attempt_id, requested_by_user_id, runtime_identity_id,
        worker_type_id, workspace_worker_id, engine_version,
        model, config_json, effective_permissions_json,
        permission_snapshot_json, timeout_ms, queue_wait_timeout_ms,
        session_policy, idempotency_key, status,
        input_json, created_at, updated_at)
     SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
            ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, 'created', ?21, ?22, ?22
     RETURNING id`,
  )
    .bind(
      assignmentId,
      target.spaceId,
      target.workspaceId,
      target.workspaceSpaceGrantId,
      runId,
      taskId,
      attemptId,
      task.requestedByUserId,
      target.workspaceRuntimeIdentityId,
      target.workerTypeId,
      target.workerId,
      target.engineVersion,
      target.model,
      JSON.stringify(assignmentInput),
      JSON.stringify(target.effectivePermissions),
      JSON.stringify(snapshot),
      timeoutMs,
      queueWaitTimeoutMs,
      sessionPolicy,
      idempotencyKey,
      JSON.stringify(assignmentInput),
      now,
    )
    .first<{ id: string }>();
  // D1 meta.changes includes writes made by triggers. Only the row returned
  // by this INSERT proves admission; an ignored/rejected insert returns none.
  if (insertion?.id !== assignmentId) {
    tryLogDiagnosticEvent({
      requestId: task.workRequestId,
      assignmentId,
      workspaceId: target.workspaceId,
      workerId: target.workerId,
      workerTypeId: target.workerTypeId,
      runId,
      taskId,
      attemptId,
      workspaceRuntimeId: target.workspaceRuntimeIdentityId,
      component: "cloud",
      operation: "assignment",
      stage: "admission",
      severity: "warning",
      errorCode: "worker_concurrency_limit",
      retryable: true,
      context: { status: "capacity_claim_lost_race" },
    });
    return {
      assignmentId: "",
      attemptId: "",
      workerId: "",
      workspaceRuntimeId: "",
      workerCatalogId: "",
      status: "failed",
      accepted: false,
      error: "Worker capacity was claimed by another assignment",
    };
  }
  const workRequestId = target.workRequestId ?? task.workRequestId;
  if (workRequestId) {
    const cancellation = await env.SYNTILA_DB.prepare(
      "SELECT cancel_requested_at FROM work_requests WHERE id = ?1 AND status IN ('running', 'cancelled')",
    )
      .bind(workRequestId)
      .first<{ cancel_requested_at: string | null }>();
    if (cancellation?.cancel_requested_at) {
      await recordAssignmentCancelled(env.SYNTILA_DB, assignmentId, {
        status: "cancelled",
        reason: "Work Request cancellation was requested before dispatch",
      });
      return {
        assignmentId,
        attemptId,
        workerId: target.workerId,
        workspaceRuntimeId: target.workspaceRuntimeIdentityId,
        workerCatalogId: target.workerTypeId,
        status: "cancelled",
        accepted: false,
        error: "Work assignment cancelled before dispatch",
      };
    }
  }
  const workspaceOwner = await env.SYNTILA_DB.prepare(
    "SELECT owner_user_id FROM execution_workspaces WHERE id = ?1",
  )
    .bind(target.workspaceId)
    .first<{ owner_user_id: string }>();
  if (workspaceOwner) {
    await recordExecutionWorkspaceAudit(env.SYNTILA_DB, {
      workspaceId: target.workspaceId,
      ownerUserId: workspaceOwner.owner_user_id,
      actorType: "user",
      actorId: task.requestedByUserId!,
      action: "execution.assignment.dispatched",
      targetType: "worker_assignment",
      targetId: assignmentId,
      details: {
        spaceId: target.spaceId,
        workerId: target.workerId,
        grantId: target.workspaceSpaceGrantId,
      },
    });
  }
  const payload = {
    snapshot: {
      assignmentId,
      objective: task.objective,
      role: task.role,
      contextArtifactIds: task.contextArtifactIds ?? [],
      threadId: target.threadId ?? task.threadId,
      workRequestId: target.workRequestId ?? task.workRequestId,
      leaseId: target.leaseId ?? task.leaseId,
      fencingToken: target.fencingToken ?? task.fencingToken,
      executionClass: target.executionClass,
      readOnly: target.readOnly,
      executionWorkspaceId: target.workspaceId,
      workspaceRuntimeId: target.workspaceRuntimeIdentityId,
      spaceId: target.spaceId,
      ...(task.spaceName ? { spaceName: task.spaceName } : {}),
      ...(task.spaceOwnerUserId
        ? { spaceOwnerUserId: task.spaceOwnerUserId }
        : {}),
      ...(task.spaceFolderAdoptionConfirmed === true
        ? { spaceFolderAdoptionConfirmed: true }
        : {}),
      ...(task.contextCompaction === true && sessionPolicy === "durable_session"
        ? { contextCompaction: true }
        : {}),
      runId,
      taskId,
      attemptId,
      requestedByUserId: task.requestedByUserId,
      workerId: target.workerId,
      workerTypeId: target.workerTypeId,
      engineVersion: target.engineVersion,
      profileDefinitionId: target.profileDefinitionId,
      profileReleaseVersion: target.profileReleaseVersion,
      providerToolName: target.providerToolName,
      providerToolVersion: target.providerToolVersion,
      executionSelection: target.permissionSnapshot.executionSelection,
      model: target.model,
      // Null is the resolved provider default, never permission to reuse a task override.
      reasoningEffort: target.reasoningEffort ?? null,
      config: assignmentInput,
      permissions: target.effectivePermissions,
      permissionSnapshot: snapshot,
      contextRefs: (task.contextArtifactIds ?? []).map((artifactId) => ({
        artifactId,
      })),
      timeoutMs,
      queueWaitTimeoutMs,
      // Replaced at delivery by the Workspace's current slot total: Cloud
      // admits each assignment against that total before sending it.
      maxConcurrentAssignments: target.maxConcurrentAssignments,
      sessionPolicy,
      ...(sessionKey !== undefined ? { sessionKey } : {}),
      ...(target.conversationId && sessionPolicy === "durable_session"
        ? {
            workerSession: {
              schemaVersion: 1,
              id: snapshot.workerSessionId,
              conversationId: target.conversationId,
              workerId: target.workerId,
              baseContextRevision: target.baseContextRevision ?? 0,
              ...(bootstrap ? { bootstrap } : {}),
            },
          }
        : {}),
      ...(bootstrap && sessionPolicy === "stateless"
        ? { statelessContext: bootstrap }
        : {}),
      idempotencyKey,
    },
    input: assignmentInput,
  };
  // Persist the complete command before any delivery attempt. Work for a
  // Service that is not ready yet then waits in this durable queue and is
  // flushed, unchanged, when the Service reports ready.
  await env.SYNTILA_DB.prepare(
    `UPDATE worker_assignments SET command_payload_json = ?1
      WHERE id = ?2 AND status = 'created' AND command_payload_json IS NULL`,
  )
    .bind(JSON.stringify(payload), assignmentId)
    .run();
  if (!env.SYNTILA_WORKSPACE_GATEWAY) {
    const code = "provider_unavailable";
    const error = executionErrorMessage(code);
    await recordAssignmentError(env.SYNTILA_DB, assignmentId, {
      error: {
        code,
        message: error,
        retryable: true,
        details: cloudFailureDiagnostic(
          "gateway_dispatch",
          code,
          "Workspace Gateway is not configured for this assignment",
        ),
      },
      failedAt: now,
    });
    tryLogDiagnosticEvent({
      requestId: task.workRequestId,
      assignmentId,
      workspaceId: target.workspaceId,
      workerId: target.workerId,
      workerTypeId: target.workerTypeId,
      runId,
      taskId,
      attemptId,
      workspaceRuntimeId: target.workspaceRuntimeIdentityId,
      component: "cloud",
      operation: "assignment",
      stage: "transport",
      severity: "error",
      errorCode: code,
      retryable: true,
      context: { status: "gateway_unavailable" },
    });
    return {
      assignmentId,
      attemptId,
      workerId: target.workerId,
      workspaceRuntimeId: target.workspaceRuntimeIdentityId,
      workerCatalogId: target.workerTypeId,
      status: "failed",
      accepted: false,
      error,
    };
  }
  try {
    const stub = env.SYNTILA_WORKSPACE_GATEWAY.get(
      env.SYNTILA_WORKSPACE_GATEWAY.idFromName(target.workspaceId),
    );
    // Dispatch through the Workspace Gateway's logical outbound path. The
    // Gateway writes to its active WebSocket or long-poll event queue.
    const response = await stub.fetch("http://gateway/dispatch-assignment", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        executionWorkspaceId: target.workspaceId,
        workspaceRuntimeId: target.workspaceRuntimeIdentityId,
        workerId: target.workerId,
        runId,
        taskId,
        attemptId,
        assignmentId,
        idempotencyKey,
        payload,
      }),
    });
    if (!response.ok)
      throw new Error(
        (await response.text()) || `Gateway returned HTTP ${response.status}`,
      );
    const delivery = (await response
      .clone()
      .json()
      .catch(() => ({}))) as {
      delivered?: boolean;
      queued?: boolean;
      deliveryState?: string;
    };
    if (delivery.queued === true && delivery.delivered !== true) {
      // The Service is not ready or every slot is taken. Nothing was sent and
      // nothing was accepted: the assignment stays `created` in the durable
      // queue until the Service is ready or an assignment finishes.
      tryLogDiagnosticEvent({
        requestId: task.workRequestId,
        assignmentId,
        workspaceId: target.workspaceId,
        workerId: target.workerId,
        workerTypeId: target.workerTypeId,
        runId,
        taskId,
        attemptId,
        workspaceRuntimeId: target.workspaceRuntimeIdentityId,
        component: "cloud",
        operation: "assignment",
        stage: "dispatch",
        severity: "info",
        retryable: true,
        context: {
          status: `queued_${delivery.deliveryState ?? "waiting_for_service_ready"}`,
        },
      });
      return {
        assignmentId,
        attemptId,
        workerId: target.workerId,
        workspaceRuntimeId: target.workspaceRuntimeIdentityId,
        workerCatalogId: target.workerTypeId,
        status: "queued",
        accepted: true,
      };
    }
    await env.SYNTILA_DB.prepare(
      `UPDATE worker_assignments SET status = 'dispatched', updated_at = ?1,
              dispatched_at = COALESCE(dispatched_at, ?1)
        WHERE id = ?2 AND status IN (${assignmentSourceStatusList("dispatched")})`,
    )
      .bind(new Date().toISOString(), assignmentId)
      .run();
    tryLogDiagnosticEvent({
      requestId: task.workRequestId,
      assignmentId,
      workspaceId: target.workspaceId,
      workerId: target.workerId,
      workerTypeId: target.workerTypeId,
      runId,
      taskId,
      attemptId,
      workspaceRuntimeId: target.workspaceRuntimeIdentityId,
      component: "cloud",
      operation: "assignment",
      stage: "dispatch",
      severity: "info",
      retryable: true,
      context: { status: "dispatched" },
    });
    await publishAssignmentPhase(env, assignmentId);
  } catch {
    const code = "provider_unavailable";
    const message = executionErrorMessage(code);
    // The Gateway may have written the command before the response was lost,
    // so a bare failure could leave a live command behind. Revoke instead
    // unless the assignment provably never left Cloud.
    await failOrRevokeDispatch(env, assignmentId, attemptId, {
      error: {
        code,
        message,
        retryable: true,
        details: cloudFailureDiagnostic(
          "gateway_dispatch",
          code,
          "Workspace Gateway dispatch did not accept the assignment",
        ),
      },
      failedAt: new Date().toISOString(),
    });
    tryLogDiagnosticEvent({
      requestId: task.workRequestId,
      assignmentId,
      workspaceId: target.workspaceId,
      workerId: target.workerId,
      workerTypeId: target.workerTypeId,
      runId,
      taskId,
      attemptId,
      workspaceRuntimeId: target.workspaceRuntimeIdentityId,
      component: "cloud",
      operation: "assignment",
      stage: "transport",
      severity: "error",
      errorCode: code,
      retryable: true,
      context: { status: "gateway_dispatch_failed" },
    });
    return {
      assignmentId,
      attemptId,
      workerId: target.workerId,
      workspaceRuntimeId: target.workspaceRuntimeIdentityId,
      workerCatalogId: target.workerTypeId,
      status: "failed",
      accepted: false,
      error: message,
    };
  }
  return {
    assignmentId,
    attemptId,
    workerId: target.workerId,
    workspaceRuntimeId: target.workspaceRuntimeIdentityId,
    workerCatalogId: target.workerTypeId,
    status: "dispatched",
    accepted: true,
  };
}

/**
 * Asks the Workspace Gateway to hand any durably queued `created` assignments
 * to a Service that is now ready. Best effort and idempotent: the Gateway
 * claims each assignment with a conditional write, so it never double-sends.
 */
export async function nudgeQueuedAssignments(
  env: AssignmentDispatcherEnv,
  workspaceId: string,
): Promise<void> {
  const namespace = env.SYNTILA_WORKSPACE_GATEWAY;
  if (!namespace) return;
  try {
    await namespace
      .get(namespace.idFromName(workspaceId))
      .fetch("http://gateway/flush-queued", { method: "POST" });
  } catch {
    // The next poll nudges again; the assignment's queue deadline still bounds
    // the wait.
  }
}

/**
 * Fails an assignment whose dispatch call did not return success. `created`
 * means the Gateway never persisted delivery, so nothing can be running and a
 * direct failure is safe. Any later status means the command may exist, so
 * the failure becomes a revocation that finalizes only on Service evidence.
 */
export async function failOrRevokeDispatch(
  env: AssignmentDispatcherEnv,
  assignmentId: string,
  attemptId: string,
  failure: AssignmentFailurePayload,
): Promise<void> {
  const row = await env.SYNTILA_DB.prepare(
    "SELECT status FROM worker_assignments WHERE id = ?1",
  )
    .bind(assignmentId)
    .first<{ status: string }>();
  if (!row || row.status === "created") {
    await recordAssignmentError(
      env.SYNTILA_DB,
      assignmentId,
      failure,
      attemptId,
      { onlyFrom: ["created"] },
    );
    return;
  }
  await revokeAssignment(env, {
    assignmentId,
    attemptId,
    intent: {
      status: "failed",
      reason: failure.error.message,
      source: "dispatch_failed",
      failure,
    },
  });
}

/**
 * Creates a Worker Assignment in D1 and dispatches the workflow step over the Workspace Gateway.
 */
export async function dispatchTaskAssignment(
  env: AssignmentDispatcherEnv,
  params: DispatchAssignmentParams,
): Promise<DispatchAssignmentResult> {
  const { task } = params;
  const sessionPolicy =
    task.sessionPolicy ?? task.input?.sessionPolicy ?? "stateless";
  const sessionKey = task.sessionKey ?? task.input?.sessionKey;
  if (
    !["stateless", "durable_session"].includes(String(sessionPolicy)) ||
    (sessionPolicy === "stateless" && sessionKey !== undefined) ||
    (sessionPolicy === "durable_session" &&
      (typeof sessionKey !== "string" ||
        !sessionKey.trim() ||
        sessionKey.length > 256))
  ) {
    return {
      assignmentId: "",
      attemptId: "",
      workerId: "",
      workspaceRuntimeId: "",
      workerCatalogId: "",
      status: "failed",
      accepted: false,
      error: "Assignment session policy or logical session key is invalid",
    };
  }
  const normalizedTask: TaskToDispatch = {
    ...task,
    sessionPolicy,
    ...(sessionKey !== undefined ? { sessionKey } : {}),
  };
  // Every assignment carries the authenticated Space requester so Workspace
  // selection, grants, and the immutable assignment target are evaluated.
  if (!normalizedTask.spaceId || !normalizedTask.requestedByUserId) {
    return {
      assignmentId: "",
      attemptId: "",
      workerId: "",
      workspaceRuntimeId: "",
      workerCatalogId: "",
      status: "failed",
      accepted: false,
      error: "Space execution context is required for assignment dispatch",
    };
  }
  return dispatchWorkspaceWorkerAssignment(env, {
    ...params,
    task: normalizedTask,
  });
}

/**
 * Records successful completion of an assignment, updating assignment, attempt, and task in D1.
 */
export async function recordAssignmentResult(
  db: D1Database,
  assignmentId: string,
  result: AssignmentResultPayload,
  expectedAttemptId?: string,
): Promise<boolean> {
  const now = new Date().toISOString();

  const existing = await db
    .prepare(
      `SELECT status, task_id, attempt_id FROM worker_assignments WHERE id = ?1`,
    )
    .bind(assignmentId)
    .first<{
      status: string;
      task_id: string;
      attempt_id: string | null;
    }>();
  if (!existing) return false;
  if (expectedAttemptId && existing.attempt_id !== expectedAttemptId)
    return false;
  if (
    !isKnownAssignmentStatus(existing.status) ||
    isTerminalAssignmentStatus(existing.status as AssignmentLifecycleStatus) ||
    !canTransitionAssignment(
      existing.status as AssignmentLifecycleStatus,
      "completed",
    )
  ) {
    return false;
  }

  return runTerminalTransition(db, [
    db
      .prepare(
        `UPDATE worker_assignments SET status = 'completed', output_json = ?1, updated_at = ?2
         WHERE id = ?3 AND status IN (${assignmentSourceStatusList("completed")})
         RETURNING id`,
      )
      .bind(JSON.stringify(result), now, assignmentId),
    db
      .prepare(
        `UPDATE workflow_tasks SET status = 'completed', output_json = ?1,
                finished_at = ?2, updated_at = ?2
         WHERE id = ?3 AND status IN ('queued', 'waiting', 'running')
           AND EXISTS (SELECT 1 FROM worker_assignments
                       WHERE id = ?4 AND status = 'completed')`,
      )
      .bind(JSON.stringify(result), now, existing.task_id, assignmentId),
  ]);
}

/**
 * Records failure of an assignment, updating assignment, attempt, and task in D1.
 */
export async function recordAssignmentError(
  db: D1Database,
  assignmentId: string,
  failure: AssignmentFailurePayload,
  expectedAttemptId?: string,
  options?: { onlyFrom?: readonly AssignmentLifecycleStatus[] },
): Promise<boolean> {
  const now = new Date().toISOString();
  const details = safeFailureDetails(failure.error?.details);
  const code = canonicalExecutionErrorCode(failure.error?.code);
  const normalizedFailure: AssignmentFailurePayload = {
    error: {
      code,
      message: executionErrorMessage(code),
      retryable: failure.error?.retryable === true,
      ...(details ? { details } : {}),
    },
    failedAt: now,
  };

  const existing = await db
    .prepare(
      `SELECT status, task_id, attempt_id FROM worker_assignments WHERE id = ?1`,
    )
    .bind(assignmentId)
    .first<{
      status: string;
      task_id: string;
      attempt_id: string | null;
    }>();
  if (!existing) return false;
  if (expectedAttemptId && existing.attempt_id !== expectedAttemptId)
    return false;
  const terminalStatus =
    normalizedFailure.error.code === "timeout" ? "timed_out" : "failed";
  if (
    !isKnownAssignmentStatus(existing.status) ||
    isTerminalAssignmentStatus(existing.status as AssignmentLifecycleStatus) ||
    !canTransitionAssignment(
      existing.status as AssignmentLifecycleStatus,
      terminalStatus,
    ) ||
    (options?.onlyFrom &&
      !options.onlyFrom.includes(existing.status as AssignmentLifecycleStatus))
  ) {
    return false;
  }

  return runTerminalTransition(db, [
    db
      .prepare(
        `UPDATE worker_assignments SET status = ?1, error_json = ?2, updated_at = ?3
         WHERE id = ?4 AND status IN (${sourceList(terminalStatus, options?.onlyFrom)})
         RETURNING id`,
      )
      .bind(
        terminalStatus,
        JSON.stringify(normalizedFailure),
        now,
        assignmentId,
      ),
    db
      .prepare(
        `UPDATE workflow_tasks SET status = 'failed', error = ?1,
                finished_at = ?2, updated_at = ?2
         WHERE id = ?3 AND status IN ('queued', 'waiting', 'running')
           AND EXISTS (SELECT 1 FROM worker_assignments
                       WHERE id = ?4 AND status = ?5)`,
      )
      .bind(
        normalizedFailure.error.message,
        now,
        existing.task_id,
        assignmentId,
        terminalStatus,
      ),
  ]);
}

export async function recordAssignmentCancelled(
  db: D1Database,
  assignmentId: string,
  cancellation: { status: "cancelled"; reason: string },
  expectedAttemptId?: string,
  options?: { onlyFrom?: readonly AssignmentLifecycleStatus[] },
): Promise<boolean> {
  const now = new Date().toISOString();
  const existing = await db
    .prepare(
      `SELECT status, task_id, attempt_id FROM worker_assignments WHERE id = ?1`,
    )
    .bind(assignmentId)
    .first<{
      status: string;
      task_id: string;
      attempt_id: string | null;
    }>();
  if (!existing) return false;
  if (expectedAttemptId && existing.attempt_id !== expectedAttemptId)
    return false;
  if (
    !isKnownAssignmentStatus(existing.status) ||
    isTerminalAssignmentStatus(existing.status as AssignmentLifecycleStatus) ||
    !canTransitionAssignment(
      existing.status as AssignmentLifecycleStatus,
      "cancelled",
    )
  ) {
    return false;
  }
  return runTerminalTransition(db, [
    db
      .prepare(
        `UPDATE worker_assignments SET status = 'cancelled', error_json = ?1, updated_at = ?2
         WHERE id = ?3 AND status IN (${sourceList("cancelled", options?.onlyFrom)})
           AND (?4 IS NULL OR attempt_id = ?4)
         RETURNING id`,
      )
      .bind(
        JSON.stringify(cancellation),
        now,
        assignmentId,
        expectedAttemptId ?? null,
      ),
    db
      .prepare(
        `UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1,
                updated_at = ?1
         WHERE id = ?2 AND status IN ('queued', 'waiting', 'running')
           AND EXISTS (SELECT 1 FROM worker_assignments
                       WHERE id = ?3 AND status = 'cancelled')`,
      )
      .bind(now, existing.task_id, assignmentId),
  ]);
}

function sourceList(
  target: AssignmentLifecycleStatus,
  onlyFrom?: readonly AssignmentLifecycleStatus[],
): string {
  const all = assignmentSourceStatusList(target);
  if (!onlyFrom) return all;
  const allowed = new Set<string>(onlyFrom);
  return all
    .split(", ")
    .filter((quoted) => allowed.has(quoted.slice(1, -1)))
    .join(", ");
}

function isKnownAssignmentStatus(
  status: string,
): status is AssignmentLifecycleStatus {
  return (ASSIGNMENT_LIFECYCLE_STATUSES as readonly string[]).includes(status);
}

async function runTerminalTransition(
  db: D1Database,
  statements: D1PreparedStatement[],
): Promise<boolean> {
  // The first statement is the assignment update ending in RETURNING id. D1
  // `meta.changes` counts trigger writes, so only a returned row proves that
  // this call (and not a concurrent handler) made the terminal transition.
  if (typeof db.batch === "function") {
    const results = await db.batch(statements);
    return (results[0]?.results?.length ?? 0) === 1;
  }
  // Sequential fallback for stores without batch support. Without a
  // RETURNING result to inspect, a completed statement counts as applied.
  let applied = true;
  for (const [index, statement] of statements.entries()) {
    const result = (await statement.run()) as
      { results?: unknown[] } | undefined;
    if (index === 0 && Array.isArray(result?.results))
      applied = result.results.length === 1;
  }
  return applied;
}

/**
 * Revokes assignments whose Workspace can no longer be expected to report a
 * terminal result. This is intentionally Cloud-owned recovery: a transport
 * heartbeat proves only that the Workspace service is reachable, not that the
 * Engine/provider process is still alive, and a Workspace that stopped
 * answering may still be running the process. So recovery never writes a
 * terminal outcome for work that may have been delivered; it starts a
 * revocation (see assignment-revocation.ts) and keeps re-sending the cancel.
 * Pass [env] to let recovery reach the Gateway; without it the revocation is
 * recorded and delivered later, on reconnect or the next recovery pass.
 */
export async function recoverStaleAssignments(
  db: D1Database,
  now = new Date(),
  env?: RevocationEnv,
): Promise<number> {
  const nowMs = now.getTime();
  await finalizeRevocationsOfRevokedRuntimes(db);
  await escalateUnconfirmedRevocations(
    db,
    ASSIGNMENT_REVOCATION_CONFIRMATION_MS,
    now,
  );
  const rows = await db
    .prepare(
      `SELECT wa.id, wa.status, wa.attempt_id AS attemptId,
              wa.created_at AS createdAt,
              wa.updated_at AS updatedAt, wa.timeout_ms AS timeoutMs,
              wa.queue_wait_timeout_ms AS queueWaitTimeoutMs,
              wa.dispatched_at AS dispatchedAt,
              wa.acknowledged_at AS acknowledgedAt,
              wa.running_at AS runningAt,
              wa.start_permit_issued_at AS permitIssuedAt,
              wa.start_permit_required AS permitRequired,
              ew.status AS workspaceStatus, ew.updated_at AS workspaceUpdatedAt,
              g.expires_at AS grantExpiresAt, g.status AS grantStatus,
              wr.status AS workRequestStatus
         FROM worker_assignments wa
         JOIN execution_workspaces ew ON ew.id = wa.execution_workspace_id
         LEFT JOIN workspace_space_grants g ON g.id = wa.workspace_space_grant_id
         LEFT JOIN workflow_tasks wt ON wt.id = wa.task_id
         LEFT JOIN work_requests wr ON wr.id = wt.work_request_id
        WHERE wa.status IN (${ACTIVE_ASSIGNMENT_STATUS_SQL})`,
    )
    .all<{
      id: string;
      status: string;
      attemptId: string | null;
      createdAt: string;
      updatedAt: string;
      timeoutMs: number | null;
      queueWaitTimeoutMs: number | null;
      dispatchedAt: string | null;
      acknowledgedAt: string | null;
      runningAt: string | null;
      permitIssuedAt: string | null;
      permitRequired: number | null;
      workspaceStatus: string;
      workspaceUpdatedAt: string;
      grantExpiresAt: string | null;
      grantStatus: string | null;
      workRequestStatus: string | null;
    }>();

  const revoke = async (
    row: { id: string; status: string; attemptId: string | null },
    intent: RevocationIntent,
  ): Promise<boolean> => {
    const input = {
      assignmentId: row.id,
      ...(row.attemptId ? { attemptId: row.attemptId } : {}),
      intent,
      // The decision was made from this status. If the assignment has since
      // advanced the stale decision must not revoke it.
      onlyFrom: isKnownAssignmentStatus(row.status) ? [row.status] : [],
    };
    const result = env
      ? await revokeAssignment(env, input)
      : await beginAssignmentRevocation(db, input);
    return result.outcome === "finalized" || result.outcome === "pending";
  };

  let recovered = 0;
  for (const row of rows.results ?? []) {
    if (
      isKnownAssignmentStatus(row.status) &&
      isRevocationAssignmentStatus(row.status)
    ) {
      // Already revoking: keep trying to reach the Service.
      if (env) await deliverRevocation(env, row.id);
      continue;
    }
    if (row.workRequestStatus === "cancelled") {
      if (
        await revoke(row, {
          status: "cancelled",
          reason: "The owning Work Request was cancelled.",
          source: "work_cancelled",
        })
      )
        recovered += 1;
      continue;
    }
    // Recovers a crash after the grant commit but before its assignments
    // received durable revocation intents. Grant removal never proves a stop.
    if (row.grantStatus === "revoked") {
      if (
        await revoke(row, {
          status: "cancelled",
          source: "grant_revoked",
          reason: "Workspace Space Grant revoked",
        })
      )
        recovered += 1;
      continue;
    }
    const grantExpired =
      row.grantExpiresAt != null && Date.parse(row.grantExpiresAt) <= nowMs;
    // A `created` assignment was never sent, so it waits in the durable queue
    // for the Service to return; its queue deadline bounds the wait.
    const workspaceDisconnected =
      row.status !== "created" &&
      row.workspaceStatus !== "online" &&
      nowMs -
        Math.max(
          Date.parse(row.updatedAt),
          Date.parse(row.workspaceUpdatedAt),
        ) >=
        30_000;
    // Each phase measures from its own event (see currentAssignmentDeadline),
    // so queue wait and startup no longer inherit time already spent in
    // delivery, and provider execution counts from provider start rather than
    // from the last unrelated row update.
    const violation = assignmentDeadlineViolation(
      {
        status: row.status,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        dispatchedAt: row.dispatchedAt,
        acknowledgedAt: row.acknowledgedAt,
        startPermitIssuedAt: row.permitIssuedAt,
        startPermitRequired: row.permitRequired === 1,
        runningAt: row.runningAt,
        queueWaitTimeoutMs: row.queueWaitTimeoutMs,
        timeoutMs: row.timeoutMs,
      },
      nowMs,
    );
    const executionExpired = violation != null;
    if (!grantExpired && !workspaceDisconnected && !executionExpired) {
      continue;
    }
    const code = grantExpired
      ? "provider_unavailable"
      : workspaceDisconnected
        ? "provider_unavailable"
        : "timeout";
    const message = grantExpired
      ? "The Workspace execution lease expired before the assignment completed."
      : workspaceDisconnected
        ? "The Workspace disconnected before the assignment completed."
        : violation?.phase === "readiness_wait"
          ? "The Workspace Service was not ready to accept the assignment in time."
          : violation?.phase === "queue_wait"
            ? "The assignment waited in the Workspace queue longer than its queue wait limit."
            : violation?.phase === "startup"
              ? "The Workspace was cleared to start the assignment but did not report the provider as started."
              : violation?.phase === "command_delivery"
                ? "The Workspace did not acknowledge the assignment in time."
                : "The assignment exceeded its execution deadline.";
    if (
      await revoke(row, {
        status: code === "timeout" ? "timed_out" : "failed",
        reason: message,
        source: grantExpired
          ? "grant_expired"
          : workspaceDisconnected
            ? "workspace_disconnected"
            : "execution_deadline",
        failure: {
          error: {
            code,
            message,
            retryable: true,
            details: cloudFailureDiagnostic(
              grantExpired
                ? "workspace_lease"
                : workspaceDisconnected
                  ? "workspace_disconnect"
                  : "execution_timeout",
              code,
              message,
            ),
          },
          failedAt: now.toISOString(),
        },
      })
    ) {
      recovered += 1;
    }
  }
  return recovered;
}

/**
 * Cancels a task assignment across Cloud and Workspace. The assignment becomes
 * `cancelled` only when the Workspace confirms the process stopped (or never
 * started); otherwise it stays `revocation_pending`/`reconciling` and the
 * caller must treat the cancellation as unconfirmed and retry it.
 */
export async function cancelTaskAssignment(
  env: AssignmentDispatcherEnv,
  workspaceId: string,
  assignmentId: string,
  reason: string,
): Promise<{ cancelled: boolean }> {
  const row = await env.SYNTILA_DB.prepare(
    `SELECT status, attempt_id
       FROM worker_assignments
      WHERE id = ?1 AND execution_workspace_id = ?2`,
  )
    .bind(assignmentId, workspaceId)
    .first<{ status: string; attempt_id: string }>();
  if (!row) return { cancelled: false };
  if (row.status === "cancelled") return { cancelled: true };
  if (["completed", "failed", "timed_out", "lost"].includes(row.status))
    return { cancelled: false };
  const result = await revokeAssignment(env, {
    assignmentId,
    attemptId: row.attempt_id,
    intent: { status: "cancelled", reason, source: "manual_cancel" },
  });
  return { cancelled: result.confirmed };
}

/**
 * Folder IDs the Space owner attached on this Workspace. Only IDs travel; the
 * Workspace maps them to local paths and re-checks access before launch. The
 * owner check is repeated here so a Space that changed hands never sends the
 * previous owner's folders.
 */
export async function loadAssignmentAdditionalFolderIds(
  db: D1Database,
  spaceId: string | null | undefined,
  workspaceId: string,
): Promise<string[]> {
  if (!spaceId) return [];
  const rows = await db
    .prepare(
      `SELECT a.folder_id AS folderId
         FROM space_additional_folders a
         JOIN workspace_allowed_folders f
           ON f.workspace_id = a.workspace_id AND f.folder_id = a.folder_id
         JOIN spaces s ON s.id = a.space_id
         JOIN execution_workspaces w
           ON w.id = a.workspace_id AND w.owner_user_id = s.owner_user_id
        WHERE a.space_id = ?1 AND a.workspace_id = ?2
        ORDER BY a.folder_id`,
    )
    .bind(spaceId, workspaceId)
    .all<{ folderId: string }>();
  return (rows.results ?? []).map((row) => row.folderId);
}
