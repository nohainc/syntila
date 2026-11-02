-- Free accounts run one AI execution at a time (see ADR-023). The slot itself
-- is derived from `worker_assignments` (a requester's non-terminal rows), so
-- there is no counter to drift. This migration adds:
--  * an index that keeps the atomic admission count cheap, and
--  * the durable waiting list that keeps eligible requests in order.
CREATE INDEX idx_worker_assignments_requester_active
  ON worker_assignments(requested_by_user_id)
  WHERE status IN ('created', 'dispatched', 'acknowledged', 'running',
                   'revocation_pending', 'reconciling');

-- One row per task that was refused a slot. Rows are heartbeated by the
-- waiting Workflow; a stale row (crashed Workflow) stops blocking others and
-- is deleted by the sweep. Rows never hold capacity.
CREATE TABLE account_execution_waiters (
  task_id TEXT PRIMARY KEY,
  requester_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  work_request_id TEXT,
  reason TEXT NOT NULL CHECK (
    reason IN ('account_concurrency_limit', 'workspace_not_ready')
  ),
  enqueued_at TEXT NOT NULL,
  heartbeat_at TEXT NOT NULL
);
CREATE INDEX idx_account_execution_waiters_requester
  ON account_execution_waiters(requester_user_id, enqueued_at, task_id);
