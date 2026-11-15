-- migrate:no-transaction
-- Indexes for the task foreign keys added in 0014. Built CONCURRENTLY; safe to re-run.

CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_assignments_task_id_fkidx ON worker_assignments (task_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS conversation_turns_task_id_fkidx ON conversation_turns (task_id);
