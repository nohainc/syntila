import { accountPlanRow } from "./queries.js";
import type { AccountPlanRow } from "./account-plan.js";
import {
  EXECUTION_WAITER_STALE_MS,
  effectiveTier,
  executionSlotAdmission,
} from "./account-plan.js";
import { dataOf, type Db } from "../platform/data.js";
import type { Query } from "../platform/data.js";
import { ACTIVE_ASSIGNMENT_STATUS_SQL } from "./assignment-transitions.js";
import { tryLogDiagnosticEvent } from "./observability.js";

/**
 * Why a task is waiting before it has an assignment. Neither reason holds a
 * slot; both are shown to the requester as "queued".
 */
export type ExecutionWaitReason =
  "account_concurrency_limit" | "workspace_not_ready";

export const EXECUTION_WAIT_MESSAGES: Readonly<
  Record<ExecutionWaitReason, string>
> = {
  account_concurrency_limit:
    "Free runs one AI task at a time. This request will start when your current task finishes.",
  workspace_not_ready: "Waiting for the Workspace Service to be ready",
};

export function waiterCutoff(now: Date = new Date()): string {
  return new Date(now.getTime() - EXECUTION_WAITER_STALE_MS).toISOString();
}

/** Whether the requester is on Plus right now (expiry and grace included). */
export async function isPaidRequester(
  q: Query,
  userId: string,
  now: Date = new Date(),
): Promise<boolean> {
  const row = await accountPlanRow<AccountPlanRow>(q, userId);
  return effectiveTier(row, now) === "paid";
}

/** Live (non-terminal) assignments the requester currently holds. */
export async function countHeldExecutionSlots(
  q: Query,
  userId: string,
): Promise<number> {
  const row = await q.row<{ count: number }>`
    SELECT COUNT(*) AS count FROM worker_assignments
     WHERE requested_by_user_id = ${userId}
       AND status IN (${q.raw(ACTIVE_ASSIGNMENT_STATUS_SQL)})`;
  return row?.count ?? 0;
}

/** True when the slot admission rule would currently refuse this task. */
export async function executionSlotRefused(
  q: Query,
  userId: string,
  taskId: string,
  now: Date = new Date(),
): Promise<boolean> {
  const row = await q.row<{ refused: boolean }>`
    SELECT NOT ${executionSlotAdmission(q, userId, taskId, waiterCutoff(now))} AS refused`;
  return row?.refused === true;
}

/**
 * Records (or heartbeats) that the task is eligible but waiting. The first
 * `enqueued_at` is kept so request order survives retries and restarts.
 */
export async function recordExecutionWaiter(
  q: Query,
  input: {
    taskId: string;
    requesterUserId: string;
    runId: string;
    workRequestId?: string;
    reason: ExecutionWaitReason;
  },
  now: Date = new Date(),
): Promise<void> {
  const stamp = now.toISOString();
  await q.run`
    INSERT INTO account_execution_waiters
      (task_id, requester_user_id, run_id, work_request_id, reason,
       enqueued_at, heartbeat_at)
    VALUES (${input.taskId}, ${input.requesterUserId}, ${input.runId}, ${input.workRequestId ?? null},
            ${input.reason}, ${stamp}::timestamptz, ${stamp}::timestamptz)
    ON CONFLICT(task_id) DO UPDATE SET
      reason = excluded.reason, heartbeat_at = excluded.heartbeat_at`;
}

export async function clearExecutionWaiter(
  q: Query,
  taskId: string,
): Promise<void> {
  await q.run`DELETE FROM account_execution_waiters WHERE task_id = ${taskId}`;
}

/** Drops waiters whose Workflow stopped heartbeating. Never touches capacity. */
export async function sweepStaleExecutionWaiters(
  q: Query,
  now: Date = new Date(),
): Promise<void> {
  const cutoff = new Date(now.getTime() - 10 * EXECUTION_WAITER_STALE_MS).toISOString();
  await q.run`DELETE FROM account_execution_waiters WHERE heartbeat_at < ${cutoff}::timestamptz`;
}

interface WakeableWorkflow {
  get(id: string): Promise<{
    sendEvent(event: { type: string; payload?: unknown }): Promise<void>;
  }>;
}

/**
 * Wakes the oldest eligible waiter of the requester after one of their
 * assignments reached a terminal status, so queued work starts without
 * waiting for its poll. Best effort: the waiter's own timed re-dispatch is the
 * durable path, and admission is decided by the INSERT, never by this nudge.
 */
export async function wakeNextExecutionWaiter(
  env: { SYNTILA_DB: Db; SYNTILA_RUN_WORKFLOW?: WakeableWorkflow },
  requesterUserId: string,
  eventType: string,
  now: Date = new Date(),
): Promise<boolean> {
  if (!env.SYNTILA_RUN_WORKFLOW) return false;
  try {
    const waiter = await dataOf(env).read.row<{ taskId: string; instanceId: string | null }>`
      SELECT w.task_id AS "taskId", r.workflow_instance_id AS "instanceId"
        FROM account_execution_waiters w
        LEFT JOIN runs r ON r.id = w.run_id
       WHERE w.requester_user_id = ${requesterUserId} AND w.reason = 'account_concurrency_limit'
         AND w.heartbeat_at >= ${waiterCutoff(now)}::timestamptz
       ORDER BY w.enqueued_at, w.task_id LIMIT 1`;
    if (!waiter?.instanceId) return false;
    const instance = await env.SYNTILA_RUN_WORKFLOW.get(waiter.instanceId);
    await instance.sendEvent({
      type: eventType,
      payload: { taskId: waiter.taskId, reason: "execution_slot_released" },
    });
    return true;
  } catch {
    return false;
  }
}

/** Wake waiters for this Workspace in bounded pages. Unbound requests are
 * also re-evaluated because their eventual Workspace is not yet known.
 * Failure is best effort: each waiter retains its durable timed retry. */
export async function wakeWorkspaceReadyWaiters(
  env: { SYNTILA_DB: Db; SYNTILA_RUN_WORKFLOW?: WakeableWorkflow },
  workspaceId: string,
  eventType: string,
  now: Date = new Date(),
): Promise<number> {
  if (!env.SYNTILA_RUN_WORKFLOW) return 0;
  let cursor = "";
  let woken = 0;
  try {
    while (true) {
      const waiters = await dataOf(env).read.rows<{ taskId: string; instanceId: string | null; requestId: string | null }>`
        SELECT w.task_id AS "taskId", r.workflow_instance_id AS "instanceId", w.work_request_id AS "requestId"
          FROM account_execution_waiters w
          LEFT JOIN runs r ON r.id = w.run_id
          LEFT JOIN work_requests wr ON wr.id = w.work_request_id
         WHERE w.reason = 'workspace_not_ready'
           AND w.heartbeat_at >= ${waiterCutoff(now)}::timestamptz
           AND w.task_id > ${cursor}
         ORDER BY w.task_id LIMIT 20`;
      if (!waiters.length) break;
      await Promise.all(waiters.map(async (waiter) => {
        if (!waiter.instanceId) return;
        try {
          const instance = await env.SYNTILA_RUN_WORKFLOW!.get(waiter.instanceId);
          await instance.sendEvent({ type: eventType, payload: { taskId: waiter.taskId, reason: "workspace_ready" } });
          woken++;
          tryLogDiagnosticEvent({ component: "cloud", operation: "assignment", stage: "admission", severity: "info", retryable: false,
            requestId: waiter.requestId ?? undefined, workspaceId, taskId: waiter.taskId, context: { status: "readiness_wake_sent" } });
        } catch {
          tryLogDiagnosticEvent({ component: "cloud", operation: "assignment", stage: "admission", severity: "warning", retryable: true,
            requestId: waiter.requestId ?? undefined, workspaceId, taskId: waiter.taskId, context: { status: "readiness_wake_failed" } });
        }
      }));
      cursor = waiters[waiters.length - 1]!.taskId;
      if (waiters.length < 20) break;
    }
  } catch {
    // Durable timed retries remain authoritative.
  }
  return woken;
}
