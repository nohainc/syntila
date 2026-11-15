-- migrate:no-transaction
-- Indexes for the foreign keys added in 0008 (every foreign key needs an
-- index that starts with its columns). Built CONCURRENTLY; safe to re-run.

CREATE INDEX CONCURRENTLY IF NOT EXISTS conversation_user_messages_author_user_id_fkidx ON conversation_user_messages (author_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS thread_request_queue_author_user_id_fkidx ON thread_request_queue (author_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS thread_request_queue_state_paused_by_user_id_fkidx ON thread_request_queue_state (paused_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS work_request_inputs_user_id_fkidx ON work_request_inputs (user_id);
