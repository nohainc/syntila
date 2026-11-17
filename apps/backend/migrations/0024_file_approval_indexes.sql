-- migrate:no-transaction
-- Indexes for the foreign keys added in 0025. Built CONCURRENTLY; safe to re-run.

CREATE INDEX CONCURRENTLY IF NOT EXISTS user_files_thread_id_fkidx ON user_files (thread_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS user_files_space_id_fkidx ON user_files (space_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS plan_approvals_approved_by_user_id_fkidx ON plan_approvals (approved_by_user_id);
