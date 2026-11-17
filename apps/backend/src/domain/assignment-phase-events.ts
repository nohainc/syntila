import { createEventPublisher } from "./event-publisher.js";
import { presentExecution } from "./execution-phase.js";
import { canonicalExecutionErrorCode } from "@syntila/protocol";

interface PhaseEnv {
  readonly SYNTILA_DB: D1Database;
}

/**
 * Tells connected Work tabs that a step's execution phase changed.
 *
 * The event is a notification, not the source of truth: it carries the phase
 * Cloud just derived, but a client always re-reads the Work Request on
 * receipt. The idempotency key is per assignment and phase, so replays and
 * duplicate gateway messages publish at most one event per phase.
 *
 * Best effort by design. Phase notification must never fail or delay the
 * assignment transition that triggered it; a missed event is repaired by the
 * client's reconnect refresh.
 */
export async function publishAssignmentPhase(
  env: PhaseEnv,
  assignmentId: string,
): Promise<void> {
  try {
    const row = await env.SYNTILA_DB.prepare(
      `SELECT wa.status AS assignmentStatus, wa.dispatched_at AS dispatchedAt,
              wa.acknowledged_at AS acknowledgedAt,
              wa.start_permit_issued_at AS startPermitIssuedAt,
              wa.start_permit_required AS startPermitRequired,
              wa.running_at AS runningAt, wa.startup_stage AS startupStage,
              wa.cloud_queue_reason AS cloudQueueReason,
              wa.error_json AS errorJson, wa.run_id AS runId,
              wt.status AS taskStatus, wt.step_kind AS stepKind, wt.step_id AS stepId,
              wt.work_request_id AS workRequestId, wt.error AS taskError,
              wr.thread_id AS threadId, wr.primary_workspace_id AS workspaceId,
              th.space_id AS spaceId
         FROM worker_assignments wa
         JOIN workflow_tasks wt ON wt.id = wa.task_id
         JOIN work_requests wr ON wr.id = wt.work_request_id
         JOIN threads th ON th.id = wr.thread_id
        WHERE wa.id = ?1`,
    )
      .bind(assignmentId)
      .first<Record<string, unknown>>();
    if (!row?.workRequestId || !row.threadId || !row.workspaceId) return;
    let errorCode: string | null = null;
    if (typeof row.taskError === "string") {
      errorCode = canonicalExecutionErrorCode(row.taskError);
    }
    const text = (value: unknown) => (typeof value === "string" ? value : null);
    const presentation = presentExecution({
      assignmentStatus: text(row.assignmentStatus),
      taskStatus: text(row.taskStatus),
      dispatchedAt: text(row.dispatchedAt),
      acknowledgedAt: text(row.acknowledgedAt),
      startPermitIssuedAt: text(row.startPermitIssuedAt),
      startPermitRequired: Number(row.startPermitRequired ?? 0) === 1,
      runningAt: text(row.runningAt),
      startupStage: text(row.startupStage),
      cloudQueueReason: text(row.cloudQueueReason),
      errorJson: text(row.errorJson),
      errorCode,
    });
    await createEventPublisher(env as never).publish({
      type: "step.phase",
      workspaceId: String(row.workspaceId),
      spaceId: String(row.spaceId),
      ...(row.runId ? { runId: String(row.runId) } : {}),
      idempotencyKey: `step-phase:${assignmentId}:${presentation.executionPhase}`,
      assignmentId,
      // `status` carries the phase; the payload schema is strict, and the
      // client re-reads the Work Request for failureCategory and retry.
      payload: {
        entityId: String(row.stepId ?? row.stepKind),
        workRequestId: String(row.workRequestId),
        threadId: String(row.threadId),
        stepKind: String(row.stepKind),
        status: presentation.executionPhase,
      },
    });
  } catch (error) {
    console.error("Failed to publish step.phase", error);
  }
}
