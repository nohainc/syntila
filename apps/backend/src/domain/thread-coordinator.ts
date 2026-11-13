/**
 * Durable Object coordinator for one Thread.
 *
 * D1 is the source of truth. The object only serializes mutations, fences
 * workers, and schedules reconciliation after a restart or lease timeout.
 * Active filesystem identity is the ID-derived Thread directory.
 */

import { STEP_HARD_CAP_MS } from "@syntila/core";
import { revokeAssignment } from "./assignment-revocation.js";
import { createEventPublisher } from "./event-publisher.js";

export interface ThreadCoordinatorEnv {
  readonly SYNTILA_DB: D1Database;
  readonly SYNTILA_WORKSPACE_GATEWAY?: DurableObjectNamespace;
  readonly SYNTILA_REALTIME_GATEWAY?: DurableObjectNamespace;
}

export type CoordinatorRequestRow = {
  id: string;
  threadId: string;
  mode: "stateless" | "stateful";
  status: string;
  primaryWorkspaceId: string;
  createdAt: string;
};

export type CoordinatorLeaseRow = {
  id: string;
  threadId: string;
  workRequestId: string;
  workspaceId: string;
  fencingToken: number;
  status: "active" | "released" | "expired";
  expiresAt: string;
};

export const THREAD_LEASE_MS = 30 * 60_000;

/**
 * A Workflow finishes its request within seconds of the last step ending.
 * If the request is still running this long after, the Workflow is presumed
 * lost and the coordinator settles the request itself.
 */
export const LOST_WORKFLOW_GRACE_MS = 5 * 60_000;

/** A Worker that reported a heartbeat or progress this recently is alive. */
export const WORKER_ALIVE_WINDOW_MS = 5 * 60_000;

/**
 * Longest a lease can be kept alive by Worker liveness alone: the step hard
 * cap plus room for queueing and the Service's own timeout report.
 */
export const MAX_LEASE_LIFETIME_MS = STEP_HARD_CAP_MS + 30 * 60_000;

const TERMINAL_ASSIGNMENT_STATUSES = new Set([
  "completed",
  "failed",
  "cancelled",
  "timed_out",
  "lost",
]);

export type ExpiredLeaseAssignment = {
  id: string;
  attemptId: string | null;
  status: string;
  engineAliveAt: string | null;
  runningAt: string | null;
  updatedAt: string | null;
};

export type ExpiredLeaseFacts = {
  acquiredAt: string;
  workspaceOnline: boolean;
  assignments: readonly ExpiredLeaseAssignment[];
  /** Workflow steps not started yet (no assignment, not terminal). */
  remainingSteps?: number;
};

export type ExpiredLeaseFailureReason =
  "worker_lost" | "max_runtime_exceeded" | "workflow_lost";

export type ExpiredLeaseDecision =
  | { action: "extend" }
  | { action: "complete" }
  | {
      action: "fail";
      reason: ExpiredLeaseFailureReason;
      revokeAssignmentIds: string[];
    };

export const EXPIRED_LEASE_MESSAGES: Record<ExpiredLeaseFailureReason, string> =
  {
    worker_lost:
      "The Worker stopped responding, so the request could not finish.",
    max_runtime_exceeded:
      "The request ran longer than the maximum allowed time.",
    workflow_lost:
      "Cloud lost track of this request, so its remaining steps could not run.",
  };

/**
 * An expired lease only proves that nothing renewed it. Before the request is
 * failed, the Worker's own evidence decides: a live Worker keeps the request
 * running, a finished Worker settles it with its real outcome, and only a
 * silent or overrunning Worker fails it (and is stopped).
 */
export function classifyExpiredLease(
  facts: ExpiredLeaseFacts,
  now = Date.now(),
): ExpiredLeaseDecision {
  const open = facts.assignments.filter(
    (row) => !TERMINAL_ASSIGNMENT_STATUSES.has(row.status),
  );
  if (open.length === 0) {
    const latest = [...facts.assignments].sort((a, b) =>
      (b.updatedAt ?? "").localeCompare(a.updatedAt ?? ""),
    )[0];
    // Later steps cannot start without the Workflow, so only a finished
    // last step completes the request.
    return latest?.status === "completed" && !(facts.remainingSteps ?? 0)
      ? { action: "complete" }
      : { action: "fail", reason: "workflow_lost", revokeAssignmentIds: [] };
  }
  const revokeAssignmentIds = open.map((row) => row.id);
  const acquired = Date.parse(facts.acquiredAt);
  if (Number.isFinite(acquired) && now - acquired >= MAX_LEASE_LIFETIME_MS) {
    return {
      action: "fail",
      reason: "max_runtime_exceeded",
      revokeAssignmentIds,
    };
  }
  const lastSign = Math.max(
    ...open.flatMap((row) =>
      [row.engineAliveAt, row.runningAt, row.updatedAt]
        .map((value) => (value ? Date.parse(value) : NaN))
        .filter(Number.isFinite),
    ),
  );
  if (
    facts.workspaceOnline &&
    Number.isFinite(lastSign) &&
    now - lastSign <= WORKER_ALIVE_WINDOW_MS
  ) {
    return { action: "extend" };
  }
  return { action: "fail", reason: "worker_lost", revokeAssignmentIds };
}

/**
 * Extends the Thread lease of a running assignment's Work Request when its
 * Worker proves it is alive. Writes only when less than half the lease is
 * left, so frequent heartbeats cost one indexed no-op update.
 */
export function extendLeaseForLiveAssignment(
  db: D1Database,
  assignmentId: string,
  nowMs = Date.now(),
): D1PreparedStatement {
  return db
    .prepare(
      `UPDATE thread_runtime_leases SET expires_at = ?2
        WHERE status = 'active' AND expires_at < ?3
          AND work_request_id = (
            SELECT COALESCE(wa.work_request_id, wt.work_request_id)
              FROM worker_assignments wa
              LEFT JOIN workflow_tasks wt ON wt.id = wa.task_id
             WHERE wa.id = ?1)`,
    )
    .bind(
      assignmentId,
      new Date(nowMs + THREAD_LEASE_MS).toISOString(),
      new Date(nowMs + THREAD_LEASE_MS / 2).toISOString(),
    );
}

export function selectNextStatefulRequest(
  rows: readonly CoordinatorRequestRow[],
): CoordinatorRequestRow | null {
  return (
    [...rows]
      .filter((row) => row.mode === "stateful" && row.status === "queued")
      .sort(
        (a, b) =>
          a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id),
      )[0] ?? null
  );
}

/**
 * Statements that start a stateful Work Request and issue its Thread lease.
 *
 * The fencing token comes from `threads.lease_fence_counter`, which only ever
 * increases and survives clearing Work history (that deletes the lease rows).
 * The counter is first raised to the highest recorded lease token so a drifted
 * counter heals, then incremented; the lease reads the new value in the same
 * batch. Workspaces compare tokens only within a Thread, so a token that goes
 * backwards is rejected there as a stale fence.
 */
export function startStatefulLeaseStatements(
  db: D1Database,
  input: {
    readonly threadId: string;
    readonly workRequestId: string;
    readonly workspaceId: string;
    readonly leaseId: string;
    readonly now: string;
    readonly expiresAt: string;
  },
): D1PreparedStatement[] {
  return [
    db
      .prepare(
        "UPDATE work_requests SET status = 'running', updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
      )
      .bind(input.now, input.workRequestId),
    db
      .prepare(
        "UPDATE runs SET status = 'running', updated_at = ?1 WHERE work_request_id = ?2 AND status = 'created'",
      )
      .bind(input.now, input.workRequestId),
    db
      .prepare(
        `UPDATE threads
            SET lease_fence_counter = GREATEST(
              lease_fence_counter,
              COALESCE((SELECT MAX(fencing_token) FROM thread_runtime_leases
                         WHERE thread_id = ?1), 0)
            ) + 1
          WHERE id = ?1`,
      )
      .bind(input.threadId),
    db
      .prepare(
        `INSERT INTO thread_runtime_leases
         (id, thread_id, work_request_id, workspace_id, fencing_token, status, acquired_at, expires_at)
         VALUES (?1, ?2, ?3, ?4,
                 (SELECT lease_fence_counter FROM threads WHERE id = ?2),
                 'active', ?5, ?6)`,
      )
      .bind(
        input.leaseId,
        input.threadId,
        input.workRequestId,
        input.workspaceId,
        input.now,
        input.expiresAt,
      ),
  ];
}

/** How often a deferred lease release re-checks whether the Worker stopped. */
const PENDING_RECHECK_MS = 30_000;

export function leaseIsCurrent(
  lease: Pick<CoordinatorLeaseRow, "status" | "expiresAt" | "fencingToken">,
  fencingToken: number,
  now = Date.now(),
): boolean {
  return (
    lease.status === "active" &&
    lease.fencingToken === fencingToken &&
    Date.parse(lease.expiresAt) > now
  );
}

function json(data: unknown, init?: ResponseInit): Response {
  return Response.json(data, {
    ...init,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...init?.headers,
    },
  });
}

function badRequest(message: string): Response {
  return json({ error: message }, { status: 400 });
}

function conflict(message: string): Response {
  return json({ error: message }, { status: 409 });
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0)
    throw new Error(`${field} is required`);
  return value;
}

export class ThreadExecutionCoordinator implements DurableObject {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: ThreadCoordinatorEnv,
  ) {}

  async fetch(request: Request): Promise<Response> {
    try {
      const identity = request.headers.get("x-thread-id");
      if (identity) {
        const existing = await this.state.storage.get<string>("threadId");
        if (existing && existing !== identity)
          return conflict("Coordinator identity mismatch");
        if (!existing) await this.state.storage.put("threadId", identity);
      }
      const path = new URL(request.url).pathname;
      if (request.method === "GET" && path === "/status") return this.status();
      if (request.method !== "POST") return badRequest("POST is required");
      if (path === "/enqueue") return await this.enqueue(await request.json());
      if (path === "/cancel") return await this.cancel(await request.json());
      if (path === "/heartbeat")
        return await this.heartbeat(await request.json());
      if (path === "/complete")
        return await this.complete(await request.json());
      if (path === "/reconcile") return await this.reconcile();
      if (path === "/check-after") {
        const body = (await request.json()) as { delayMs?: unknown };
        const delay = Number(body.delayMs);
        await this.scheduleAlarm(
          Date.now() + (Number.isFinite(delay) && delay > 0 ? delay : 0),
        );
        return json({ scheduled: true });
      }
      return json({ error: "Not found" }, { status: 404 });
    } catch (error) {
      return json(
        { error: error instanceof Error ? error.message : "Coordinator error" },
        { status: 400 },
      );
    }
  }

  async alarm(): Promise<void> {
    await this.reconcile(true);
  }

  private async status(): Promise<Response> {
    const threadId = await this.threadId();
    const active = await this.env.SYNTILA_DB.prepare(
      `SELECT id, work_request_id AS workRequestId,
              workspace_id AS workspaceId, fencing_token AS fencingToken,
              status, expires_at AS expiresAt
       FROM thread_runtime_leases
       WHERE thread_id = ?1 AND status = 'active'
       LIMIT 1`,
    )
      .bind(threadId)
      .first<CoordinatorLeaseRow>();
    const queued = await this.env.SYNTILA_DB.prepare(
      `SELECT id, created_at AS createdAt FROM work_requests
       WHERE thread_id = ?1 AND mode = 'stateful' AND status = 'queued'
       ORDER BY created_at, id`,
    )
      .bind(threadId)
      .all<{ id: string; createdAt: string }>();
    return json({ threadId, active, queued: queued.results });
  }

  private async enqueue(input: unknown): Promise<Response> {
    const workRequestId = requiredString(
      (input as Record<string, unknown>)?.workRequestId,
      "workRequestId",
    );
    const request = await this.requestRow(workRequestId);
    if (!request)
      return json({ error: "Work Request not found" }, { status: 404 });
    if (request.mode !== "stateful")
      return badRequest("Only stateful Work Requests use this coordinator");
    if (request.status !== "queued")
      return json({ workRequestId, status: request.status });
    const result = await this.reconcile();
    return result;
  }

  private async cancel(input: unknown): Promise<Response> {
    const workRequestId = requiredString(
      (input as Record<string, unknown>)?.workRequestId,
      "workRequestId",
    );
    const request = await this.requestRow(workRequestId);
    if (!request)
      return json({ error: "Work Request not found" }, { status: 404 });
    if (request.status === "cancelled")
      return json({ workRequestId, status: "cancelled" });
    if (request.status !== "queued")
      return conflict("Only queued Work Requests can be cancelled");
    const now = new Date().toISOString();
    await this.env.SYNTILA_DB.batch([
      this.env.SYNTILA_DB.prepare(
        "UPDATE work_requests SET status = 'cancelled', updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
      ).bind(now, workRequestId),
      this.env.SYNTILA_DB.prepare(
        "UPDATE runs SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status = 'created'",
      ).bind(now, workRequestId),
      this.env.SYNTILA_DB.prepare(
        "UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status IN ('queued', 'waiting')",
      ).bind(now, workRequestId),
    ]);
    await this.reconcile();
    return json({ workRequestId, status: "cancelled" });
  }

  private async heartbeat(input: unknown): Promise<Response> {
    const body = input as Record<string, unknown>;
    const lease = await this.currentLease(
      requiredString(body.leaseId, "leaseId"),
      requiredString(body.workRequestId, "workRequestId"),
      Number(body.fencingToken),
    );
    if (!lease || !leaseIsCurrent(lease, Number(body.fencingToken)))
      return conflict("Stale or expired lease");
    const expiresAt = new Date(Date.now() + THREAD_LEASE_MS).toISOString();
    await this.env.SYNTILA_DB.prepare(
      "UPDATE thread_runtime_leases SET expires_at = ?1 WHERE id = ?2 AND status = 'active'",
    )
      .bind(expiresAt, lease.id)
      .run();
    await this.state.storage.setAlarm(Date.parse(expiresAt));
    return json({
      leaseId: lease.id,
      fencingToken: lease.fencingToken,
      expiresAt,
    });
  }

  private async complete(input: unknown): Promise<Response> {
    const body = input as Record<string, unknown>;
    const lease = await this.currentLease(
      requiredString(body.leaseId, "leaseId"),
      requiredString(body.workRequestId, "workRequestId"),
      Number(body.fencingToken),
    );
    if (!lease || !leaseIsCurrent(lease, Number(body.fencingToken)))
      return conflict("Stale or expired lease");
    const status =
      body.status === "failed"
        ? "failed"
        : body.status === "cancelled"
          ? "cancelled"
          : "completed";
    const pendingKey = `pending:${lease.workRequestId}`;
    if (
      status !== "completed" &&
      (await this.workerMayBeRunning(lease.workRequestId))
    ) {
      // The Thread is not free while its Worker may still be running: the
      // next request would only wait for it in the Workspace. Keep the lease
      // and finish once the Worker has stopped (or when the Workflow reports
      // completion, or when the lease expires).
      await this.state.storage.put(pendingKey, {
        leaseId: lease.id,
        fencingToken: lease.fencingToken,
        status,
      });
      await this.scheduleAlarm(Date.now() + PENDING_RECHECK_MS);
      return json(
        { workRequestId: lease.workRequestId, status: "pending_worker_stop" },
        { status: 202 },
      );
    }
    await this.state.storage.delete(pendingKey);
    await this.release(lease, status);
    await this.reconcile();
    return json({ workRequestId: lease.workRequestId, status });
  }

  /** True while any assignment of the request has not reached a terminal state. */
  private async workerMayBeRunning(workRequestId: string): Promise<boolean> {
    const row = await this.env.SYNTILA_DB.prepare(
      `SELECT COUNT(*) AS count FROM worker_assignments wa
         JOIN workflow_tasks wt ON wt.id = wa.task_id
        WHERE wt.work_request_id = ?1
          AND wa.status NOT IN ('completed', 'failed', 'cancelled', 'timed_out', 'lost')`,
    )
      .bind(workRequestId)
      .first<{ count: number }>();
    return Number(row?.count ?? 0) > 0;
  }

  private async scheduleAlarm(at: number): Promise<void> {
    const current = await this.state.storage.getAlarm();
    if (current === null || current > at) await this.state.storage.setAlarm(at);
  }

  /** Finishes deferred completions whose Worker has stopped meanwhile. */
  private async settlePending(): Promise<boolean> {
    const pending = await this.state.storage.list<{
      leaseId: string;
      fencingToken: number;
      status: "failed" | "cancelled";
    }>({ prefix: "pending:" });
    let stillWaiting = false;
    for (const [key, value] of pending) {
      const workRequestId = key.slice("pending:".length);
      const lease = await this.currentLease(
        value.leaseId,
        workRequestId,
        value.fencingToken,
      );
      if (!lease || !leaseIsCurrent(lease, value.fencingToken)) {
        await this.state.storage.delete(key);
        continue;
      }
      if (await this.workerMayBeRunning(workRequestId)) {
        stillWaiting = true;
        continue;
      }
      await this.state.storage.delete(key);
      await this.release(lease, value.status);
    }
    return stillWaiting;
  }

  private async release(
    lease: { id: string; workRequestId: string },
    status: "completed" | "failed" | "cancelled",
  ): Promise<void> {
    const now = new Date().toISOString();
    await this.env.SYNTILA_DB.batch([
      this.env.SYNTILA_DB.prepare(
        "UPDATE thread_runtime_leases SET status = 'released', released_at = ?1 WHERE id = ?2 AND status = 'active'",
      ).bind(now, lease.id),
      this.env.SYNTILA_DB.prepare(
        "UPDATE work_requests SET status = ?1, updated_at = ?2 WHERE id = ?3 AND status = 'running'",
      ).bind(status, now, lease.workRequestId),
      this.env.SYNTILA_DB.prepare(
        "UPDATE runs SET status = ?1, updated_at = ?2 WHERE work_request_id = ?3 AND status = 'running'",
      ).bind(status, now, lease.workRequestId),
    ]);
  }

  private async reconcile(fromAlarm = false): Promise<Response> {
    const threadId = await this.threadId();
    const stillWaiting = await this.settlePending();
    await this.settleExpiredLeases(threadId);
    const active = await this.env.SYNTILA_DB.prepare(
      "SELECT id FROM thread_runtime_leases WHERE thread_id = ?1 AND status = 'active' LIMIT 1",
    )
      .bind(threadId)
      .first<{ id: string }>();
    if (!active) await this.startNext(threadId);
    if (fromAlarm) {
      const nextExpiry = await this.env.SYNTILA_DB.prepare(
        "SELECT MIN(expires_at) AS expiresAt FROM thread_runtime_leases WHERE thread_id = ?1 AND status = 'active'",
      )
        .bind(threadId)
        .first<{ expiresAt: string | null }>();
      if (nextExpiry?.expiresAt)
        await this.state.storage.setAlarm(Date.parse(nextExpiry.expiresAt));
      if (stillWaiting)
        await this.scheduleAlarm(Date.now() + PENDING_RECHECK_MS);
    }
    return this.status();
  }

  /**
   * Validates leases before anything is failed: expired leases, and leases
   * whose last step ended a while ago without the Workflow finishing.
   */
  private async settleExpiredLeases(threadId: string): Promise<void> {
    const nowMs = Date.now();
    const now = new Date(nowMs).toISOString();
    const leases = await this.env.SYNTILA_DB.prepare(
      `SELECT l.id, l.work_request_id AS workRequestId,
              l.acquired_at AS acquiredAt, l.workspace_id AS workspaceId,
              l.expires_at AS expiresAt, w.status AS workspaceStatus
         FROM thread_runtime_leases l
         LEFT JOIN execution_workspaces w ON w.id = l.workspace_id
        WHERE l.thread_id = ?1 AND l.status = 'active'`,
    )
      .bind(threadId)
      .all<{
        id: string;
        workRequestId: string;
        acquiredAt: string;
        workspaceId: string;
        expiresAt: string;
        workspaceStatus: string | null;
      }>();
    for (const lease of leases.results ?? []) {
      const expired = Date.parse(lease.expiresAt) <= nowMs;
      const assignments = await this.env.SYNTILA_DB.prepare(
        `SELECT wa.id, wa.attempt_id AS attemptId, wa.status,
                wa.engine_alive_at AS engineAliveAt,
                wa.running_at AS runningAt, wa.updated_at AS updatedAt
           FROM worker_assignments wa
           LEFT JOIN workflow_tasks wt ON wt.id = wa.task_id
          WHERE COALESCE(wa.work_request_id, wt.work_request_id) = ?1`,
      )
        .bind(lease.workRequestId)
        .all<ExpiredLeaseAssignment>();
      const rows = assignments.results ?? [];
      const remaining = await this.env.SYNTILA_DB.prepare(
        `SELECT COUNT(*) AS count FROM workflow_tasks wt
          WHERE wt.work_request_id = ?1 AND wt.status IN ('queued', 'waiting')
            AND NOT EXISTS (SELECT 1 FROM worker_assignments wa WHERE wa.task_id = wt.id)`,
      )
        .bind(lease.workRequestId)
        .first<{ count: number }>();
      const remainingSteps = Number(remaining?.count ?? 0);
      if (!expired) {
        // Early settle only when every step has ended long enough ago that
        // a live Workflow would already have finished the request.
        const allEnded =
          rows.length > 0 &&
          remainingSteps === 0 &&
          rows.every((row) => TERMINAL_ASSIGNMENT_STATUSES.has(row.status));
        const lastEnded = Math.max(
          ...rows.map((row) => Date.parse(row.updatedAt ?? "")),
        );
        if (
          !allEnded ||
          !Number.isFinite(lastEnded) ||
          nowMs - lastEnded < LOST_WORKFLOW_GRACE_MS
        ) {
          continue;
        }
      }
      const decision = classifyExpiredLease(
        {
          acquiredAt: lease.acquiredAt,
          workspaceOnline: lease.workspaceStatus === "online",
          assignments: rows,
          remainingSteps,
        },
        nowMs,
      );
      if (decision.action === "extend") {
        const expiresAt = new Date(nowMs + THREAD_LEASE_MS).toISOString();
        await this.env.SYNTILA_DB.prepare(
          "UPDATE thread_runtime_leases SET expires_at = ?1 WHERE id = ?2 AND status = 'active'",
        )
          .bind(expiresAt, lease.id)
          .run();
        console.warn(
          `Thread lease ${lease.id} expired while its Worker is alive; extended.`,
        );
        continue;
      }
      if (decision.action === "complete") {
        await this.env.SYNTILA_DB.prepare(
          `UPDATE workflow_tasks SET status = 'completed', updated_at = ?1,
                  finished_at = COALESCE(finished_at, ?1)
            WHERE work_request_id = ?2 AND status IN ('queued', 'running', 'waiting')`,
        )
          .bind(now, lease.workRequestId)
          .run();
        await this.release(
          { id: lease.id, workRequestId: lease.workRequestId },
          "completed",
        );
        await this.publishWorkRequestOutcome(threadId, lease, "completed");
        continue;
      }
      const message = EXPIRED_LEASE_MESSAGES[decision.reason];
      await this.env.SYNTILA_DB.batch([
        this.env.SYNTILA_DB.prepare(
          "UPDATE thread_runtime_leases SET status = 'expired', released_at = ?1 WHERE id = ?2 AND status = 'active'",
        ).bind(now, lease.id),
        this.env.SYNTILA_DB.prepare(
          "UPDATE work_requests SET status = 'failed', updated_at = ?1 WHERE id = ?2 AND status = 'running'",
        ).bind(now, lease.workRequestId),
        this.env.SYNTILA_DB.prepare(
          "UPDATE runs SET status = 'failed', finished_at = COALESCE(finished_at, ?1), updated_at = ?1 WHERE work_request_id = ?2 AND status = 'running'",
        ).bind(now, lease.workRequestId),
        // The reason is kept with the steps, where the Work view shows
        // step errors, so it survives a reload.
        this.env.SYNTILA_DB.prepare(
          `UPDATE workflow_tasks SET status = 'failed', error = COALESCE(error, ?3),
                  updated_at = ?1, finished_at = COALESCE(finished_at, ?1)
            WHERE work_request_id = ?2 AND status IN ('queued', 'running', 'waiting')`,
        ).bind(now, lease.workRequestId, message),
      ]);
      // A failed request must not keep a Worker changing files.
      for (const row of rows) {
        if (!decision.revokeAssignmentIds.includes(row.id)) continue;
        try {
          await revokeAssignment(this.env, {
            assignmentId: row.id,
            ...(row.attemptId ? { attemptId: row.attemptId } : {}),
            intent: {
              status: "failed",
              reason: message,
              source:
                decision.reason === "max_runtime_exceeded"
                  ? "execution_deadline"
                  : "worker_process_lost",
              failure: {
                error: {
                  code:
                    decision.reason === "max_runtime_exceeded"
                      ? "timeout"
                      : "provider_unavailable",
                  message,
                  retryable: true,
                },
                failedAt: now,
              },
            },
          });
        } catch (error) {
          console.error(`Failed to revoke assignment ${row.id}`, error);
        }
      }
      await this.publishWorkRequestOutcome(threadId, lease, "failed", message);
    }
  }

  private async publishWorkRequestOutcome(
    threadId: string,
    lease: { workRequestId: string; workspaceId: string },
    status: "completed" | "failed",
    message?: string,
  ): Promise<void> {
    try {
      const row = await this.env.SYNTILA_DB.prepare(
        `SELECT t.space_id AS spaceId, r.requested_by_user_id AS userId
           FROM work_requests r JOIN threads t ON t.id = r.thread_id
          WHERE r.id = ?1`,
      )
        .bind(lease.workRequestId)
        .first<{ spaceId: string; userId: string | null }>();
      if (!row) return;
      const type = `work_request.${status}` as const;
      await createEventPublisher(this.env).publish({
        type,
        workspaceId: lease.workspaceId,
        spaceId: row.spaceId,
        idempotencyKey: `work-request:${lease.workRequestId}:${type}`,
        payload: {
          entityId: lease.workRequestId,
          workRequestId: lease.workRequestId,
          threadId,
          ...(row.userId ? { requestedByUserId: row.userId } : {}),
          status,
          ...(message ? { message } : {}),
        },
      });
    } catch (error) {
      console.error(`Failed to publish work_request.${status}`, error);
    }
  }

  private async startNext(threadId: string): Promise<void> {
    const rows = await this.env.SYNTILA_DB.prepare(
      `SELECT id, thread_id AS threadId, mode, status,
              primary_workspace_id AS primaryWorkspaceId,
              created_at AS createdAt
       FROM work_requests WHERE thread_id = ?1 AND mode = 'stateful' AND status = 'queued'
       ORDER BY created_at, id LIMIT 1`,
    )
      .bind(threadId)
      .all<CoordinatorRequestRow>();
    const next = selectNextStatefulRequest(rows.results);
    if (!next) return;
    const leaseId = `lease-${crypto.randomUUID()}`;
    const now = new Date().toISOString();
    const expiresAt = new Date(Date.now() + THREAD_LEASE_MS).toISOString();
    await this.env.SYNTILA_DB.batch(
      startStatefulLeaseStatements(this.env.SYNTILA_DB, {
        threadId,
        workRequestId: next.id,
        workspaceId: next.primaryWorkspaceId,
        leaseId,
        now,
        expiresAt,
      }),
    );
    await this.state.storage.setAlarm(Date.parse(expiresAt));
  }

  private async requestRow(id: string): Promise<CoordinatorRequestRow | null> {
    return this.env.SYNTILA_DB.prepare(
      `SELECT id, thread_id AS threadId, mode, status,
              primary_workspace_id AS primaryWorkspaceId,
              created_at AS createdAt FROM work_requests WHERE id = ?1`,
    )
      .bind(id)
      .first<CoordinatorRequestRow>();
  }

  private async currentLease(
    leaseId: string,
    workRequestId: string,
    token: number,
  ) {
    return this.env.SYNTILA_DB.prepare(
      `SELECT l.id, l.thread_id AS threadId, l.work_request_id AS workRequestId,
              workspace_id AS workspaceId,
              fencing_token AS fencingToken, l.status, l.expires_at AS expiresAt
       FROM thread_runtime_leases l
       WHERE l.id = ?1 AND l.work_request_id = ?2 AND l.fencing_token = ?3`,
    )
      .bind(leaseId, workRequestId, token)
      .first<CoordinatorLeaseRow>();
  }

  private async threadId(): Promise<string> {
    const value = await this.state.storage.get<string>("threadId");
    if (value) return value;
    throw new Error("Coordinator identity is not initialized");
  }
}

/**
 * Asks the Thread coordinator to look at the request again after the lost
 * Workflow grace, once an assignment has ended. A live Workflow finishes the
 * request long before; a lost one is settled by the coordinator.
 */
export async function scheduleLostWorkflowCheck(
  env: {
    readonly SYNTILA_DB: D1Database;
    readonly SYNTILA_THREAD_COORDINATOR?: DurableObjectNamespace;
  },
  assignmentId: string,
): Promise<void> {
  if (!env.SYNTILA_THREAD_COORDINATOR) return;
  try {
    const row = await env.SYNTILA_DB.prepare(
      `SELECT wr.thread_id AS threadId FROM worker_assignments wa
         LEFT JOIN workflow_tasks wt ON wt.id = wa.task_id
         JOIN work_requests wr
           ON wr.id = COALESCE(wa.work_request_id, wt.work_request_id)
        WHERE wa.id = ?1 AND wr.mode = 'stateful' AND wr.status = 'running'`,
    )
      .bind(assignmentId)
      .first<{ threadId: string }>();
    if (!row) return;
    await env.SYNTILA_THREAD_COORDINATOR.getByName(row.threadId).fetch(
      "https://thread-coordinator/check-after",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-thread-id": row.threadId,
        },
        body: JSON.stringify({ delayMs: LOST_WORKFLOW_GRACE_MS + 30_000 }),
      },
    );
  } catch (error) {
    console.error("Failed to schedule lost Workflow check", error);
  }
}
