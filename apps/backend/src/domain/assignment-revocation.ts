import {
  isRevocationAssignmentStatus,
  isTerminalAssignmentStatus,
  type AssignmentLifecycleStatus,
} from "@syntila/core";
import type {
  AssignmentCancelPayload,
  AssignmentFailurePayload,
} from "@syntila/workspace-runtime-protocol";
import {
  recordAssignmentCancelled,
  recordAssignmentError,
} from "./assignment-dispatcher.js";
import { transitionAssignment } from "./assignment-transitions.js";

/**
 * Safe revocation of an assignment that must not run (or must stop running).
 *
 * A deadline, a cancellation or a lost Workspace entitles Cloud to *want* the
 * work stopped. It does not entitle Cloud to *claim* it stopped: the command
 * may already sit in the Service queue or the provider may be running. So the
 * lifecycle is
 *
 *   dispatched/acknowledged/running --> revocation_pending --> terminal
 *                                              |                  ^
 *                                              +--> reconciling --+
 *
 * and the terminal outcome Cloud intended (cancelled / timed_out / failed) is
 * only written once the Service confirms the stop, or reports its own
 * terminal outcome. Until then the assignment keeps holding its capacity
 * slot, the cancel is re-sent, and `reconciling` makes the doubt visible.
 *
 * An assignment still `created` was never handed to the Gateway (the Gateway
 * persists `dispatched` before it writes the command), so nothing can be
 * running and it is finalized immediately.
 */

export type RevocationSource =
  | "startup_deadline"
  | "execution_deadline"
  | "work_cancelled"
  | "manual_cancel"
  | "workspace_disconnected"
  | "grant_expired"
  | "grant_revoked"
  | "dispatch_failed"
  | "worker_process_lost";

export interface RevocationIntent {
  /** The terminal status Cloud writes once the stop is confirmed. */
  readonly status: "cancelled" | "timed_out" | "failed";
  readonly reason: string;
  readonly source: RevocationSource;
  /** Failure recorded for `timed_out` / `failed` outcomes. */
  readonly failure?: AssignmentFailurePayload;
}

/** What `error_json` holds while an assignment is being revoked. */
export interface StoredRevocation extends RevocationIntent {
  readonly requestedAt: string;
  /** Status when revocation began; `running` means the provider may have acted. */
  readonly observedStatus: string;
  /** Stable across re-sends so the Service can deduplicate the command. */
  readonly commandId: string;
}

export function revocationCommandId(
  assignmentId: string,
  attemptId: string | null | undefined,
): string {
  return `revoke:${assignmentId}:${attemptId ?? "-"}`;
}

export type RevocationBeginOutcome =
  /** Terminal outcome written immediately: the assignment was never sent. */
  | "finalized"
  /** `revocation_pending` written; a stop must now be confirmed. */
  | "pending"
  /** Another handler already began revoking; its intent stands. */
  | "already_revoking"
  | "terminal"
  /** The decision was made from a status the assignment has since left. */
  | "superseded"
  | "stale"
  | "not_found";

export interface RevocationBeginResult {
  readonly outcome: RevocationBeginOutcome;
  readonly currentStatus?: string;
  readonly observedStatus?: string;
  /**
   * A start permit was granted for this assignment, so a provider process may
   * have been launched even if the Service never reported it.
   */
  readonly permitIssued?: boolean;
  /**
   * Finalized without waiting for the Service: the Service must obtain a start
   * permit before launching, none was ever issued, and none can be granted now.
   */
  readonly fenced?: boolean;
}

interface RevocationRow {
  status: string;
  task_id: string;
  attempt_id: string | null;
  error_json: string | null;
}

async function readRow(
  db: D1Database,
  assignmentId: string,
): Promise<RevocationRow | null> {
  return db
    .prepare(
      `SELECT status, task_id, attempt_id, error_json
         FROM worker_assignments WHERE id = ?1`,
    )
    .bind(assignmentId)
    .first<RevocationRow>();
}

function failureFor(intent: RevocationIntent): AssignmentFailurePayload {
  return (
    intent.failure ?? {
      error: {
        code:
          intent.status === "timed_out" ? "timeout" : "provider_unavailable",
        message: intent.reason,
        retryable: true,
      },
      failedAt: new Date().toISOString(),
    }
  );
}

/** Writes the intended terminal outcome through the guarded terminal writers. */
async function applyIntent(
  db: D1Database,
  assignmentId: string,
  attemptId: string | null | undefined,
  intent: RevocationIntent,
  onlyFrom?: readonly AssignmentLifecycleStatus[],
): Promise<boolean> {
  if (intent.status === "cancelled") {
    return recordAssignmentCancelled(
      db,
      assignmentId,
      { status: "cancelled", reason: intent.reason },
      attemptId ?? undefined,
      { onlyFrom },
    );
  }
  const failure = failureFor(intent);
  // A `failed` intent must not be rewritten to timed_out by the writer.
  const code = intent.status === "timed_out" ? "timeout" : failure.error.code;
  return recordAssignmentError(
    db,
    assignmentId,
    { ...failure, error: { ...failure.error, code } },
    attemptId ?? undefined,
    { onlyFrom },
  );
}

function parseStored(errorJson: string | null): StoredRevocation | null {
  if (!errorJson) return null;
  try {
    const parsed = JSON.parse(errorJson) as { revocation?: StoredRevocation };
    const revocation = parsed.revocation;
    if (
      revocation &&
      typeof revocation === "object" &&
      ["cancelled", "timed_out", "failed"].includes(revocation.status)
    ) {
      return revocation;
    }
  } catch {
    // Fall through: an unreadable intent degrades to a plain cancellation.
  }
  return null;
}

/**
 * Starts revocation. Never reports a stop it has not seen: unless the
 * assignment was never delivered, the result is `pending`.
 */
export async function beginAssignmentRevocation(
  db: D1Database,
  input: {
    assignmentId: string;
    attemptId?: string;
    intent: RevocationIntent;
    /**
     * The statuses the caller's decision was based on. If the assignment has
     * since moved on (a provider-start acknowledgement, say), the stale
     * decision is dropped rather than revoking work that is progressing.
     */
    onlyFrom?: readonly AssignmentLifecycleStatus[];
    now?: string;
  },
): Promise<RevocationBeginResult> {
  const { assignmentId, intent } = input;
  const now = input.now ?? new Date().toISOString();
  // A concurrent handler can advance the row between read and write, so the
  // decision is retried against fresh state a bounded number of times.
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const row = await readRow(db, assignmentId);
    if (!row) return { outcome: "not_found" };
    if (input.attemptId && row.attempt_id !== input.attemptId) {
      return { outcome: "stale", currentStatus: row.status };
    }
    const status = row.status as AssignmentLifecycleStatus;
    if (isTerminalAssignmentStatus(status)) {
      return { outcome: "terminal", currentStatus: status };
    }
    if (isRevocationAssignmentStatus(status)) {
      return fenceIfNeverStarted(db, assignmentId, {
        outcome: "already_revoking",
        currentStatus: status,
      });
    }
    if (input.onlyFrom && !input.onlyFrom.includes(status)) {
      return { outcome: "superseded", currentStatus: status };
    }
    if (status === "created") {
      if (
        await applyIntent(db, assignmentId, row.attempt_id, intent, ["created"])
      ) {
        return { outcome: "finalized", observedStatus: status };
      }
      continue;
    }
    const stored: StoredRevocation = {
      ...intent,
      requestedAt: now,
      observedStatus: status,
      commandId: revocationCommandId(assignmentId, row.attempt_id),
    };
    const result = await transitionAssignment(db, {
      fence: {
        assignmentId,
        ...(input.attemptId ? { attemptId: input.attemptId } : {}),
      },
      to: "revocation_pending",
      // Only the status observed above may be revoked; a newer status is
      // re-read so `observedStatus` always describes what Cloud saw.
      onlyFrom: [status],
      errorJson: JSON.stringify({ revocation: stored }),
      now,
    });
    if (result.applied) {
      return fenceIfNeverStarted(db, assignmentId, {
        outcome: "pending",
        observedStatus: status,
      });
    }
    if (result.outcome === "stale" || result.outcome === "not_found") {
      return { outcome: result.outcome, currentStatus: result.currentStatus };
    }
  }
  return { outcome: "already_revoking" };
}

/**
 * Finalizes a revocation at once when the start permit proves the provider was
 * never launched. Revocation has already moved the assignment out of
 * `acknowledged`, so no permit can be granted any more; if none had been
 * granted before that instant, no process exists or can ever exist.
 *
 * Services without the capability (`start_permit_required = 0`) give no such
 * guarantee, and an assignment observed `running` already has a process, so
 * both keep waiting for the Service to confirm.
 */
async function fenceIfNeverStarted(
  db: D1Database,
  assignmentId: string,
  result: RevocationBeginResult,
): Promise<RevocationBeginResult> {
  const row = await db
    .prepare(
      `SELECT status, attempt_id, error_json, start_permit_required,
              start_permit_issued_at
         FROM worker_assignments WHERE id = ?1`,
    )
    .bind(assignmentId)
    .first<
      RevocationRow & {
        start_permit_required: number | null;
        start_permit_issued_at: string | null;
      }
    >();
  if (!row) return result;
  const permitIssued = row.start_permit_issued_at != null;
  const observed = parseStored(row.error_json)?.observedStatus;
  const neverStarted =
    isRevocationAssignmentStatus(row.status as AssignmentLifecycleStatus) &&
    Number(row.start_permit_required ?? 0) === 1 &&
    !permitIssued &&
    observed !== "running";
  if (!neverStarted) return { ...result, permitIssued };
  const finalized = await finalizeAssignmentRevocation(
    db,
    assignmentId,
    row.attempt_id ?? undefined,
  );
  return finalized === "finalized"
    ? { ...result, outcome: "finalized", fenced: true, permitIssued }
    : { ...result, permitIssued };
}

export type RevocationFinalizeOutcome =
  "finalized" | "not_revoking" | "terminal" | "not_found";

/**
 * Cloud's only path from a revoking status to the terminal status it
 * intended. Call it only with Service evidence that the stop happened.
 */
export async function finalizeAssignmentRevocation(
  db: D1Database,
  assignmentId: string,
  attemptId?: string,
): Promise<RevocationFinalizeOutcome> {
  const row = await readRow(db, assignmentId);
  if (!row) return "not_found";
  const status = row.status as AssignmentLifecycleStatus;
  if (isTerminalAssignmentStatus(status)) return "terminal";
  if (!isRevocationAssignmentStatus(status)) return "not_revoking";
  const intent: RevocationIntent = parseStored(row.error_json) ?? {
    status: "cancelled",
    reason: "Cancelled by Workspace runtime",
    source: "manual_cancel",
  };
  const applied = await applyIntent(
    db,
    assignmentId,
    attemptId ?? row.attempt_id,
    intent,
  );
  return applied ? "finalized" : "terminal";
}

/**
 * Marks revocations the Service has not confirmed within [olderThanMs] as
 * `reconciling`: visible, still holding capacity, and still being re-sent.
 * Returns the IDs escalated.
 */
export async function escalateUnconfirmedRevocations(
  db: D1Database,
  olderThanMs: number,
  now = new Date(),
): Promise<string[]> {
  const cutoff = new Date(now.getTime() - olderThanMs).toISOString();
  const { results } = await db
    .prepare(
      `UPDATE worker_assignments SET status = 'reconciling', updated_at = ?1
        WHERE status = 'revocation_pending' AND updated_at <= ?2
        RETURNING id`,
    )
    .bind(now.toISOString(), cutoff)
    .all<{ id: string }>();
  return (results ?? []).map((row) => row.id);
}

/**
 * Finalizes revocations whose owning Workspace runtime identity has been
 * revoked (for example by `workspace.recovered` re-registering the Workspace).
 *
 * The Service only acts on commands addressed to its own runtime identity, so
 * a cancel for an assignment owned by a replaced identity can never be
 * acknowledged. Waiting for that acknowledgement would hold the capacity slot,
 * the Thread lease and the Work Request forever and make Stop appear broken.
 * The replaced runtime can no longer authenticate or report results, and the
 * new Service reclaims orphaned engine processes on start, so the intended
 * terminal outcome is written without Service confirmation.
 * Returns the IDs finalized.
 */
export async function finalizeRevocationsOfRevokedRuntimes(
  db: D1Database,
  executionWorkspaceId?: string,
): Promise<string[]> {
  const { results } = await db
    .prepare(
      `SELECT wa.id AS id, wa.attempt_id AS attemptId
         FROM worker_assignments wa
         JOIN workspace_runtime_identities ri ON ri.id = wa.runtime_identity_id
        WHERE wa.status IN ('revocation_pending', 'reconciling')
          AND ri.revoked_at IS NOT NULL
          AND (?1::text IS NULL OR wa.execution_workspace_id = ?1)
        LIMIT 100`,
    )
    .bind(executionWorkspaceId ?? null)
    .all<{ id: string; attemptId: string | null }>();
  const finalized: string[] = [];
  for (const row of results ?? []) {
    try {
      const outcome = await finalizeAssignmentRevocation(
        db,
        row.id,
        row.attemptId ?? undefined,
      );
      if (outcome === "finalized") finalized.push(row.id);
    } catch {
      // Best effort: the next recovery pass retries.
    }
  }
  return finalized;
}

export interface RevocationEnv {
  readonly SYNTILA_DB: D1Database;
  readonly SYNTILA_WORKSPACE_GATEWAY?: DurableObjectNamespace;
}

interface RevokingAssignment {
  execution_workspace_id: string;
  runtime_identity_id: string;
  workspace_worker_id: string;
  run_id: string;
  task_id: string;
  attempt_id: string;
  idempotency_key: string;
  error_json: string | null;
}

/**
 * Sends `assignment.cancel` for a revoking assignment through the Workspace
 * Gateway's existing connection and finalizes it if the Service confirms.
 * Returns whether the stop was confirmed. Never throws.
 */
export async function deliverRevocation(
  env: RevocationEnv,
  assignmentId: string,
  reason?: string,
): Promise<boolean> {
  const gateway = env.SYNTILA_WORKSPACE_GATEWAY;
  if (!gateway) return false;
  try {
    const row = await env.SYNTILA_DB.prepare(
      `SELECT execution_workspace_id, runtime_identity_id, workspace_worker_id,
              run_id, task_id, attempt_id, idempotency_key, error_json
         FROM worker_assignments
        WHERE id = ?1 AND status IN ('revocation_pending', 'reconciling')`,
    )
      .bind(assignmentId)
      .first<RevokingAssignment>();
    if (!row) return false;
    // A replaced runtime identity can never acknowledge: finalize instead of
    // sending a command that the current Service ignores.
    const finalizedIds = await finalizeRevocationsOfRevokedRuntimes(
      env.SYNTILA_DB,
      row.execution_workspace_id,
    );
    if (finalizedIds.includes(assignmentId)) return true;
    const stored = parseStored(row.error_json);
    const payload: AssignmentCancelPayload = {
      assignmentId,
      reason: reason ?? stored?.reason ?? "Cloud revoked the assignment",
      commandId:
        stored?.commandId ?? revocationCommandId(assignmentId, row.attempt_id),
      deadlineMs: Date.now() + 10_000,
    };
    const response = await gateway
      .get(gateway.idFromName(row.execution_workspace_id))
      .fetch("http://gateway/cancel-assignment", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          executionWorkspaceId: row.execution_workspace_id,
          workspaceRuntimeId: row.runtime_identity_id,
          workerId: row.workspace_worker_id,
          runId: row.run_id,
          taskId: row.task_id,
          attemptId: row.attempt_id,
          assignmentId,
          idempotencyKey: row.idempotency_key,
          payload,
        }),
      });
    if (!response.ok) return false;
    const acknowledgement = (await response.json()) as { cancelled?: unknown };
    if (acknowledgement.cancelled !== true) return false;
    await finalizeAssignmentRevocation(
      env.SYNTILA_DB,
      assignmentId,
      row.attempt_id,
    );
    return true;
  } catch {
    return false;
  }
}

export interface RevokeResult extends RevocationBeginResult {
  /** True only when a terminal outcome was written on Service evidence. */
  readonly confirmed: boolean;
}

async function notifyServiceOfFence(
  env: RevocationEnv,
  assignmentId: string,
  reason: string,
): Promise<void> {
  const gateway = env.SYNTILA_WORKSPACE_GATEWAY;
  if (!gateway) return;
  try {
    const row = await env.SYNTILA_DB.prepare(
      `SELECT execution_workspace_id, runtime_identity_id, workspace_worker_id,
              run_id, task_id, attempt_id, idempotency_key
         FROM worker_assignments WHERE id = ?1`,
    )
      .bind(assignmentId)
      .first<RevokingAssignment>();
    if (!row) return;
    const sent = gateway
      .get(gateway.idFromName(row.execution_workspace_id))
      .fetch("http://gateway/cancel-assignment", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          executionWorkspaceId: row.execution_workspace_id,
          workspaceRuntimeId: row.runtime_identity_id,
          workerId: row.workspace_worker_id,
          runId: row.run_id,
          taskId: row.task_id,
          attemptId: row.attempt_id,
          assignmentId,
          idempotencyKey: row.idempotency_key,
          payload: {
            assignmentId,
            reason,
            commandId: revocationCommandId(assignmentId, row.attempt_id),
            deadlineMs: Date.now() + 10_000,
          } satisfies AssignmentCancelPayload,
        }),
      });
    // The Gateway holds the request until the Service acknowledges; do not
    // make the caller wait for a courtesy message.
    sent.catch(() => undefined);
    await Promise.race([
      sent,
      new Promise((resolve) => setTimeout(resolve, 3_000)),
    ]);
  } catch {
    // Best effort: the Service is fenced either way.
  }
}

/** Begins revocation and makes one attempt to have the Service confirm it. */
export async function revokeAssignment(
  env: RevocationEnv,
  input: {
    assignmentId: string;
    attemptId?: string;
    intent: RevocationIntent;
    onlyFrom?: readonly AssignmentLifecycleStatus[];
  },
): Promise<RevokeResult> {
  const begun = await beginAssignmentRevocation(env.SYNTILA_DB, input);
  if (begun.outcome === "finalized") {
    // Fenced: nothing can launch, but a Service still holding the queued
    // command should release it now instead of waiting for a denial.
    if (begun.fenced) {
      await notifyServiceOfFence(env, input.assignmentId, input.intent.reason);
    }
    return { ...begun, confirmed: true };
  }
  if (begun.outcome !== "pending" && begun.outcome !== "already_revoking") {
    return { ...begun, confirmed: false };
  }
  const confirmed = await deliverRevocation(
    env,
    input.assignmentId,
    input.intent.reason,
  );
  return { ...begun, confirmed };
}
