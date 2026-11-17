import {
  ASSIGNMENT_STARTUP_STAGE_RANK,
  type AssignmentStartupPayload,
  type AssignmentStartupStage,
} from "@syntila/workspace-runtime-protocol";

/** Statuses in which the Service may still be starting the assignment. */
const PRE_START_STATUSES = ["dispatched", "acknowledged"] as const;

export type AssignmentStartupOutcome =
  | { applied: true }
  | { applied: false; reason: "not_found" | "not_pre_start" | "stale" };

function rank(stage: string | null): number {
  if (!stage) return 0;
  return ASSIGNMENT_STARTUP_STAGE_RANK[stage as AssignmentStartupStage] ?? 0;
}

/**
 * A startup report is applied only when it does not move backwards. Equal
 * rank is accepted so a queue position can update while waiting.
 */
export function startupReportAdvances(
  current: string | null,
  next: AssignmentStartupStage,
): boolean {
  return ASSIGNMENT_STARTUP_STAGE_RANK[next] >= rank(current);
}

/** The bounded, non-secret detail persisted next to the stage. */
export function startupDetail(payload: AssignmentStartupPayload): string {
  const { stage: _stage, at: _at, ...detail } = payload;
  return JSON.stringify(detail);
}

/**
 * Records the furthest startup stage reported for an assignment. The write is
 * a compare-and-set on the previous stage, so concurrent or replayed reports
 * cannot move the stage backwards, and it only touches rows that have not
 * started: provider start and terminal states are owned by other evidence.
 */
export async function recordAssignmentStartup(
  db: D1Database,
  input: {
    assignmentId: string;
    attemptId: string;
    payload: AssignmentStartupPayload;
    now: string;
  },
): Promise<AssignmentStartupOutcome> {
  const row = await db
    .prepare(
      `SELECT status, startup_stage FROM worker_assignments
        WHERE id = ?1 AND attempt_id = ?2`,
    )
    .bind(input.assignmentId, input.attemptId)
    .first<{ status: string; startup_stage: string | null }>();
  if (!row) return { applied: false, reason: "not_found" };
  if (!(PRE_START_STATUSES as readonly string[]).includes(row.status)) {
    return { applied: false, reason: "not_pre_start" };
  }
  if (!startupReportAdvances(row.startup_stage, input.payload.stage)) {
    return { applied: false, reason: "stale" };
  }
  const updated = await db
    .prepare(
      `UPDATE worker_assignments
          SET startup_stage = ?1, startup_stage_at = ?2, startup_detail_json = ?3
        WHERE id = ?4 AND attempt_id = ?5
          AND status IN ('dispatched', 'acknowledged')
          AND COALESCE(startup_stage, '') = COALESCE(?6, '')
        RETURNING id`,
    )
    .bind(
      input.payload.stage,
      input.payload.at ?? input.now,
      startupDetail(input.payload),
      input.assignmentId,
      input.attemptId,
      row.startup_stage,
    )
    .first<{ id: string }>();
  return updated ? { applied: true } : { applied: false, reason: "stale" };
}
