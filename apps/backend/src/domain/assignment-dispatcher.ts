import { atomically, dataOf, queryOf, type Query, type Db } from "../platform/data.js";
import { inTransaction } from "../platform/tx-env.js";
import { agentFenceSql, type AgentSessionFence } from "./agent-session-fence.js";
import { assignmentProgress, assignmentStatus } from "./queries.js";
import { loadConversationBootstrap } from "./routes/conversation-bootstrap.js";
import { createHash } from "node:crypto";
import { encryptProviderFailure, providerFailureKey } from "./provider-failure-encryption.js";
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
} from "@syntila/core";
import {
  ProviderFailureDetailsSchema,
  canonicalExecutionErrorCode,
  executionErrorMessage,
  sanitizeProviderFailureDetails,
  type ProviderFailureDetails,
} from "@syntila/protocol";
import {
  selectSpaceExecutionTarget,
  type ExecutionTarget,
} from "./scheduler.js";
import { dispatchWorkerAssignment } from "./worker-dispatch.js";
import type { WorkerTargetSnapshot } from "./worker-eligibility.js";
import { tryLogDiagnosticEvent } from "./observability.js";
import { withAssignmentPhase } from "./assignment-phase-events.js";
import {
  ASSIGNMENT_REVOCATION_CONFIRMATION_MS,
  DEFAULT_QUEUE_WAIT_TIMEOUT_MS,
  assignmentDeadlineViolation,
} from "./assignment-delivery.js";
import {
  beginAssignmentRevocation,
  deliverRevocation,
  escalateUnconfirmedRevocations,
  revokeAssignment,
  type RevocationEnv,
  type RevocationIntent,
} from "./assignment-revocation.js";
import {
  ACTIVE_ASSIGNMENT_STATUS_SQL,
  assignmentSourceStatusList,
} from "./assignment-transitions.js";
import {
  executionSlotAdmission,
  pluginAssignmentAdmission,
} from "./account-plan.js";
import {
  clearExecutionWaiter,
  executionSlotRefused,
  isPaidRequester,
  recordExecutionWaiter,
  waiterCutoff,
  type ExecutionWaitReason,
} from "./account-execution-slots.js";

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

function safeProviderFailure(
  value: unknown,
): ProviderFailureDetails | undefined {
  const parsed = ProviderFailureDetailsSchema.safeParse(value);
  if (!parsed.success) return undefined;
  const sanitized = sanitizeProviderFailureDetails({
    nativeErrorCode: parsed.data.nativeErrorCode,
    providerErrorText: parsed.data.providerErrorText,
    failedRunResponse: parsed.data.failedRunResponse,
    source: parsed.data.source,
  });
  const omittedFields = [...new Set([...(parsed.data.omittedFields ?? []), ...(sanitized.omittedFields ?? [])])];
  return { ...sanitized,
    ...(parsed.data.truncated || sanitized.truncated ? { truncated: true } : {}),
    ...(parsed.data.omitted || sanitized.omitted ? { omitted: true } : {}),
    ...(omittedFields.length ? { omittedFields } : {}),
  };
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
  /** Artifact output patterns the step declared (packages/core artifact-outputs.ts). */
  readonly artifactOutputs?: readonly string[];
  /** Git references handed to this step (packages/core git-reference.ts); validated before dispatch. */
  readonly gitReferences?: readonly unknown[];
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
  readonly workBindingId?: string;
  readonly leaseId?: string;
  readonly fencingToken?: number;
  readonly executionClass?: "stateless_read" | "stateful_thread";
  /** Restricts Worker/provider access while retaining a Thread lease. */
  readonly readOnly?: boolean;
  /**
   * Set when the request was accepted for a specific Worker (ADR-035). The
   * assignment then runs on the Worker path only; it is never given to a
   * Workspace, whatever the flag says later.
   */
  readonly workerTarget?: WorkerTargetSnapshot;
}

export interface DispatchAssignmentParams {
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
  readonly status:
    | "dispatched"
    | "queued"
    | "failed"
    | "cancelled"
    /** No assignment was created; the task must wait and dispatch again. */
    | "deferred";
  readonly accepted: boolean;
  readonly error?: string;
  /** Set with `status: "deferred"`: what the task is waiting for. */
  readonly waitReason?: ExecutionWaitReason;
}

function deferredDispatch(
  reason: ExecutionWaitReason,
): DispatchAssignmentResult {
  return {
    assignmentId: "",
    attemptId: "",
    workerId: "",
    workspaceRuntimeId: "",
    workerCatalogId: "",
    status: "deferred",
    accepted: false,
    waitReason: reason,
  };
}

export interface AssignmentDispatcherEnv {
  readonly SYNTILA_DB: Db;
  readonly SYNTILA_WORKSPACE_GATEWAY?: DurableObjectNamespace;
  readonly SYNTILA_WORKER_GATEWAY?: DurableObjectNamespace;
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
  const row = await assignmentStatus(dataOf(env).read, assignmentId);
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
 * Creates a Worker Assignment and dispatches the workflow step to its Worker.
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
  // Every Step names the Worker it was accepted for; there is no other target.
  if (!normalizedTask.workerTarget) {
    return {
      assignmentId: "",
      attemptId: "",
      workerId: "",
      workspaceRuntimeId: "",
      workerCatalogId: "",
      status: "failed",
      accepted: false,
      error: "The Step has no Worker",
    };
  }
  return dispatchWorkerAssignment(env, {
    ...params,
    task: normalizedTask,
    workerTarget: normalizedTask.workerTarget,
  });
}

/**
 * Records successful completion of an assignment, updating assignment, attempt, and task in D1.
 */
export async function recordAssignmentResult(
  db: Db,
  assignmentId: string,
  result: AssignmentResultPayload,
  expectedAttemptId?: string,
  agent?: AgentSessionFence,
): Promise<boolean> {
  const now = new Date().toISOString();

  const existing = await assignmentProgress(queryOf(db), assignmentId);
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

  return runTerminalTransition(db, "assignment.complete", async (q) => {
    const first = await q.run`UPDATE worker_assignments SET status = 'completed', output_json = ${JSON.stringify(result)}, updated_at = ${now}
         WHERE id = ${assignmentId} AND status IN (${q.raw(assignmentSourceStatusList("completed"))})
           AND (${expectedAttemptId ?? null}::text IS NULL OR attempt_id = ${expectedAttemptId ?? null})${agentFenceSql(q, agent)}
         RETURNING id`;
    if (first !== 1) return false;
    await q.run`UPDATE workflow_tasks SET status = 'completed', output_json = ${JSON.stringify(result)},
                finished_at = ${now}, updated_at = ${now}
         WHERE id = ${existing.task_id} AND status IN ('queued', 'waiting', 'running')
           AND EXISTS (SELECT 1 FROM worker_assignments
                       WHERE id = ${assignmentId} AND status = 'completed')`;
    return first === 1;
  });
}

/**
 * Records failure of an assignment, updating assignment, attempt, and task in D1.
 */
export async function recordAssignmentError(
  db: Db,
  assignmentId: string,
  failure: AssignmentFailurePayload,
  expectedAttemptId?: string,
  options?: { onlyFrom?: readonly AssignmentLifecycleStatus[]; providerFailureKey?: string; agent?: AgentSessionFence },
): Promise<boolean> {
  const now = new Date().toISOString();
  const details = safeFailureDetails(failure.error?.details);
  const providerFailure = safeProviderFailure(failure.providerFailure);
  const key = providerFailureKey(options?.providerFailureKey);
  const code = canonicalExecutionErrorCode(failure.error?.code);
  const normalizedFailure: AssignmentFailurePayload = {
    error: {
      code,
      message: executionErrorMessage(code),
      retryable: failure.error?.retryable === true,
      ...(details ? { details } : {}),
    },
    failedAt: now,
    ...(providerFailure && key ? { providerFailureEncrypted: encryptProviderFailure(providerFailure, assignmentId, key) } : {}),
    ...((providerFailure && !key) || (!providerFailure && failure.providerFailureUnavailable === true) ? { providerFailureUnavailable: true as const } : {}),
  };

  const existing = await assignmentProgress(queryOf(db), assignmentId);
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

  return runTerminalTransition(db, "assignment.fail", async (q) => {
    const first = await q.run`UPDATE worker_assignments SET status = ${terminalStatus}, error_json = ${JSON.stringify(normalizedFailure)}::text::jsonb, updated_at = ${now}
         WHERE id = ${assignmentId} AND status IN (${q.raw(sourceList(terminalStatus, options?.onlyFrom))})
           AND (${expectedAttemptId ?? null}::text IS NULL OR attempt_id = ${expectedAttemptId ?? null})${agentFenceSql(q, options?.agent)}
         RETURNING id`;
    if (first !== 1) return false;
    await q.run`UPDATE workflow_tasks SET status = 'failed', error = ${normalizedFailure.error.message},
                finished_at = ${now}, updated_at = ${now}
         WHERE id = ${existing.task_id} AND status IN ('queued', 'waiting', 'running')
           AND EXISTS (SELECT 1 FROM worker_assignments
                       WHERE id = ${assignmentId} AND status = ${terminalStatus})`;
    return first === 1;
  });
}

export async function recordAssignmentCancelled(
  db: Db,
  assignmentId: string,
  cancellation: { status: "cancelled"; reason: string },
  expectedAttemptId?: string,
  options?: { onlyFrom?: readonly AssignmentLifecycleStatus[]; agent?: AgentSessionFence },
): Promise<boolean> {
  const now = new Date().toISOString();
  const existing = await assignmentProgress(queryOf(db), assignmentId);
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
  return runTerminalTransition(db, "assignment.cancel", async (q) => {
    const first = await q.run`UPDATE worker_assignments SET status = 'cancelled', error_json = ${JSON.stringify(cancellation)}::text::jsonb, updated_at = ${now}
         WHERE id = ${assignmentId} AND status IN (${q.raw(sourceList("cancelled", options?.onlyFrom))})
           AND (${expectedAttemptId ?? null}::text IS NULL OR attempt_id = ${expectedAttemptId ?? null})${agentFenceSql(q, options?.agent)}
         RETURNING id`;
    if (first !== 1) return false;
    await q.run`UPDATE workflow_tasks SET status = 'cancelled', finished_at = ${now},
                updated_at = ${now}
         WHERE id = ${existing.task_id} AND status IN ('queued', 'waiting', 'running')
           AND EXISTS (SELECT 1 FROM worker_assignments
                       WHERE id = ${assignmentId} AND status = 'cancelled')`;
    return first === 1;
  });
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
  db: Db,
  label: string,
  body: (q: Query) => Promise<boolean>,
): Promise<boolean> {
  // The first statement is the assignment update ending in RETURNING id: only
  // a returned row proves that this call (and not a concurrent handler) made
  // the terminal transition. Everything commits together or not at all.
  return atomically(db, label, body);
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
  db: Db,
  now = new Date(),
  env?: RevocationEnv,
): Promise<number> {
  const nowMs = now.getTime();
  await escalateUnconfirmedRevocations(
    db,
    ASSIGNMENT_REVOCATION_CONFIRMATION_MS,
    now,
  );
  const q = queryOf(db);
  const rows = await q.rows<{
      id: string;
      status: string;
      attemptId: string | null;
      createdAt: string;
      updatedAt: string;
      timeoutMs: number | null;
      queueWaitTimeoutMs: number | null;
      cloudQueueReason: string | null;
      cloudQueueSince: string | null;
      workflowId: string;
      workflowVersion: number;
      dispatchedAt: string | null;
      acknowledgedAt: string | null;
      runningAt: string | null;
      permitIssuedAt: string | null;
      permitRequired: number | null;
      workerOnline: boolean;
      workRequestStatus: string | null;
    }>`SELECT wa.id, wa.status, wa.attempt_id AS "attemptId",
              wa.created_at AS "createdAt",
              wa.updated_at AS "updatedAt", wa.timeout_ms AS "timeoutMs",
              wa.queue_wait_timeout_ms AS "queueWaitTimeoutMs",
              wa.cloud_queue_reason AS "cloudQueueReason",
              wa.cloud_queue_since AS "cloudQueueSince",
              wa.dispatched_at AS "dispatchedAt",
              wa.acknowledged_at AS "acknowledgedAt",
              wa.running_at AS "runningAt",
              wa.start_permit_issued_at AS "permitIssuedAt",
              wa.start_permit_required AS "permitRequired",
              EXISTS (SELECT 1 FROM worker_agent_sessions s
                       WHERE s.worker_instance_id = wa.worker_instance_id
                         AND s.disconnected_at IS NULL AND s.lease_expires_at > now()) AS "workerOnline",
              wr.status AS "workRequestStatus", wr.workflow_id AS "workflowId",
              wr.workflow_version AS "workflowVersion"
         FROM worker_assignments wa
         LEFT JOIN workflow_tasks wt ON wt.id = wa.task_id
         LEFT JOIN work_requests wr ON wr.id = wt.work_request_id
        WHERE wa.status IN (${q.raw(ACTIVE_ASSIGNMENT_STATUS_SQL)})`;

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
  for (const row of rows) {
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
    // A `created` assignment was never sent, so it waits in the durable queue
    // for the Agent to return; its queue deadline bounds the wait.
    const workerDisconnected =
      row.status !== "created" &&
      !row.workerOnline &&
      nowMs - Date.parse(row.updatedAt) >= 30_000;
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
        startPermitRequired: Number(row.permitRequired) === 1,
        runningAt: row.runningAt,
        queueWaitTimeoutMs: row.queueWaitTimeoutMs,
        cloudQueueReason: row.cloudQueueReason,
        cloudQueueSince: row.cloudQueueSince,
        workflowId: row.workflowId,
        workflowVersion: row.workflowVersion,
        timeoutMs: row.timeoutMs,
      },
      nowMs,
    );
    const executionExpired = violation != null;
    if (!workerDisconnected && !executionExpired) {
      continue;
    }
    const code = workerDisconnected ? "provider_unavailable" : "timeout";
    const message = workerDisconnected
      ? "The Worker disconnected before the assignment completed."
      : violation?.phase === "readiness_wait"
        ? "The Worker was not ready to accept the assignment in time."
        : violation?.phase === "queue_wait"
          ? "The assignment waited in the Worker's queue longer than its queue wait limit."
          : violation?.phase === "startup"
            ? "The Worker was cleared to start the assignment but did not report the provider as started."
            : violation?.phase === "command_delivery"
              ? "The Worker did not acknowledge the assignment in time."
              : "The assignment exceeded its execution deadline.";
    if (
      await revoke(row, {
        status: code === "timeout" ? "timed_out" : "failed",
        reason: message,
        source: workerDisconnected ? "worker_disconnected" : "execution_deadline",
        failure: {
          error: {
            code,
            message,
            retryable: true,
            details: cloudFailureDiagnostic(
              workerDisconnected ? "worker_disconnect" : "execution_timeout",
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
 * Cancels a task assignment across Cloud and its Worker. The assignment becomes
 * `cancelled` only when the Agent confirms the process stopped (or never
 * started); otherwise it stays `revocation_pending`/`reconciling` and the
 * caller must treat the cancellation as unconfirmed and retry it.
 */
export async function cancelTaskAssignment(
  env: AssignmentDispatcherEnv,
  assignmentId: string,
  reason: string,
): Promise<{ cancelled: boolean }> {
  const row = await dataOf(env).read.row<{ status: string; attempt_id: string }>`SELECT status, attempt_id
       FROM worker_assignments WHERE id = ${assignmentId}`;
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


