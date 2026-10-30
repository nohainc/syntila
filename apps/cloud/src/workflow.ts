import { advanceThreadQueueSafely } from "./routes/thread-request-queue.js";
import type { SecurityEnv } from "./routes/http-security.js";
import {
  WorkflowEntrypoint,
  type WorkflowEvent,
  type WorkflowStep,
} from "cloudflare:workers";
import {
  effectiveStepTimeoutMs,
  markWorkflowTaskResult,
  planWorkflowTasks,
  readyWorkflowTasks,
  validateBuiltinWorkflowDefinition,
  type PlannedWorkflowTask,
  type BuiltinWorkflowDefinition,
  type StepKind,
  type StepResult,
  type WorkRequestSnapshot,
} from "@syntila/core";
import {
  renderWorkStepPrompt,
  workStepPromptInputs,
} from "./workflow-prompts.js";
import { ASSIGNMENT_TERMINAL_EVENT_TYPE } from "./assignment-workflow-signal.js";
import {
  INPUT_DELIVERY_IDLE_TIMEOUT_MS,
  WORK_INPUTS_EVENT_TYPE,
  loadWorkRequestInputs,
  withInputFacts,
  type WorkRequestInputRow,
} from "./routes/work-request-inputs.js";
import { createEventPublisher } from "./event-publisher.js";
import { tryLogTraceEvent } from "./observability.js";
import {
  dispatchTaskAssignment,
  nudgeQueuedAssignments,
  type AssignmentDispatcherEnv,
} from "./assignment-dispatcher.js";
import {
  deliverRevocation,
  revokeAssignment,
  type RevocationEnv,
} from "./assignment-revocation.js";
import type { AssignmentLifecycleStatus, ThreadBindingId } from "@syntila/core";
import {
  prepareWorkerStepExecution,
  completeWorkerStepExecution,
} from "./execution-engine.js";
import {
  assignmentDeadlineViolation,
  classifyStepAssignmentOutcome,
  currentAssignmentDeadline,
  DEFAULT_QUEUE_WAIT_TIMEOUT_MS,
  type AssignmentDeadlinePhase,
} from "./assignment-delivery.js";

/**
 * Number of wait rounds (10 s each) the Workflow waits for the Service to
 * confirm a revocation before it gives up *waiting*. Giving up never means the process
 * stopped: the assignment stays `reconciling` and the step fails without retry.
 */
const REVOCATION_CONFIRMATION_ROUNDS = 3;
const REVOCATION_CONFIRMATION_ROUND_MS = 10_000;

/**
 * Longest the Workflow waits for a terminal notification before re-reading the
 * assignment in D1. Bounds the delay caused by a lost event.
 */
export const ASSIGNMENT_RECONCILIATION_INTERVAL_MS = 30_000;
/**
 * A long run is re-read less often: an 8 hour step at 30 seconds would exceed
 * the Workflow step budget. Terminal events still wake the Workflow at once;
 * this only bounds the delay after a lost event.
 */
export const LONG_RUN_RECONCILIATION_INTERVAL_MS = 120_000;
const LONG_RUN_AFTER_MS = 10 * 60_000;
const WAKEUP_SLACK = 20;

interface WakeupRow {
  readonly status: string;
  readonly createdAt: string;
  readonly updatedAt?: string | null;
  readonly dispatchedAt?: string | null;
  readonly acknowledgedAt?: string | null;
  readonly permitIssuedAt?: string | null;
  readonly permitRequired?: number | null;
  readonly runningAt?: string | null;
  readonly queueWaitTimeoutMs?: number | null;
}

function phaseDeadline(row: WakeupRow, timeoutMs: number) {
  return currentAssignmentDeadline({
    status: row.status,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    dispatchedAt: row.dispatchedAt,
    acknowledgedAt: row.acknowledgedAt,
    startPermitIssuedAt: row.permitIssuedAt,
    startPermitRequired: row.permitRequired === 1,
    runningAt: row.runningAt,
    queueWaitTimeoutMs: row.queueWaitTimeoutMs ?? DEFAULT_QUEUE_WAIT_TIMEOUT_MS,
    timeoutMs,
  });
}

/**
 * How long to wait for the terminal event before looking at D1 again: the
 * time left in the current phase, never more than the reconciliation interval
 * and never less than a second.
 */
export function nextWakeupMs(
  row: WakeupRow | null,
  timeoutMs: number,
  now = Date.now(),
): number {
  let wait = ASSIGNMENT_RECONCILIATION_INTERVAL_MS;
  const runningSince = row?.runningAt ? Date.parse(row.runningAt) : NaN;
  if (
    row?.status === "running" &&
    Number.isFinite(runningSince) &&
    now - runningSince > LONG_RUN_AFTER_MS
  ) {
    wait = LONG_RUN_RECONCILIATION_INTERVAL_MS;
  }
  const deadline = row ? phaseDeadline(row, timeoutMs) : null;
  if (deadline) {
    const started = Date.parse(deadline.startedAt);
    if (Number.isFinite(started)) {
      wait = Math.min(wait, started + deadline.limitMs - now);
    }
  }
  return Math.max(1_000, Math.ceil(wait / 1_000) * 1_000);
}

/**
 * True once a running assignment is past its provider time limit plus the
 * grace the Service needs to report its own timeout first.
 */
export function providerExecutionOverrun(
  row: WakeupRow,
  timeoutMs: number,
  now = Date.now(),
): boolean {
  const started = Date.parse(row.runningAt ?? row.updatedAt ?? row.createdAt);
  return (
    Number.isFinite(started) &&
    now - started >= timeoutMs + DEFAULT_QUEUE_WAIT_TIMEOUT_MS
  );
}

/** Temporary local diagnostics (REALTIME_DIAGNOSTICS=1 in .dev.vars). */
function workflowDiagnostic(
  env: unknown,
  stage: string,
  data: Record<string, unknown> = {},
): void {
  if ((env as { REALTIME_DIAGNOSTICS?: string }).REALTIME_DIAGNOSTICS !== "1")
    return;
  console.log(
    JSON.stringify({
      diagnostic: "workflow_terminal",
      stage,
      ...data,
      at: new Date().toISOString(),
    }),
  );
}

/**
 * Suspends the Workflow until an `assignment-terminal` event arrives or
 * [timeoutMs] passes. Both outcomes are the same to the caller: it re-reads
 * the assignment from D1, which is the only authority. An event sent before
 * this wait started is buffered by Workflows and returns immediately.
 */
async function waitForTerminalEvent(
  step: WorkflowStep,
  name: string,
  timeoutMs: number,
): Promise<"event" | "timeout"> {
  try {
    await step.waitForEvent(name, {
      type: ASSIGNMENT_TERMINAL_EVENT_TYPE,
      timeout: `${Math.max(1, Math.ceil(timeoutMs / 1_000))} seconds`,
    });
    return "event";
  } catch {
    // Timing out is the reconciliation path, not a failure.
    return "timeout";
  }
}

/**
 * An ambiguous failure: the work may have run (or may still be running). The
 * step must fail visibly and must NOT be replayed automatically against the
 * same repository or provider session.
 */
class AssignmentNotRetryableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AssignmentNotRetryableError";
  }
}

/**
 * What the Input Delivery gate does with the current input rows: continue,
 * fail, stop for cancellation, or keep waiting. Pure, for testing.
 */
export function inputGateDecision(
  rows: readonly Pick<
    WorkRequestInputRow,
    "name" | "state" | "errorMessage" | "updatedAt"
  >[],
  cancelRequested: boolean,
  now: number,
):
  | { outcome: "none" | "delivered" | "waiting" }
  | { outcome: "failed" | "cancelled"; message: string } {
  if (rows.length === 0) return { outcome: "none" };
  const failed = rows.find((row) => row.state === "failed");
  if (failed)
    return {
      outcome: "failed",
      message:
        failed.errorMessage ??
        `${failed.name} was not delivered to the Workspace`,
    };
  if (rows.every((row) => row.state === "delivered"))
    return { outcome: "delivered" };
  if (cancelRequested) return { outcome: "cancelled", message: "Cancelled" };
  const lastProgress = Math.max(
    ...rows.map((row) => Date.parse(row.updatedAt) || 0),
  );
  if (now - lastProgress >= INPUT_DELIVERY_IDLE_TIMEOUT_MS)
    return {
      outcome: "failed",
      message: `Files were not delivered to the Workspace in time: ${rows
        .filter((row) => row.state !== "delivered")
        .map((row) => row.name)
        .join(", ")}`,
    };
  return { outcome: "waiting" };
}

export interface SyntilaWorkflowParams {
  readonly runId: string;
  readonly goalId: string;
  readonly idempotencyKey: string;
  readonly organizationId?: string;
  /** Immutable definition for the Work v1 Cloud Workflow. */
  readonly builtinWorkflow?: BuiltinWorkflowDefinition;
  readonly workRequestId?: string;
  readonly threadId?: string;
  readonly spaceId?: string;
  readonly input?: Record<string, unknown>;
  readonly retryStepKind?: StepKind;
  readonly retrySessionStrategy?: "resume" | "fresh";
  readonly retryNumber?: number;
  /** Set by a confirmed retry of a `space_folder_exists` failure. */
  readonly retryAdoptSpaceFolder?: boolean;
  /** Set when the user chose to compact the Worker session after a context
   * overflow: the retry resumes the session and compacts it first. */
  readonly retryCompactContext?: boolean;
}

export interface SyntilaWorkflowCheckpoint {
  readonly runId: string;
  readonly goalId: string;
  readonly idempotencyKey: string;
  readonly stage: "workflow" | "completed" | "cancelled" | "failed";
  readonly status: "active" | "waiting" | "completed" | "cancelled" | "failed";
  readonly failureReason?: string;
  readonly workflowStepId?: string;
}

type ExecutionEnv = Env & {
  readonly SYNTILA_THREAD_COORDINATOR?: DurableObjectNamespace;
};

interface AssignmentRow {
  status: string;
  outputJson: string | null;
  errorJson: string | null;
  workerId: string | null;
  workerTypeId: string | null;
  engineVersion: string | null;
  model: string | null;
  permissionSnapshotJson: string | null;
  assignmentId: string;
  attemptId: string;
  workspaceId: string | null;
  createdAt: string;
  updatedAt: string;
  queueWaitTimeoutMs: number | null;
  /** Set once a start permit was granted: a process may have been launched. */
  permitIssuedAt: string | null;
  permitRequired: number | null;
  /** Events that start the per-phase deadlines. */
  dispatchedAt: string | null;
  acknowledgedAt: string | null;
  runningAt: string | null;
}

const PHASE_FAILURE_MESSAGE: Record<AssignmentDeadlinePhase, string> = {
  readiness_wait:
    "The Workspace Service was not ready to accept the assignment in time. Check that it is running and synchronized, then retry.",
  command_delivery:
    "Workspace did not acknowledge the assignment. Check its connection and retry.",
  queue_wait:
    "The Workspace did not start the assignment before its queue wait limit. Retry the step.",
  startup:
    "The Workspace was cleared to start the assignment but did not report the provider as started. Retry the step.",
  provider_execution: "The assignment exceeded its execution deadline.",
};

function parseJsonRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "string") return {};
  try {
    const parsed: unknown = JSON.parse(value);
    return typeof parsed === "object" &&
      parsed !== null &&
      !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : {};
  } catch {
    return {};
  }
}

const stepConfig = {
  retries: {
    limit: 3,
    delay: "5 seconds" as const,
    backoff: "exponential" as const,
  },
  timeout: "5 minutes" as const,
} as const;

function parseWorkflowStepResult(value: unknown): StepResult | null {
  if (typeof value !== "string") return null;
  try {
    const parsed: unknown = JSON.parse(value);
    if (
      typeof parsed !== "object" ||
      parsed === null ||
      Array.isArray(parsed)
    ) {
      return null;
    }
    const result = parsed as Partial<StepResult>;
    return result.status === "completed" && typeof result.text === "string"
      ? (result as StepResult)
      : null;
  } catch {
    return null;
  }
}

export class SyntilaRunWorkflow extends WorkflowEntrypoint<
  Env,
  SyntilaWorkflowParams
> {
  private async persistTerminalRun(
    runId: string,
    status: "completed" | "failed" | "cancelled",
  ): Promise<void> {
    const db = (this.env as ExecutionEnv).SYNTILA_DB;
    if (!db) return;
    const now = new Date().toISOString();
    await db
      .prepare(
        "UPDATE runs SET status = ?1, finished_at = ?2, updated_at = ?2 WHERE id = ?3",
      )
      .bind(status, now, runId)
      .run();
  }

  /** Extends the active Thread lease of this Work Request. Best effort. */
  private async renewThreadLease(params: SyntilaWorkflowParams): Promise<void> {
    if (!params.workRequestId || !params.threadId) return;
    try {
      const runtimeEnv = this.env as ExecutionEnv;
      const db = runtimeEnv.SYNTILA_DB;
      const namespace = runtimeEnv.SYNTILA_THREAD_COORDINATOR;
      if (!db || !namespace) return;
      const lease = await db
        .prepare(
          `SELECT id, fencing_token AS fencingToken FROM thread_runtime_leases
         WHERE work_request_id = ?1 AND thread_id = ?2 AND status = 'active' LIMIT 1`,
        )
        .bind(params.workRequestId, params.threadId)
        .first<{ id: string; fencingToken: number }>();
      if (!lease) return;
      await namespace
        .getByName(params.threadId)
        .fetch("https://thread-coordinator/heartbeat", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-thread-id": params.threadId,
          },
          body: JSON.stringify({
            workRequestId: params.workRequestId,
            leaseId: lease.id,
            fencingToken: lease.fencingToken,
          }),
        });
    } catch {
      // The lease is only extended opportunistically; the next wake-up retries.
    }
  }

  /**
   * Finalizes the Work Request and gives up its Thread lease. Runs as a
   * durable step so a Workflow restart cannot apply one outcome and then
   * replay into another. The coordinator keeps the lease while the Worker may
   * still be running, and a completion that arrives after the lease is gone
   * still marks the request completed.
   */
  private async finishWorkRequest(
    params: SyntilaWorkflowParams,
    status: "completed" | "failed" | "cancelled",
    workflowStep: WorkflowStep,
  ): Promise<void> {
    await workflowStep.do(`workflow:finish:${status}`, stepConfig, async () => {
      await this.finishWorkRequestNow(params, status);
      return true;
    });
  }

  private async finishWorkRequestNow(
    params: SyntilaWorkflowParams,
    status: "completed" | "failed" | "cancelled",
  ): Promise<void> {
    if (!params.workRequestId || !params.threadId) return;
    const runtimeEnv = this.env as ExecutionEnv;
    const db = runtimeEnv.SYNTILA_DB;
    const namespace = runtimeEnv.SYNTILA_THREAD_COORDINATOR;
    if (!db) return;
    const request = await db
      .prepare(
        "SELECT mode FROM work_requests WHERE id = ?1 AND thread_id = ?2",
      )
      .bind(params.workRequestId, params.threadId)
      .first<{ mode: string }>();
    if (request?.mode === "stateless") {
      const now = new Date().toISOString();
      await db
        .prepare(
          "UPDATE work_requests SET status = ?1, updated_at = ?2 WHERE id = ?3 AND status IN ('queued', 'running')",
        )
        .bind(status, now, params.workRequestId)
        .run();
      return;
    }
    if (!namespace) return;
    const lease = await db
      .prepare(
        `SELECT id, fencing_token AS fencingToken FROM thread_runtime_leases
       WHERE work_request_id = ?1 AND thread_id = ?2 AND status = 'active' LIMIT 1`,
      )
      .bind(params.workRequestId, params.threadId)
      .first<{ id: string; fencingToken: number }>();
    if (!lease) {
      // The lease is already gone (an earlier failure path released it, or it
      // expired). A Workflow that still finished every step completed the
      // request; do not leave a finished result marked failed.
      if (status === "completed") {
        const now = new Date().toISOString();
        await db.batch([
          db
            .prepare(
              `UPDATE work_requests SET status = 'completed', updated_at = ?1
                WHERE id = ?2 AND status = 'failed'
                  AND NOT EXISTS (SELECT 1 FROM workflow_tasks
                                   WHERE work_request_id = ?2 AND status != 'completed')`,
            )
            .bind(now, params.workRequestId),
        ]);
      }
      return;
    }
    const stub = namespace.getByName(params.threadId);
    await stub.fetch("https://thread-coordinator/complete", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-thread-id": params.threadId,
      },
      body: JSON.stringify({
        workRequestId: params.workRequestId,
        leaseId: lease.id,
        fencingToken: lease.fencingToken,
        status,
      }),
    });
  }

  private async persistWorkflowTasks(
    params: SyntilaWorkflowParams,
    tasks: readonly PlannedWorkflowTask[],
  ): Promise<void> {
    const db = (this.env as ExecutionEnv).SYNTILA_DB;
    if (!db || !params.workRequestId) return;
    const now = new Date().toISOString();
    const statements = tasks.flatMap((task) => [
      db
        .prepare(
          `INSERT INTO workflow_tasks
         (id, work_request_id, step_kind, execution_mode,
          timeout_ms, prompt_profile_version,
          status, attempt, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'queued', 0, ?7, ?7)
         ON CONFLICT(work_request_id, step_kind) DO NOTHING`,
        )
        .bind(
          task.id,
          task.workRequestId,
          task.step.kind,
          task.step.executionMode,
          task.step.timeoutMs,
          task.step.promptProfileVersion,
          now,
        ),
      ...task.dependencyTaskIds.map((dependencyId) =>
        db
          .prepare(
            `INSERT INTO workflow_task_dependencies (task_id, depends_on_task_id)
           VALUES (?1, ?2) ON CONFLICT(task_id, depends_on_task_id) DO NOTHING`,
          )
          .bind(task.id, dependencyId),
      ),
    ]);
    if (statements.length > 0) await db.batch(statements);
  }

  private async publishWorkEvent(
    params: SyntilaWorkflowParams,
    type:
      | "work_request.started"
      | "work_request.completed"
      | "work_request.failed"
      | "work_request.cancelled"
      | "step.queued"
      | "step.running"
      | "step.completed"
      | "step.failed"
      | "step.cancelled",
    options: { status: string; stepKind?: StepKind; attempt?: number },
  ): Promise<void> {
    const workRequestId = params.workRequestId;
    const threadId = params.threadId;
    const workspaceId = params.organizationId;
    if (!workRequestId || !threadId || !workspaceId) return;
    try {
      const spaceId =
        params.spaceId ??
        (
          await (this.env as ExecutionEnv).SYNTILA_DB.prepare(
            "SELECT space_id AS spaceId FROM threads WHERE id = ?1",
          )
            .bind(threadId)
            .first<{ spaceId: string }>()
        )?.spaceId;
      if (!spaceId) return;
      // Lets clients skip "finished" notices for the person who asked.
      const requestedByUserId = type.startsWith("work_request.")
        ? ((
            await (this.env as ExecutionEnv).SYNTILA_DB.prepare(
              "SELECT requested_by_user_id AS userId FROM work_requests WHERE id = ?1",
            )
              .bind(workRequestId)
              .first<{ userId: string }>()
          )?.userId ?? null)
        : null;
      const stepSuffix = options.stepKind ? `:step:${options.stepKind}` : "";
      const attemptSuffix = options.attempt
        ? `:attempt:${options.attempt}`
        : "";
      await createEventPublisher(this.env).publish({
        type,
        workspaceId,
        spaceId,
        runId: params.runId,
        idempotencyKey: `work-request:${workRequestId}:${type}${stepSuffix}${attemptSuffix}`,
        payload: {
          entityId: options.stepKind ?? workRequestId,
          workRequestId,
          threadId,
          ...(requestedByUserId ? { requestedByUserId } : {}),
          ...(options.stepKind ? { stepKind: options.stepKind } : {}),
          status: options.status,
        },
      });
      if (
        type === "work_request.completed" ||
        type === "work_request.failed" ||
        type === "work_request.cancelled"
      ) {
        // The Thread is free again: send the next queued request, or pause
        // the queue when this request failed.
        await advanceThreadQueueSafely(this.env as SecurityEnv, threadId, {
          failedRequest: type === "work_request.failed",
        });
      }
    } catch (error) {
      console.error(`Failed to publish ${type}`, error);
    }
  }

  private async persistWorkflowTaskState(
    task: PlannedWorkflowTask,
    output?: unknown,
    error?: string,
    status: PlannedWorkflowTask["status"] = task.status,
    attempt: number = task.attempt,
  ): Promise<void> {
    const db = (this.env as ExecutionEnv).SYNTILA_DB;
    if (!db) return;
    await db
      .prepare(
        `UPDATE workflow_tasks SET status = ?1, attempt = ?2, output_json = ?3,
       error = ?4, updated_at = ?5,
       started_at = CASE WHEN ?1 = 'running' THEN COALESCE(started_at, ?5) ELSE started_at END,
       finished_at = CASE WHEN ?1 IN ('completed', 'failed', 'cancelled') THEN ?5 ELSE finished_at END
       WHERE id = ?6`,
      )
      .bind(
        status,
        attempt,
        output === undefined ? null : JSON.stringify(output),
        error ?? null,
        new Date().toISOString(),
        task.id,
      )
      .run();
  }

  /**
   * Waits until every file input of the request is `delivered`, one fails,
   * the request is cancelled, or no input changes for
   * [INPUT_DELIVERY_IDLE_TIMEOUT_MS]. D1 is the authority; events from the
   * input routes only shorten the bounded waits.
   */
  private async awaitWorkRequestInputs(
    params: SyntilaWorkflowParams,
    step: WorkflowStep,
  ): Promise<
    | { outcome: "none" | "delivered" }
    | { outcome: "failed" | "cancelled"; message: string }
  > {
    const db = (this.env as ExecutionEnv).SYNTILA_DB;
    if (!db || !params.workRequestId || params.retryStepKind)
      return { outcome: "none" };
    for (let round = 0; ; round += 1) {
      const rows = await loadWorkRequestInputs(db, params.workRequestId);
      const request = await db
        .prepare(
          "SELECT cancel_requested_at AS cancelRequestedAt FROM work_requests WHERE id = ?1",
        )
        .bind(params.workRequestId)
        .first<{ cancelRequestedAt: string | null }>();
      const decision = inputGateDecision(
        rows,
        !!request?.cancelRequestedAt,
        Date.now(),
      );
      if (decision.outcome === "none" || decision.outcome === "delivered")
        return { outcome: decision.outcome };
      if ("message" in decision) return decision;
      try {
        await step.waitForEvent(`work-inputs-${round}`, {
          type: WORK_INPUTS_EVENT_TYPE,
          timeout: "30 seconds",
        });
      } catch {
        // A timeout is the re-read path.
      }
    }
  }

  private async runVersioned(
    params: SyntilaWorkflowParams,
    step: WorkflowStep,
  ): Promise<SyntilaWorkflowCheckpoint> {
    const definition = params.builtinWorkflow!;
    validateBuiltinWorkflowDefinition(definition);
    const workRequestId = params.workRequestId ?? `run-${params.runId}`;
    let promptInput = await this.loadWorkRequestPromptInput(params);
    let tasks = [...planWorkflowTasks(definition, workRequestId)];
    const stepResults: Partial<Record<StepKind, StepResult>> = {};
    const db = (this.env as ExecutionEnv).SYNTILA_DB;
    if (db && params.workRequestId) {
      const requestMode = await db
        .prepare("SELECT mode FROM work_requests WHERE id = ?1")
        .bind(params.workRequestId)
        .first<{ mode: string }>();
      if (requestMode?.mode === "stateless") {
        const now = new Date().toISOString();
        await db.batch([
          db
            .prepare(
              "UPDATE work_requests SET status = 'running', updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
            )
            .bind(now, params.workRequestId),
          db
            .prepare(
              "UPDATE runs SET status = 'running', updated_at = ?1 WHERE work_request_id = ?2 AND status = 'created'",
            )
            .bind(now, params.workRequestId),
        ]);
      }
    }
    await this.persistWorkflowTasks(params, tasks);
    if (params.retryStepKind && db && params.workRequestId) {
      const persistedRows = await db
        .prepare(
          `SELECT step_kind AS kind, status, attempt, output_json AS outputJson
           FROM workflow_tasks WHERE work_request_id = ?1`,
        )
        .bind(params.workRequestId)
        .all<Record<string, unknown>>();
      const persistedByKind = new Map(
        (persistedRows.results ?? []).map((row) => [String(row.kind), row]),
      );
      tasks = tasks.map((task) => {
        // The retried step is re-executed by this run. The workflow function
        // body is replayed on every wake-up, and by then the retried step's
        // own task row may already be completed by the terminal-result handler
        // (its output is the assignment output, not a step result), so it must
        // never be preloaded here.
        if (task.step.kind === params.retryStepKind) return task;
        const persisted = persistedByKind.get(task.step.kind);
        if (persisted?.status !== "completed") return task;
        const output = parseWorkflowStepResult(persisted.outputJson);
        if (!output) {
          throw new Error(
            `Completed ${task.step.kind} result is unavailable for retry`,
          );
        }
        stepResults[task.step.kind] = output;
        return {
          ...task,
          status: "completed",
          attempt:
            typeof persisted.attempt === "number" ? persisted.attempt : 0,
        };
      });
    }
    await this.publishWorkEvent(params, "work_request.started", {
      status: "running",
    });
    await Promise.all(
      tasks
        .filter((task) => task.status === "queued")
        .map((task) =>
          this.publishWorkEvent(params, "step.queued", {
            stepKind: task.step.kind,
            status: "queued",
          }),
        ),
    );
    const started: SyntilaWorkflowCheckpoint = {
      runId: params.runId,
      goalId: params.goalId,
      idempotencyKey: params.idempotencyKey,
      stage: "workflow",
      status: "active",
    };

    // Input Delivery v1: no step is dispatched until every file input is on
    // the target Workspace. The assignment flow below is unchanged.
    const inputs = await this.awaitWorkRequestInputs(params, step);
    if (inputs.outcome === "failed" || inputs.outcome === "cancelled") {
      const status = inputs.outcome === "cancelled" ? "cancelled" : "failed";
      const first = tasks.find((task) => task.status === "queued");
      for (const task of tasks.filter((task) => task.status === "queued")) {
        await this.persistWorkflowTaskState(
          task,
          undefined,
          task === first ? inputs.message : undefined,
          status,
        );
      }
      await this.persistTerminalRun(params.runId, status);
      await this.finishWorkRequest(params, status, step);
      if (status === "failed") {
        if (first)
          await this.publishWorkEvent(params, "step.failed", {
            stepKind: first.step.kind,
            status: "failed",
          });
        await this.publishWorkEvent(params, "work_request.failed", {
          status: "failed",
        });
      }
      return {
        ...started,
        stage: status,
        status,
        workflowStepId: first?.step.kind,
        failureReason: inputs.message,
      };
    }
    // Dispatch carries each file's verified digest so the Service can check
    // its delivered copy; the stored request input never changes.
    if (inputs.outcome === "delivered" && db && params.workRequestId)
      promptInput = withInputFacts(
        promptInput,
        await loadWorkRequestInputs(db, params.workRequestId),
      );

    while (true) {
      const ready = readyWorkflowTasks(tasks);
      if (ready.length === 0) {
        if (tasks.every((task) => task.status === "completed")) break;
        const failed = tasks.find(
          (task) => task.status === "failed" || task.status === "cancelled",
        );
        const status = failed?.status === "cancelled" ? "cancelled" : "failed";
        await this.persistTerminalRun(params.runId, status);
        await this.finishWorkRequest(params, status, step);
        if (status === "failed") {
          await this.publishWorkEvent(params, "work_request.failed", {
            status: "failed",
          });
        }
        return {
          ...started,
          stage: status,
          status,
          workflowStepId: failed?.step.kind,
          failureReason: failed
            ? `Workflow step ${failed.step.kind} ${failed.status}`
            : "Workflow has no runnable steps",
        };
      }
      // Stateful Thread steps are never concurrent. Independent stateless
      // steps can share one durable Workflow batch.
      const batch = ready.some(
        (task) => task.step.executionMode === "stateful_thread",
      )
        ? [ready.find((task) => task.step.executionMode === "stateful_thread")!]
        : ready;
      const results = await Promise.all(
        batch.map((task) =>
          this.runWorkflowTask(
            params,
            definition,
            task,
            promptInput,
            step,
            stepResults,
          ),
        ),
      );
      for (const result of results) {
        const cancellationRequested = await (
          this.env as ExecutionEnv
        ).SYNTILA_DB.prepare(
          "SELECT cancel_requested_at AS cancelRequestedAt FROM work_requests WHERE id = ?1",
        )
          .bind(params.workRequestId)
          .first<{ cancelRequestedAt: string | null }>();
        const resultStatus = cancellationRequested?.cancelRequestedAt
          ? "cancelled"
          : result.status;
        if (resultStatus === "completed" && result.stepResult) {
          stepResults[result.task.step.kind] = result.stepResult;
        }
        tasks = [
          ...markWorkflowTaskResult(tasks, result.task.id, resultStatus),
        ];
        const persistedTask = tasks.find((task) => task.id === result.task.id)!;
        workflowDiagnostic(this.env, "task_state_start", {
          runId: params.runId,
          status: resultStatus,
        });
        await this.persistWorkflowTaskState(
          persistedTask,
          result.output,
          result.error,
        );
        workflowDiagnostic(this.env, "task_state_done", {
          runId: params.runId,
        });
        if (resultStatus === "completed" || resultStatus === "failed") {
          await this.publishWorkEvent(
            params,
            resultStatus === "completed" ? "step.completed" : "step.failed",
            { stepKind: result.task.step.kind, status: resultStatus },
          );
          workflowDiagnostic(this.env, "step_event_published", {
            runId: params.runId,
          });
        }
        if (resultStatus === "failed" || resultStatus === "cancelled") {
          const failed = tasks.find(
            (candidate) => candidate.id === result.task.id,
          )!;
          await this.persistTerminalRun(params.runId, resultStatus);
          await this.finishWorkRequest(params, resultStatus, step);
          if (resultStatus === "failed") {
            await this.publishWorkEvent(params, "work_request.failed", {
              status: "failed",
            });
          } else {
            await this.publishWorkEvent(params, "step.cancelled", {
              stepKind: result.task.step.kind,
              status: "cancelled",
            });
            await this.publishWorkEvent(params, "work_request.cancelled", {
              stepKind: result.task.step.kind,
              status: "cancelled",
            });
          }
          return {
            ...started,
            stage: resultStatus,
            status: resultStatus,
            workflowStepId: failed.step.kind,
            failureReason:
              result.error ??
              `Workflow step ${failed.step.kind} ${resultStatus}`,
          };
        }
      }
    }
    workflowDiagnostic(this.env, "terminal_run_start", { runId: params.runId });
    await this.persistTerminalRun(params.runId, "completed");
    workflowDiagnostic(this.env, "finish_request_start", {
      runId: params.runId,
    });
    await this.finishWorkRequest(params, "completed", step);
    workflowDiagnostic(this.env, "completed_event_start", {
      runId: params.runId,
    });
    await this.publishWorkEvent(params, "work_request.completed", {
      status: "completed",
    });
    workflowDiagnostic(this.env, "run_returning", { runId: params.runId });
    return { ...started, stage: "completed", status: "completed" };
  }

  private async runWorkflowTask(
    params: SyntilaWorkflowParams,
    definition: BuiltinWorkflowDefinition,
    task: PlannedWorkflowTask,
    promptInput: Record<string, unknown>,
    workflowStep: WorkflowStep,
    stepResults: Partial<Record<StepKind, StepResult>>,
  ): Promise<{
    task: PlannedWorkflowTask;
    status: "completed" | "failed" | "cancelled";
    output?: unknown;
    stepResult?: StepResult;
    error?: string;
  }> {
    const db = (this.env as ExecutionEnv).SYNTILA_DB;
    if (!db || !params.workRequestId) {
      return {
        task,
        status: "failed",
        error: "Work Request execution context is unavailable",
      };
    }
    let attempt = 0;
    const startedAt = new Date().toISOString();
    const workBindingId =
      definition.id === "direct" ? "direct" : task.step.kind;
    const workConfig =
      typeof promptInput.workConfig === "object" &&
      promptInput.workConfig !== null
        ? (promptInput.workConfig as Record<string, unknown>)
        : {};
    const bindings =
      typeof workConfig.bindings === "object" && workConfig.bindings !== null
        ? (workConfig.bindings as Record<string, unknown>)
        : {};
    const stepBinding =
      typeof bindings[workBindingId] === "object" &&
      bindings[workBindingId] !== null
        ? (bindings[workBindingId] as Record<string, unknown>)
        : {};
    while (attempt < 3) {
      attempt += 1;
      await this.persistWorkflowTaskState(
        task,
        undefined,
        undefined,
        "queued",
        attempt,
      );
      try {
        const assignment = await workflowStep.do(
          `workflow:${task.step.kind}:dispatch:${attempt}`,
          {
            ...stepConfig,
            timeout: "1 minute",
          },
          async () => {
            // T3: the Workflow step that hands the task to the dispatcher.
            tryLogTraceEvent({
              traceStage: "workflow_dispatch_started",
              requestId: params.workRequestId,
              workspaceId: params.organizationId,
              runId: params.runId,
              taskId: task.id,
              context: { status: `attempt_${attempt}` },
            });
            const promptInputs = workStepPromptInputs(
              { ...promptInput, workRequestId: params.workRequestId },
              stepResults,
            );
            const configuredInstructions =
              typeof stepBinding.additionalInstructions === "string"
                ? stepBinding.additionalInstructions
                : "";
            const requestInstructions =
              promptInputs.stepInstructions?.[task.step.kind] ?? "";
            const mergedInstructions = [
              requestInstructions,
              configuredInstructions,
            ]
              .filter((value) => value.trim().length > 0)
              .join("\n\n");
            const prompt = renderWorkStepPrompt(definition, task.step, {
              ...promptInputs,
              stepInstructions: {
                ...promptInputs.stepInstructions,
                ...(mergedInstructions
                  ? { [task.step.kind]: mergedInstructions }
                  : {}),
              },
            });
            if (!prompt.trim()) throw new Error("Work Step prompt is empty");
            const context = await db
              .prepare(
                `SELECT wr.thread_id AS threadId,
                      wr.requested_by_user_id AS requesterUserId,
                      wr.status AS workRequestStatus,
                      wr.cancel_requested_at AS cancelRequestedAt,
                      ws.space_id AS spaceId,
                      s.name AS spaceName,
                      s.owner_user_id AS spaceOwnerUserId,
                      CASE WHEN wr.ai_context_generation = ws.ai_context_generation THEN ws.work_session_generation
                        ELSE -1 - wr.ai_context_generation END AS workSessionGeneration
                 FROM work_requests wr JOIN threads ws ON ws.id = wr.thread_id
                 JOIN spaces s ON s.id = ws.space_id
                WHERE wr.id = ?1`,
              )
              .bind(params.workRequestId)
              .first<{
                threadId: string;
                requesterUserId: string;
                workRequestStatus: string;
                cancelRequestedAt: string | null;
                spaceId: string;
                spaceName: string;
                spaceOwnerUserId: string | null;
                workSessionGeneration: number;
              }>();
            if (!context) throw new Error("Work Request was not found");
            if (
              context.workRequestStatus === "cancelled" ||
              context.cancelRequestedAt
            ) {
              return { status: "cancelled", assignmentId: "", startedAt };
            }
            const bindingId = workBindingId as ThreadBindingId;
            const {
              workConfig: _workConfig,
              workRequestSnapshot: _snapshot,
              ...workerInput
            } = promptInput;
            const execution = prepareWorkerStepExecution({
              taskId: task.id,
              step: task.step,
              bindingId,
              binding: stepBinding,
              prompt,
              workerInput,
              scope: {
                spaceId: context.spaceId,
                spaceName: context.spaceName,
                ...(context.spaceOwnerUserId
                  ? { spaceOwnerUserId: context.spaceOwnerUserId }
                  : {}),
                requesterUserId: context.requesterUserId,
                threadId: context.threadId,
                workRequestId: params.workRequestId!,
                workSessionGeneration: context.workSessionGeneration,
              },
              retry: {
                stepKind: params.retryStepKind,
                sessionStrategy: params.retrySessionStrategy,
                number: params.retryNumber,
                adoptSpaceFolder: params.retryAdoptSpaceFolder === true,
                compactContext: params.retryCompactContext === true,
              },
            });
            const dispatched = await dispatchTaskAssignment(
              this.env as unknown as AssignmentDispatcherEnv,
              {
                workspaceId: params.organizationId ?? "",
                runId: params.runId,
                taskId: task.id,
                explicitWorkerId: execution.workerId,
                explicitAttemptNumber: attempt,
                task: execution.task,
              },
            );
            if (dispatched.status === "cancelled") {
              return {
                status: "cancelled",
                assignmentId: dispatched.assignmentId,
                attemptId: dispatched.attemptId,
                startedAt,
              };
            }
            if (!dispatched.accepted || !dispatched.assignmentId) {
              throw new Error(
                dispatched.error ?? `${task.step.kind} Worker dispatch failed`,
              );
            }
            return {
              status: "dispatched",
              assignmentId: dispatched.assignmentId,
              attemptId: dispatched.attemptId,
              startedAt,
            };
          },
        );
        if (assignment.status === "cancelled") {
          return {
            task,
            status: "cancelled",
            error: "Work assignment was cancelled",
          };
        }
        const readAssignment = () =>
          db
            .prepare(
              `SELECT wa.id AS assignmentId, wa.status, wa.output_json AS outputJson,
                      wa.error_json AS errorJson, wa.workspace_worker_id AS workerId,
                      wa.worker_type_id AS workerTypeId, wa.engine_version AS engineVersion,
                      wa.model, wa.permission_snapshot_json AS permissionSnapshotJson,
                      wa.attempt_id AS attemptId,
                      wa.execution_workspace_id AS workspaceId,
                      wa.created_at AS createdAt, wa.updated_at AS updatedAt,
                      wa.queue_wait_timeout_ms AS queueWaitTimeoutMs,
                      wa.start_permit_issued_at AS permitIssuedAt,
                      wa.start_permit_required AS permitRequired,
                      wa.dispatched_at AS dispatchedAt,
                      wa.acknowledged_at AS acknowledgedAt,
                      wa.running_at AS runningAt
                 FROM worker_assignments wa WHERE wa.id = ?1`,
            )
            .bind(assignment.assignmentId)
            .first<AssignmentRow>();
        let terminal: AssignmentRow | null = null;
        // Status the assignment had when Cloud began revoking it. `running`
        // means the provider may have acted, so the step is not replayed.
        let revokedAfter: AssignmentLifecycleStatus | null = null;
        const isTerminalRow = (row: AssignmentRow | null): boolean =>
          !!row &&
          ["completed", "failed", "cancelled", "timed_out"].includes(
            row.status,
          );
        // The Workflow sleeps until a terminal notification arrives. Each
        // wake-up (an event, a phase deadline or the reconciliation interval)
        // re-reads the authoritative row, so a lost, early, duplicated or
        // stale event can only cost one extra read. The cap below is a safety
        // valve; the time bound is the D1-derived provider deadline.
        const maxWakeups =
          Math.ceil(
            (effectiveStepTimeoutMs(task.step.timeoutMs) +
              2 * DEFAULT_QUEUE_WAIT_TIMEOUT_MS) /
              ASSIGNMENT_RECONCILIATION_INTERVAL_MS,
          ) + WAKEUP_SLACK;
        for (let wakeup = 0; wakeup < maxWakeups; wakeup += 1) {
          terminal = await workflowStep.do(
            `workflow:${task.step.kind}:assignment-status:${attempt}:${wakeup}`,
            { ...stepConfig, timeout: "30 seconds" },
            async () => {
              const row = await readAssignment();
              // The Thread lease is a liveness lease, not a time limit: keep
              // it alive for as long as this Workflow is still watching the
              // assignment, so a long run is not failed after 20 minutes.
              if (row && !isTerminalRow(row))
                await this.renewThreadLease(params);
              // Work waiting for a Service that was not ready is flushed by
              // the Gateway when it becomes ready. Nudging here makes a lost
              // or hibernation-missed readiness event harmless.
              if (row?.status === "created" && row.workspaceId) {
                await nudgeQueuedAssignments(
                  this.env as unknown as AssignmentDispatcherEnv,
                  row.workspaceId,
                );
              }
              return row;
            },
          );
          if (
            terminal &&
            ["completed", "failed", "cancelled", "timed_out"].includes(
              terminal.status,
            )
          ) {
            // Lag between the terminal row being written and this wake-up seeing
            // it. Both timestamps originate in Cloud, so the difference is
            // valid without clock-offset correction.
            const persistedAt = Date.parse(terminal.updatedAt);
            tryLogTraceEvent({
              traceStage: "workflow_observed_terminal",
              requestId: params.workRequestId,
              workspaceId: params.organizationId,
              runId: params.runId,
              taskId: task.id,
              assignmentId: terminal.assignmentId,
              attemptId: terminal.attemptId,
              ...(Number.isFinite(persistedAt)
                ? { durationMs: Math.max(0, Date.now() - persistedAt) }
                : {}),
              context: { status: terminal.status },
            });
            workflowDiagnostic(this.env, "observed_terminal", {
              runId: params.runId,
              status: terminal.status,
            });
            break;
          }
          // Each phase measures from its own event. Provider execution is
          // bounded by the wake-up budget and the final-timeout path below.
          const violation = terminal
            ? assignmentDeadlineViolation({
                status: terminal.status,
                createdAt: terminal.createdAt,
                updatedAt: terminal.updatedAt,
                dispatchedAt: terminal.dispatchedAt,
                acknowledgedAt: terminal.acknowledgedAt,
                startPermitIssuedAt: terminal.permitIssuedAt,
                startPermitRequired: terminal.permitRequired === 1,
                runningAt: terminal.runningAt,
                queueWaitTimeoutMs:
                  terminal.queueWaitTimeoutMs ?? DEFAULT_QUEUE_WAIT_TIMEOUT_MS,
              })
            : null;
          if (
            terminal &&
            violation &&
            violation.phase !== "provider_execution"
          ) {
            const phaseMessage = PHASE_FAILURE_MESSAGE[violation.phase];
            // Expiry was decided from this status. If an acknowledgement
            // moved the assignment on since the read, the conditional write
            // below leaves it alone and the next wake-up observes the new state.
            const observedStatus = terminal.status as AssignmentLifecycleStatus;
            await workflowStep.do(
              `workflow:${task.step.kind}:delivery-timeout:${attempt}`,
              stepConfig,
              async () => {
                // Cloud may not call the work stopped: the command can sit in
                // the Service queue. Revoke it; the terminal outcome is
                // written only when the Service confirms.
                await revokeAssignment(this.env as unknown as RevocationEnv, {
                  assignmentId: assignment.assignmentId,
                  attemptId: assignment.attemptId,
                  onlyFrom: [observedStatus],
                  intent: {
                    status: "failed",
                    reason: phaseMessage,
                    source: "startup_deadline",
                    failure: {
                      error: {
                        code: "provider_unavailable",
                        message: phaseMessage,
                        retryable: true,
                      },
                      failedAt: new Date().toISOString(),
                    },
                  },
                });
              },
            );
            revokedAfter = observedStatus;
            continue;
          }
          const providerOverrun =
            !!terminal &&
            terminal.status === "running" &&
            providerExecutionOverrun(
              terminal,
              effectiveStepTimeoutMs(task.step.timeoutMs),
            );
          if (providerOverrun) break;
          await waitForTerminalEvent(
            workflowStep,
            `workflow:${task.step.kind}:assignment-wait:${attempt}:${wakeup}`,
            nextWakeupMs(terminal, effectiveStepTimeoutMs(task.step.timeoutMs)),
          );
        }
        if (!isTerminalRow(terminal)) {
          // The deadline passed without a terminal outcome. Start revocation
          // (idempotent if the delivery timeout already did) and wait a
          // bounded time for the Service to confirm.
          const observed = (terminal?.status ??
            "running") as AssignmentLifecycleStatus;
          await workflowStep.do(
            `workflow:${task.step.kind}:timeout-revoke:${attempt}`,
            stepConfig,
            async () => {
              await revokeAssignment(this.env as unknown as RevocationEnv, {
                assignmentId: assignment.assignmentId,
                attemptId: assignment.attemptId,
                intent: {
                  status: "timed_out",
                  reason: "The assignment exceeded its time limit.",
                  source: "execution_deadline",
                  failure: {
                    error: {
                      code: "timeout",
                      message: "The assignment exceeded its time limit.",
                      retryable: true,
                    },
                    failedAt: new Date().toISOString(),
                  },
                },
              });
            },
          );
          revokedAfter ??= observed;
          for (
            let round = 0;
            round < REVOCATION_CONFIRMATION_ROUNDS;
            round += 1
          ) {
            terminal = await workflowStep.do(
              `workflow:${task.step.kind}:revocation-status:${attempt}:${round}`,
              { ...stepConfig, timeout: "30 seconds" },
              async () => {
                const row = await readAssignment();
                // Re-send the cancel while waiting; the Service may have
                // been offline when revocation began.
                if (row && !isTerminalRow(row) && round > 0) {
                  await deliverRevocation(
                    this.env as unknown as RevocationEnv,
                    assignment.assignmentId,
                  );
                }
                return row;
              },
            );
            if (isTerminalRow(terminal)) break;
            await waitForTerminalEvent(
              workflowStep,
              `workflow:${task.step.kind}:revocation-wait:${attempt}:${round}`,
              REVOCATION_CONFIRMATION_ROUND_MS,
            );
          }
          if (!isTerminalRow(terminal)) {
            // Final look after the last wait, so a confirmation that arrived
            // during it is not reported as unconfirmed.
            terminal = await workflowStep.do(
              `workflow:${task.step.kind}:revocation-status:${attempt}:final`,
              { ...stepConfig, timeout: "30 seconds" },
              async () => readAssignment(),
            );
          }
        }
        const errorRecord = parseJsonRecord(terminal?.errorJson);
        const errorValue = parseJsonRecord(errorRecord.error);
        const outcome = classifyStepAssignmentOutcome({
          status: terminal?.status,
          hasOutput: !!terminal?.outputJson,
          ...(typeof errorValue.message === "string"
            ? { errorMessage: errorValue.message }
            : {}),
          // A granted start permit means a process may have been launched
          // even if the Service never reported it.
          revokedAfter: terminal?.permitIssuedAt ? "running" : revokedAfter,
        });
        if (outcome.kind === "cancelled") {
          return {
            task,
            status: "cancelled",
            error: "Work assignment was cancelled",
          };
        }
        if (outcome.kind === "failed") {
          throw outcome.retryable
            ? new Error(outcome.message)
            : new AssignmentNotRetryableError(outcome.message);
        }
        if (!terminal) throw new Error("Work Step assignment timed out");
        const stepResult = completeWorkerStepExecution({
          output: parseJsonRecord(terminal.outputJson),
          evidence: parseJsonRecord(terminal.permissionSnapshotJson),
          attribution: {
            workerId: terminal.workerId,
            workerTypeId: terminal.workerTypeId,
            engineVersion: terminal.engineVersion,
            model: terminal.model,
          },
          startedAt: terminal.createdAt || startedAt,
          completedAt: new Date().toISOString(),
          configuredEffort: stepBinding.reasoningEffort,
        });
        return { task, status: "completed", output: stepResult, stepResult };
      } catch (error) {
        if (
          error instanceof Error &&
          error.name === "WorkAssignmentCancelledError"
        ) {
          return { task, status: "cancelled", error: error.message };
        }
        // Conversational turns require explicit retry to avoid replaying a turn
        // into a durable provider conversation after an ambiguous failure.
        if (
          definition.id === "direct" ||
          definition.id === "chat" ||
          attempt >= 3 ||
          (error instanceof Error &&
            error.name === "AssignmentNotRetryableError")
        ) {
          return {
            task,
            status: "failed",
            error: error instanceof Error ? error.message : String(error),
          };
        }
      }
    }
    return {
      task,
      status: "failed",
      error: "Workflow step retry limit exceeded",
    };
  }

  private async loadWorkRequestPromptInput(
    params: SyntilaWorkflowParams,
  ): Promise<Record<string, unknown>> {
    const callerInput = params.input ?? {};
    if (!params.workRequestId) return callerInput;
    const db = (this.env as ExecutionEnv).SYNTILA_DB;
    if (!db) return callerInput;
    const row = await db
      .prepare(
        `SELECT wr.input_json AS inputJson, wr.snapshot_json AS snapshotJson
         FROM work_requests wr
         WHERE wr.id = ?1`,
      )
      .bind(params.workRequestId)
      .first<{
        inputJson: string;
        snapshotJson: string | null;
      }>();
    if (!row) return callerInput;
    const parseRecord = (value: string | null | undefined) => {
      if (!value) return {};
      try {
        const parsed: unknown = JSON.parse(value);
        return typeof parsed === "object" &&
          parsed !== null &&
          !Array.isArray(parsed)
          ? (parsed as Record<string, unknown>)
          : {};
      } catch {
        return {};
      }
    };
    const persistedInput = parseRecord(row.inputJson);
    const snapshot = parseRecord(row.snapshotJson);
    const resolvedBindings =
      typeof snapshot.resolvedBindings === "object" &&
      snapshot.resolvedBindings !== null &&
      !Array.isArray(snapshot.resolvedBindings)
        ? snapshot.resolvedBindings
        : {};
    const threadInstructions =
      typeof snapshot.threadInstructions === "string"
        ? snapshot.threadInstructions
        : "";
    return {
      ...callerInput,
      ...persistedInput,
      originalRequest:
        typeof snapshot.originalRequest === "string"
          ? snapshot.originalRequest
          : "",
      spaceInstructions:
        typeof snapshot.spaceInstructions === "string"
          ? snapshot.spaceInstructions
          : "",
      threadInstructions,
      stepInstructions:
        typeof snapshot.stepAdditionalInstructions === "object" &&
        snapshot.stepAdditionalInstructions !== null
          ? snapshot.stepAdditionalInstructions
          : {},
      workConfig: { bindings: resolvedBindings, threadInstructions },
      workRequestSnapshot: snapshot,
    };
  }

  private async loadWorkRequestSnapshot(
    workRequestId: string,
  ): Promise<WorkRequestSnapshot | null> {
    const db = (this.env as ExecutionEnv).SYNTILA_DB;
    if (!db) return null;
    const row = await db
      .prepare(
        `SELECT snapshot_json AS snapshotJson,
                workflow_snapshot_json AS workflowSnapshotJson
         FROM work_requests WHERE id = ?1`,
      )
      .bind(workRequestId)
      .first<{ snapshotJson: string | null; workflowSnapshotJson: string }>();
    if (!row?.snapshotJson) return null;
    try {
      const snapshot = JSON.parse(row.snapshotJson) as WorkRequestSnapshot;
      const workflowSnapshot = JSON.parse(
        row.workflowSnapshotJson,
      ) as BuiltinWorkflowDefinition;
      if (snapshot.schemaVersion !== 1) return null;
      validateBuiltinWorkflowDefinition(workflowSnapshot);
      if (
        snapshot.workflowId !== workflowSnapshot.id ||
        snapshot.workflowVersion !== workflowSnapshot.version
      ) {
        return null;
      }
      return { ...snapshot, workflowSnapshot };
    } catch {
      return null;
    }
  }

  override async run(
    event: WorkflowEvent<SyntilaWorkflowParams>,
    step: WorkflowStep,
  ): Promise<SyntilaWorkflowCheckpoint> {
    let params = event.payload;
    if (params.workRequestId) {
      const snapshot = await this.loadWorkRequestSnapshot(params.workRequestId);
      if (snapshot)
        params = { ...params, builtinWorkflow: snapshot.workflowSnapshot };
    }
    if (!params.builtinWorkflow) {
      throw new Error("A versioned built-in Work v1 Workflow is required");
    }
    return this.runVersioned(params, step);
  }
}
