import {
  ASSIGNMENT_ACTIVE_STATUSES,
  ASSIGNMENT_LIFECYCLE_STATUSES,
  assignmentSourceStatuses,
  isTerminalAssignmentStatus,
  type AssignmentLifecycleStatus,
} from "@syntila/core";

/**
 * Cloud's only writer of `worker_assignments.status` for message-driven
 * transitions. Every change is one conditional UPDATE whose WHERE clause
 * carries both the canonical source-status set (from `@syntila/core`) and the
 * identity fence, so concurrent handlers, replays and stale messages cannot
 * move a row backwards or out of its attempt. The database, not an earlier
 * SELECT, decides which handler wins.
 */

/** SQL `IN (...)` list of the statuses a transition to [target] may start from. */
export function assignmentSourceStatusList(
  target: AssignmentLifecycleStatus,
): string {
  return assignmentSourceStatuses(target)
    .map((status) => `'${status}'`)
    .join(", ");
}

/**
 * SQL `IN (...)` list of every non-terminal status. Capacity, sync and
 * recovery queries use this so a revoked-but-unconfirmed assignment keeps
 * holding its slot until the Service proves the process is gone.
 */
export const ACTIVE_ASSIGNMENT_STATUS_SQL = ASSIGNMENT_ACTIVE_STATUSES.map(
  (status) => `'${status}'`,
).join(", ");

export interface AssignmentFence {
  assignmentId: string;
  /** Rejects messages from a previous attempt of the same task. */
  attemptId?: string;
  /** Rejects messages from another Workspace. */
  executionWorkspaceId?: string;
  /** Rejects messages from a previous or revoked runtime identity. */
  runtimeIdentityId?: string;
}

export interface AssignmentTransitionInput {
  fence: AssignmentFence;
  to: AssignmentLifecycleStatus;
  /**
   * Narrows the canonical source set further. Used where a message is only
   * meaningful before a milestone, e.g. an admission rejection must not fail
   * an assignment that was already accepted.
   */
  onlyFrom?: readonly AssignmentLifecycleStatus[];
  now?: string;
  /**
   * Replaces `error_json` in the same statement. Used by revocation to store
   * the intended terminal outcome with the transition that makes it pending.
   */
  errorJson?: string;
  /**
   * Moves the Workflow task to `running` once the assignment is Running. The
   * projection is skipped for stale, superseded and terminal outcomes.
   */
  startTaskId?: string;
}

export type AssignmentTransitionOutcome =
  /** This call performed the transition. */
  | "applied"
  /** The assignment already had the target status (replay or lost race). */
  | "duplicate"
  /** A later, non-terminal status already holds; late evidence is ignored. */
  | "superseded"
  /** The assignment is terminal and immutable. */
  | "terminal"
  /** The row exists but belongs to another attempt, runtime or Workspace. */
  | "stale"
  | "not_found";

export interface AssignmentTransitionResult {
  outcome: AssignmentTransitionOutcome;
  applied: boolean;
  /** Status observed after a non-applied outcome. */
  currentStatus?: string;
}

const KNOWN = new Set<string>(ASSIGNMENT_LIFECYCLE_STATUSES);

/**
 * SQL fragment recording the event that starts the next deadline. First write
 * wins (`COALESCE`), so a replayed message can never push a deadline back.
 * `?2` is the transition time.
 */
export function assignmentMilestoneSql(
  target: AssignmentLifecycleStatus,
): string {
  switch (target) {
    case "dispatched":
      return ", dispatched_at = COALESCE(dispatched_at, ?2)";
    case "acknowledged":
      return ", acknowledged_at = COALESCE(acknowledged_at, ?2)";
    case "running":
      // A start ack that overtakes the admission ack still admits the work.
      return ", acknowledged_at = COALESCE(acknowledged_at, ?2), running_at = COALESCE(running_at, ?2)";
    default:
      return "";
  }
}

export async function transitionAssignment(
  db: D1Database,
  input: AssignmentTransitionInput,
): Promise<AssignmentTransitionResult> {
  const { fence, to } = input;
  const now = input.now ?? new Date().toISOString();
  const sources = assignmentSourceStatuses(to).filter(
    (status) => !input.onlyFrom || input.onlyFrom.includes(status),
  );
  if (sources.length === 0) {
    return classify(db, input);
  }

  const values: unknown[] = [to, now, fence.assignmentId];
  if (input.errorJson !== undefined) values.push(input.errorJson);
  const errorSql = input.errorJson !== undefined ? ", error_json = ?4" : "";
  const milestoneSql = assignmentMilestoneSql(to);
  let fenceSql = "";
  const fenced: Array<[string, string | undefined]> = [
    ["attempt_id", fence.attemptId],
    ["execution_workspace_id", fence.executionWorkspaceId],
    ["runtime_identity_id", fence.runtimeIdentityId],
  ];
  for (const [column, value] of fenced) {
    if (value === undefined) continue;
    values.push(value);
    fenceSql += ` AND ${column} = ?${values.length}`;
  }
  const sourceSql = sources.map((status) => `'${status}'`).join(", ");
  // D1 `meta.changes` also counts writes made by triggers, so the only
  // reliable signal that this statement changed the row is RETURNING.
  const returned = await db
    .prepare(
      `UPDATE worker_assignments SET status = ?1, updated_at = ?2${errorSql}${milestoneSql}
        WHERE id = ?3 AND status IN (${sourceSql})${fenceSql}
        RETURNING id`,
    )
    .bind(...values)
    .first<{ id: string }>();
  const result: AssignmentTransitionResult =
    returned?.id === fence.assignmentId
      ? { outcome: "applied", applied: true }
      : await classify(db, input);
  if (
    input.startTaskId &&
    to === "running" &&
    (result.outcome === "applied" || result.outcome === "duplicate")
  ) {
    // Idempotent and gated on the assignment actually being Running, so a
    // replay repairs a projection that a crash left behind but a terminal
    // or superseded assignment can never start its task.
    await db
      .prepare(
        `UPDATE workflow_tasks SET status = 'running',
                started_at = COALESCE(started_at, ?1), updated_at = ?1
           WHERE id = ?2 AND status IN ('queued', 'waiting')
             AND EXISTS (SELECT 1 FROM worker_assignments
                          WHERE id = ?3 AND status = 'running')`,
      )
      .bind(now, input.startTaskId, fence.assignmentId)
      .run();
  }
  return result;
}

async function classify(
  db: D1Database,
  input: AssignmentTransitionInput,
): Promise<AssignmentTransitionResult> {
  const applied = false;
  const { fence, to } = input;
  const row = await db
    .prepare(
      `SELECT status, attempt_id, execution_workspace_id, runtime_identity_id
         FROM worker_assignments WHERE id = ?1`,
    )
    .bind(fence.assignmentId)
    .first<{
      status: string;
      attempt_id: string | null;
      execution_workspace_id: string;
      runtime_identity_id: string;
    }>();
  if (!row) return { outcome: "not_found", applied };
  const currentStatus = row.status;
  if (
    (fence.attemptId !== undefined && fence.attemptId !== row.attempt_id) ||
    (fence.executionWorkspaceId !== undefined &&
      fence.executionWorkspaceId !== row.execution_workspace_id) ||
    (fence.runtimeIdentityId !== undefined &&
      fence.runtimeIdentityId !== row.runtime_identity_id)
  ) {
    return { outcome: "stale", applied, currentStatus };
  }
  if (currentStatus === to) {
    return { outcome: "duplicate", applied, currentStatus };
  }
  if (KNOWN.has(currentStatus)) {
    return {
      outcome: isTerminalAssignmentStatus(
        currentStatus as AssignmentLifecycleStatus,
      )
        ? "terminal"
        : "superseded",
      applied,
      currentStatus,
    };
  }
  return { outcome: "superseded", applied, currentStatus };
}
