-- migrate:no-transaction
-- Indexes for the foreign keys added in 0011. Built CONCURRENTLY; safe to re-run.

CREATE INDEX CONCURRENTLY IF NOT EXISTS account_execution_waiters_run_id_fkidx ON account_execution_waiters (run_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS account_execution_waiters_work_request_id_fkidx ON account_execution_waiters (work_request_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS work_request_inputs_thread_id_fkidx ON work_request_inputs (thread_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS work_request_inputs_workspace_id_fkidx ON work_request_inputs (workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_service_readiness_runtime_identity_id_fkidx ON workspace_service_readiness (runtime_identity_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_service_readiness_session_id_fkidx ON workspace_service_readiness (session_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS discussion_messages_work_request_id_fkidx ON discussion_messages (work_request_id);
