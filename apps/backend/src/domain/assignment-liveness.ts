import { beginAssignmentRevocation } from "./assignment-revocation.js";
import { extendLeaseForLiveAssignment } from "./thread-coordinator.js";

/**
 * Process liveness reported by the Workspace Service on every heartbeat.
 *
 * `liveAssignmentIds` are assignments whose Engine process the Service can
 * still see. `pendingTerminalAssignmentIds` are assignments that already have
 * an outcome in the Service journal that Cloud has not acknowledged yet; they
 * are not lost, the outcome is simply still on its way.
 */
export interface EngineLivenessReport {
  readonly liveAssignmentIds: ReadonlySet<string>;
  readonly pendingTerminalAssignmentIds: ReadonlySet<string>;
}

/** Consecutive reports that must omit an assignment before it is lost. */
export const ENGINE_MISSING_REPORT_LIMIT = 2;

const MAX_REPORTED_IDS = 500;
const MAX_ID_LENGTH = 128;

function idSet(value: unknown): Set<string> {
  const ids = new Set<string>();
  if (!Array.isArray(value)) return ids;
  for (const entry of value.slice(0, MAX_REPORTED_IDS)) {
    if (
      typeof entry === "string" &&
      entry.length > 0 &&
      entry.length <= MAX_ID_LENGTH
    ) {
      ids.add(entry);
    }
  }
  return ids;
}

/**
 * Reads the liveness fields of a heartbeat payload. Returns null when the
 * Service does not report liveness (an older Service), so Cloud never treats
 * silence from such a Service as proof that processes are gone.
 */
export function parseEngineLivenessReport(
  payload: unknown,
): EngineLivenessReport | null {
  if (!payload || typeof payload !== "object") return null;
  const record = payload as Record<string, unknown>;
  if (!Array.isArray(record.liveAssignmentIds)) return null;
  return {
    liveAssignmentIds: idSet(record.liveAssignmentIds),
    pendingTerminalAssignmentIds: idSet(record.pendingTerminalAssignmentIds),
  };
}

export interface LostEngineAssignment {
  readonly assignmentId: string;
  readonly attemptId: string | null;
}

/**
 * Applies one report to the workspace's running assignments and returns the
 * assignments whose Engine has been missing for too many consecutive reports.
 */
export async function applyEngineLivenessReport(
  db: D1Database,
  workspaceId: string,
  report: EngineLivenessReport,
  now: string,
): Promise<LostEngineAssignment[]> {
  const { results } = await db
    .prepare(
      `SELECT id, attempt_id, engine_missing_reports
         FROM worker_assignments
        WHERE execution_workspace_id = ?1 AND status = 'running'
        LIMIT 200`,
    )
    .bind(workspaceId)
    .all<{
      id: string;
      attempt_id: string | null;
      engine_missing_reports: number | null;
    }>();
  const lost: LostEngineAssignment[] = [];
  for (const row of results ?? []) {
    const present =
      report.liveAssignmentIds.has(row.id) ||
      report.pendingTerminalAssignmentIds.has(row.id);
    if (present) {
      await db
        .prepare(
          `UPDATE worker_assignments
              SET engine_alive_at = ?2, engine_missing_reports = 0
            WHERE id = ?1 AND status = 'running'`,
        )
        .bind(row.id, now)
        .run();
      // A live Worker keeps its Thread lease alive, so the lease does not
      // depend only on the Workflow waking up to renew it.
      const nowMs = Date.parse(now);
      await extendLeaseForLiveAssignment(
        db,
        row.id,
        Number.isFinite(nowMs) ? nowMs : Date.now(),
      ).run();
      continue;
    }
    const missing = (row.engine_missing_reports ?? 0) + 1;
    await db
      .prepare(
        `UPDATE worker_assignments SET engine_missing_reports = ?2
          WHERE id = ?1 AND status = 'running'`,
      )
      .bind(row.id, missing)
      .run();
    if (missing >= ENGINE_MISSING_REPORT_LIMIT) {
      lost.push({ assignmentId: row.id, attemptId: row.attempt_id });
    }
  }
  return lost;
}

/** Starts a safe revocation (failure) for assignments whose Engine is gone. */
export async function failLostEngineAssignments(
  db: D1Database,
  lost: readonly LostEngineAssignment[],
  now: string,
): Promise<number> {
  const message = "The worker process ended unexpectedly.";
  let started = 0;
  for (const item of lost) {
    const result = await beginAssignmentRevocation(db, {
      assignmentId: item.assignmentId,
      ...(item.attemptId ? { attemptId: item.attemptId } : {}),
      onlyFrom: ["running"],
      now,
      intent: {
        status: "failed",
        reason: message,
        source: "worker_process_lost",
        failure: {
          error: {
            code: "provider_unavailable",
            message,
            retryable: true,
            details: {
              diagnostic: JSON.stringify({
                schemaVersion: 1,
                component: "cloud",
                stage: "worker_process_lost",
                errorCode: "provider_unavailable",
                providerStarted: true,
                detail:
                  "The Workspace Service stopped reporting the Engine process for this assignment and no outcome was recorded.",
              }),
            },
          },
          failedAt: now,
        },
      },
    });
    if (result.outcome === "finalized" || result.outcome === "pending") {
      started += 1;
    }
  }
  return started;
}
