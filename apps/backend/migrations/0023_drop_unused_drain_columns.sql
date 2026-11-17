-- Contract step: worker_scheduling.drain_requested_by_user_id, drain_requested_at
-- and drain_completed_at were created with the first schema for a drain
-- workflow that was never built. No backend code, app, Workspace client,
-- trigger or view reads or writes them, so the previous release does not
-- depend on them. Dropping a column also drops its foreign key and the
-- worker_scheduling_drain_requested_by_user_id_fkidx index.
-- The 'draining' state and the 'drain_requested' / 'drain_completed' audit
-- actions are CHECK values, not columns, and stay as they are.
ALTER TABLE worker_scheduling
  DROP COLUMN drain_requested_by_user_id,
  DROP COLUMN drain_requested_at,
  DROP COLUMN drain_completed_at;
