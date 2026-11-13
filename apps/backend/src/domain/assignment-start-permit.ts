import {
  isRevocationAssignmentStatus,
  isTerminalAssignmentStatus,
  type AssignmentLifecycleStatus,
} from "@syntila/core";
import {
  transitionAssignment,
  type AssignmentFence,
} from "./assignment-transitions.js";

/**
 * Start fencing. A Service that advertises `assignment.start_permit.v1`
 * requests a permit immediately before it launches the provider process and
 * does not launch without a grant. Cloud grants a permit only while the
 * assignment is Acknowledged. Because revocation moves the assignment out of
 * Acknowledged with a conditional UPDATE, and a grant is a conditional UPDATE
 * that requires Acknowledged, exactly one of them wins:
 *
 * - grant first: `start_permit_issued_at` is set, a process may start, and a
 *   later revocation must wait for the Service to confirm the stop;
 * - revocation first: no later request can be granted, so if no permit was
 *   ever issued, no process exists or can ever exist and Cloud may finalize
 *   the revocation without waiting for the Service.
 */

/** How long a granted permit stays valid for the Service to use it. */
export const START_PERMIT_TTL_MS = 30_000;

export type StartPermitDenial =
  /** Cloud revoked the assignment; the Service must not start. */
  | "revoked"
  /** The assignment already reached a terminal state. */
  | "terminal"
  /** The assignment is already Running; a permit was used before. */
  | "already_started"
  /** The request does not match the assignment's identity. */
  | "stale"
  | "not_found";

export type StartPermitDecision =
  | {
      readonly granted: true;
      readonly permitId: string;
      readonly expiresAt: string;
    }
  | { readonly granted: false; readonly reason: StartPermitDenial };

export function startPermitId(
  assignmentId: string,
  attemptId: string,
  issuedAtMs: number,
): string {
  return `permit:${assignmentId}:${attemptId}:${issuedAtMs}`;
}

/**
 * Decides a permit request. Admission evidence is implied by the request (a
 * Service asking to start has accepted the assignment), so a permit request
 * that overtakes `assignment.ack` still advances `dispatched` to
 * `acknowledged`. Repeating a request after a lost grant is safe: it is
 * granted again while the assignment is still Acknowledged.
 */
export async function grantStartPermit(
  db: D1Database,
  fence: AssignmentFence & { attemptId: string },
  now = new Date(),
): Promise<StartPermitDecision> {
  const admitted = await transitionAssignment(db, {
    fence,
    to: "acknowledged",
    now: now.toISOString(),
  });
  if (admitted.outcome === "stale") return { granted: false, reason: "stale" };
  if (admitted.outcome === "not_found") {
    return { granted: false, reason: "not_found" };
  }
  if (admitted.outcome === "terminal") {
    return { granted: false, reason: "terminal" };
  }
  if (admitted.outcome === "superseded") {
    return {
      granted: false,
      reason: denialFor(admitted.currentStatus),
    };
  }

  // The grant itself: it must observe Acknowledged at the instant it writes.
  const issuedAt = now.toISOString();
  const row = await db
    .prepare(
      `UPDATE worker_assignments SET start_permit_issued_at = COALESCE(start_permit_issued_at, ?1)
        WHERE id = ?2 AND attempt_id = ?3 AND status = 'acknowledged'
          AND (?4::text IS NULL OR execution_workspace_id = ?4)
          AND (?5::text IS NULL OR runtime_identity_id = ?5)
          AND (workspace_space_grant_id IS NULL OR EXISTS (
            SELECT 1 FROM workspace_space_grants g
             WHERE g.id = worker_assignments.workspace_space_grant_id
               AND g.status = 'active'
               AND (g.expires_at IS NULL OR g.expires_at > ?1)))
        RETURNING id, start_permit_issued_at`,
    )
    .bind(
      issuedAt,
      fence.assignmentId,
      fence.attemptId,
      fence.executionWorkspaceId ?? null,
      fence.runtimeIdentityId ?? null,
    )
    .first<{ id: string; start_permit_issued_at: string }>();
  if (row?.id === fence.assignmentId) {
    const issuedAtMs = Date.parse(row.start_permit_issued_at);
    return {
      granted: true,
      permitId: startPermitId(fence.assignmentId, fence.attemptId, issuedAtMs),
      expiresAt: new Date(issuedAtMs + START_PERMIT_TTL_MS).toISOString(),
    };
  }
  // Lost the race: re-read to report why.
  const current = await db
    .prepare("SELECT status FROM worker_assignments WHERE id = ?1")
    .bind(fence.assignmentId)
    .first<{ status: string }>();
  return { granted: false, reason: denialFor(current?.status) };
}

function denialFor(status: string | undefined): StartPermitDenial {
  if (!status) return "not_found";
  if (status === "running") return "already_started";
  if (isRevocationAssignmentStatus(status as AssignmentLifecycleStatus)) {
    return "revoked";
  }
  if (isTerminalAssignmentStatus(status as AssignmentLifecycleStatus)) {
    return "terminal";
  }
  return "revoked";
}
