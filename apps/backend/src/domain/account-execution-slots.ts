import { accountPlanRow } from "./queries.js";
import {
  EXECUTION_WAITER_STALE_MS,
  effectiveTier,
  executionSlotAdmissionSql,
} from "./account-plan.js";
import { ACTIVE_ASSIGNMENT_STATUS_SQL } from "./assignment-transitions.js";
import { dataOf, type Query } from "../platform/data.js";

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
  db: D1Database,
  userId: string,
  now: Date = new Date(),
): Promise<boolean> {
  const row = await accountPlanRow(db, userId);
  return effectiveTier(row, now) === "paid";
}

/** Live (non-terminal) assignments the requester currently holds. */
export async function countHeldExecutionSlots(
  db: D1Database,
  userId: string,
): Promise<number> {
  const read = dataOf({ SYNTILA_DB: db }).read;
  const row = await read.row<{ count: number }>`
    SELECT COUNT(*) AS count FROM worker_assignments
     WHERE requested_by_user_id = ${userId}
       AND status IN (${read.raw(ACTIVE_ASSIGNMENT_STATUS_SQL)})`;
  return row?.count ?? 0;
}

/** True when the slot admission rule would currently refuse this task. */
export async function executionSlotRefused(
  q: Query,
  userId: string,
  taskId: string,
  now: Date = new Date(),
): Promise<boolean> {
  const row = await q.row<{ refused: number }>`
    WITH args AS (
      SELECT ${userId}::text AS user_id, ${taskId}::text AS task_id, ${waiterCutoff(now)}::text AS cutoff
    )
    SELECT CASE WHEN ${q.raw(executionSlotAdmissionSql("args.user_id", "args.task_id", "args.cutoff"))}
                THEN 0 ELSE 1 END AS refused
    FROM args`;
  return row?.refused === 1;
}

/**
 * Records (or heartbeats) that the task is eligible but waiting. The first
 * `enqueued_at` is kept so request order survives retries and restarts.
 */
export async function recordExecutionWaiter(
  db: D1Database,
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
  await dataOf(env).read.run`INSERT INTO account_execution_waiters
         (task_id, requester_user_id, run_id, work_request_id, reason,
          enqueued_at, heartbeat_at)
       VALUES (${input.taskId}, ${input.requesterUserId}, ${input.runId}, ${input.workRequestId ?? null}, ${input.reason}, ${stamp}, ${stamp})
       ON CONFLICT(task_id) DO UPDATE SET
         reason = excluded.reason, heartbeat_at = excluded.heartbeat_at`;
}

export async function clearExecutionWaiter(
  db: D1Database,
  taskId: string,
): Promise<void> {
  await dataOf(env).read.run`DELETE FROM account_execution_waiters WHERE task_id = ${taskId}`;
}

/** Drops waiters whose Workflow stopped heartbeating. Never touches capacity. */
export async function sweepStaleExecutionWaiters(
  db: D1Database,
  now: Date = new Date(),
): Promise<void> {
  await dataOf(env).read.run`DELETE FROM account_execution_waiters WHERE heartbeat_at < ${new Date(now.getTime() - 10 * EXECUTION_WAITER_STALE_MS).toISOString()}`;
}

/** The waiter's current reason, for read models. */
export async function executionWaitReason(
  db: D1Database,
  taskId: string,
): Promise<ExecutionWaitReason | null> {
  const row = await dataOf(env).read.row<{ reason: ExecutionWaitReason }>`SELECT reason FROM account_execution_waiters WHERE task_id = ${taskId}`;
  return row?.reason ?? null;
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
  env: { SYNTILA_DB: D1Database; SYNTILA_RUN_WORKFLOW?: WakeableWorkflow },
  requesterUserId: string,
  eventType: string,
  now: Date = new Date(),
): Promise<boolean> {
  if (!env.SYNTILA_RUN_WORKFLOW) return false;
  try {
    const waiter = await dataOf(env).read.row<{ taskId: string; instanceId: string | null }>`SELECT w.task_id AS "taskId", r.workflow_instance_id AS "instanceId"
         FROM account_execution_waiters w
         LEFT JOIN runs r ON r.id = w.run_id
        WHERE w.requester_user_id = ${requesterUserId} AND w.reason = 'account_concurrency_limit'
          AND w.heartbeat_at >= ${waiterCutoff(now)}
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
