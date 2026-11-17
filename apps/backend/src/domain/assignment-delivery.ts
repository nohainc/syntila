export const ASSIGNMENT_ACCEPTANCE_DEADLINE_MS = 30_000;
export const ASSIGNMENT_STARTUP_DEADLINE_MS = 30_000;
/** Default time an accepted assignment may remain queued before startup. */
export const DEFAULT_QUEUE_WAIT_TIMEOUT_MS = 2 * 60_000;
/** Parallel slots a Workspace gets before its owner chooses a number. */
export const DEFAULT_WORKSPACE_PARALLEL_SLOTS = 3;

/**
 * How long Cloud waits for a Service to confirm a revocation before it shows
 * the assignment as `reconciling` (unresolved) instead of `revocation_pending`.
 * Reconciling never means stopped: the cancel keeps being re-sent.
 */
export const ASSIGNMENT_REVOCATION_CONFIRMATION_MS = 20_000;

export interface AssignmentCommandDisposition {
  readonly shouldSend: boolean;
  readonly duplicate: boolean;
  readonly terminal: boolean;
  readonly accepted: boolean;
}

/** Classifies a redispatch without ever reopening a terminal assignment. */
export function assignmentCommandDisposition(
  status: string,
): AssignmentCommandDisposition {
  if (
    ["completed", "failed", "cancelled", "timed_out", "lost"].includes(status)
  ) {
    return {
      shouldSend: false,
      duplicate: true,
      terminal: true,
      accepted: true,
    };
  }
  if (["acknowledged", "running"].includes(status)) {
    return {
      shouldSend: false,
      duplicate: true,
      terminal: false,
      accepted: true,
    };
  }
  if (status === "revocation_pending" || status === "reconciling") {
    // A revoked assignment must never be (re)delivered as a start command: a
    // late replay would launch the very process Cloud is trying to stop.
    return {
      shouldSend: false,
      duplicate: true,
      terminal: false,
      accepted: false,
    };
  }
  if (status === "created" || status === "dispatched") {
    return {
      shouldSend: true,
      duplicate: status === "dispatched",
      terminal: false,
      accepted: false,
    };
  }
  return {
    shouldSend: false,
    duplicate: false,
    terminal: false,
    accepted: false,
  };
}

export type AssignmentDeadlinePhase =
  | "readiness_wait"
  | "command_delivery"
  | "queue_wait"
  | "startup"
  | "provider_execution";

export interface AssignmentDeadlineInput {
  readonly status: string;
  readonly createdAt: string;
  readonly updatedAt?: string | null;
  /** Gateway queued the command for delivery. */
  readonly dispatchedAt?: string | null;
  /** Service admitted the assignment into its local queue. */
  readonly acknowledgedAt?: string | null;
  /** Cloud granted the start permit: a valid slot is available. */
  readonly startPermitIssuedAt?: string | null;
  readonly startPermitRequired?: boolean;
  /** Provider execution began. */
  readonly runningAt?: string | null;
  readonly queueWaitTimeoutMs?: number | null;
  /** Provider execution timeout. */
  readonly timeoutMs?: number | null;
  /** Cloud queue evidence; never supplied by the Workspace Service. */
  readonly cloudQueueReason?: string | null;
  readonly cloudQueueSince?: string | null;
  /** Trusted, accepted Workflow identity. */
  readonly workflowId?: string;
  readonly workflowVersion?: number;
}

/** Capacity is a wait, not an execution/readiness failure, for Research v2. */
export function isResearchCapacityQueue(
  input: Pick<
    AssignmentDeadlineInput,
    "status" | "cloudQueueReason" | "workflowId" | "workflowVersion"
  >,
): boolean {
  return (
    input.status === "created" &&
    input.cloudQueueReason === "workspace_capacity" &&
    input.workflowId === "research" &&
    input.workflowVersion === 2
  );
}

/** Gateway-only compare-and-set. Repeated polls do not reset the wait clock. */
export async function recordCloudQueueReason(
  db: D1Database,
  assignmentId: string,
  attemptId: string,
  reason: "workspace_capacity" | "service_not_ready",
  now = new Date().toISOString(),
): Promise<void> {
  await db
    .prepare(
      `UPDATE worker_assignments
    SET cloud_queue_since = CASE WHEN cloud_queue_reason = ?1
          THEN COALESCE(cloud_queue_since, ?2) ELSE ?2 END,
        cloud_queue_reason = ?1
    WHERE id = ?3 AND attempt_id = ?4 AND status = 'created'`,
    )
    .bind(reason, now, assignmentId, attemptId)
    .run();
}

/** Readiness loss applies to the entire persisted queue, including after a restart. */
export async function recordCloudQueueNotReady(
  db: D1Database,
  workspaceId: string,
  runtimeId: string,
  now = new Date().toISOString(),
): Promise<void> {
  await db
    .prepare(
      `UPDATE worker_assignments
    SET cloud_queue_since = CASE WHEN cloud_queue_reason = 'service_not_ready'
          THEN COALESCE(cloud_queue_since, ?1) ELSE ?1 END,
        cloud_queue_reason = 'service_not_ready'
    WHERE execution_workspace_id = ?2 AND runtime_identity_id = ?3
      AND status = 'created'`,
    )
    .bind(now, workspaceId, runtimeId)
    .run();
}

export interface AssignmentDeadlineViolation {
  readonly phase: AssignmentDeadlinePhase;
  /** The event the violated deadline started at. */
  readonly startedAt: string;
  readonly limitMs: number;
  readonly elapsedMs: number;
}

/**
 * The deadline an assignment is currently subject to, with the event it
 * started at. Each phase measures from its own event, never from assignment
 * creation, so time spent in one phase cannot consume another's budget:
 *
 * - `readiness_wait`: `created` (persisted, nothing sent) -> the Gateway
 *   hands the command to the transport. This is the durable queue for a
 *   Service that is connected but not ready.
 * - `command_delivery`: Gateway queued the command -> Service admission ack.
 *   (Service receipt and admission share one acknowledgement message, so
 *   Cloud observes them as one deadline.)
 * - `queue_wait`: Service accepted it -> a valid slot and start permit exist.
 * - `startup`: start permit granted -> provider start evidence. Services
 *   without start permits cannot signal the slot event, so for them queue
 *   wait and startup are one window starting at admission.
 * - `provider_execution`: provider started -> the configured timeout.
 *
 * Terminal delivery is owned by the Service (journal-backed retry) and has no
 * Cloud-side deadline.
 */
export function currentAssignmentDeadline(input: AssignmentDeadlineInput): {
  phase: AssignmentDeadlinePhase;
  startedAt: string;
  limitMs: number;
} | null {
  const queueWait = input.queueWaitTimeoutMs ?? DEFAULT_QUEUE_WAIT_TIMEOUT_MS;
  switch (input.status) {
    case "created":
      if (isResearchCapacityQueue(input)) return null;
      // Persisted but not handed to the transport: either the Service is not
      // ready yet (the durable queue) or dispatch never completed. Bounded by
      // the queue wait limit; nothing was ever sent, so expiry is a direct,
      // safe finalization.
      return {
        phase: "readiness_wait",
        startedAt: input.cloudQueueSince ?? input.createdAt,
        limitMs: queueWait,
      };
    case "dispatched":
      return {
        phase: "command_delivery",
        startedAt: input.dispatchedAt ?? input.updatedAt ?? input.createdAt,
        limitMs: ASSIGNMENT_ACCEPTANCE_DEADLINE_MS,
      };
    case "acknowledged": {
      const admitted =
        input.acknowledgedAt ?? input.updatedAt ?? input.createdAt;
      if (input.startPermitIssuedAt) {
        return {
          phase: "startup",
          startedAt: input.startPermitIssuedAt,
          limitMs: ASSIGNMENT_STARTUP_DEADLINE_MS,
        };
      }
      return input.startPermitRequired
        ? { phase: "queue_wait", startedAt: admitted, limitMs: queueWait }
        : {
            phase: "queue_wait",
            startedAt: admitted,
            limitMs: Math.max(ASSIGNMENT_STARTUP_DEADLINE_MS, queueWait),
          };
    }
    case "running":
      return input.timeoutMs != null && Number.isFinite(input.timeoutMs)
        ? {
            phase: "provider_execution",
            startedAt: input.runningAt ?? input.updatedAt ?? input.createdAt,
            limitMs: input.timeoutMs,
          }
        : null;
    default:
      return null;
  }
}

/** The violated deadline, or null while the assignment is within budget. */
export function assignmentDeadlineViolation(
  input: AssignmentDeadlineInput,
  now = Date.now(),
): AssignmentDeadlineViolation | null {
  const deadline = currentAssignmentDeadline(input);
  if (!deadline) return null;
  const started = Date.parse(deadline.startedAt);
  if (!Number.isFinite(started)) return null;
  const elapsedMs = now - started;
  return elapsedMs >= deadline.limitMs ? { ...deadline, elapsedMs } : null;
}

export type StepAssignmentOutcome =
  | { readonly kind: "completed" }
  | { readonly kind: "cancelled" }
  | {
      readonly kind: "failed";
      readonly message: string;
      /** False when replaying the step could repeat side effects. */
      readonly retryable: boolean;
    };

/**
 * Decides what a Workflow step does with the assignment it was waiting for.
 *
 * Retrying creates a new attempt against the same repository and provider
 * session, so it is only allowed when the previous attempt provably did
 * nothing: a confirmed stop of work that had not started, or a failure the
 * Service reported itself. Anything ambiguous fails the step visibly instead:
 *
 * - the stop is not confirmed (status is still revocation_pending or
 *   reconciling): the process may be alive;
 * - Cloud revoked an assignment the provider had already started: the stop is
 *   confirmed but side effects may remain.
 */
export function classifyStepAssignmentOutcome(input: {
  readonly status: string | undefined;
  readonly hasOutput: boolean;
  readonly errorMessage?: string;
  /** Status the assignment had when Cloud began revoking it, if it did. */
  readonly revokedAfter: string | null;
}): StepAssignmentOutcome {
  if (input.status === "cancelled") return { kind: "cancelled" };
  if (input.status === "completed" && input.hasOutput) {
    return { kind: "completed" };
  }
  if (input.status === "failed" || input.status === "timed_out") {
    return {
      kind: "failed",
      message: input.errorMessage ?? "Worker assignment failed",
      retryable: input.revokedAfter !== "running",
    };
  }
  if (input.status === "revocation_pending" || input.status === "reconciling") {
    return {
      kind: "failed",
      message:
        "The Workspace has not confirmed that the Worker stopped. Syntila is reconciling it; the step was not retried.",
      retryable: false,
    };
  }
  return {
    kind: "failed",
    message: "Work Step assignment timed out",
    retryable: input.revokedAfter !== "running",
  };
}
