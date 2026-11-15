-- Lists rows whose user reference points at no user. Run on production
-- before validating the NOT VALID foreign keys of migration 0008:
--   sudo -u postgres psql -X -d syntila < check-user-references.sql
-- All four counts at 0 means the keys can be validated.
SELECT 'conversation_user_messages.author_user_id' AS reference, count(*) AS orphans
  FROM conversation_user_messages t WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = t.author_user_id)
UNION ALL SELECT 'thread_request_queue.author_user_id', count(*)
  FROM thread_request_queue t WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = t.author_user_id)
UNION ALL SELECT 'thread_request_queue_state.paused_by_user_id', count(*)
  FROM thread_request_queue_state t WHERE t.paused_by_user_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = t.paused_by_user_id)
UNION ALL SELECT 'work_request_inputs.user_id', count(*)
  FROM work_request_inputs t WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = t.user_id);
