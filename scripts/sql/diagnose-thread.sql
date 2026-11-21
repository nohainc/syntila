-- Read-only: what happened to the requests in one Thread (LOCAL development database).
--   scripts/diagnose-thread.sh [space-name] [thread-name]     (defaults: test ttt)
-- Only SELECTs. Nothing is changed.
\pset pager off
\echo == Thread
SELECT t.id, t.name, s.name AS space, t.space_id FROM threads t JOIN spaces s ON s.id = t.space_id
 WHERE s.name = :'space_name' AND t.name = :'thread_name';

\echo == Work requests (newest first)
SELECT to_jsonb(r) - 'input_json' AS work_request FROM work_requests r
 WHERE r.thread_id IN (SELECT t.id FROM threads t JOIN spaces s ON s.id = t.space_id
                        WHERE s.name = :'space_name' AND t.name = :'thread_name')
 ORDER BY r.created_at DESC LIMIT 5;

\echo == Worker assignments (newest first)
SELECT a.id, a.status, a.execution_path, a.worker_instance_id, a.model, a.created_at, a.dispatched_at,
       a.acknowledged_at, a.running_at, a.updated_at, a.error_json
  FROM worker_assignments a
 WHERE a.thread_id IN (SELECT t.id FROM threads t JOIN spaces s ON s.id = t.space_id
                        WHERE s.name = :'space_name' AND t.name = :'thread_name')
 ORDER BY a.created_at DESC LIMIT 5;

\echo == Workers and their sessions
SELECT w.id, w.name, w.enabled, w.revoked_at,
       (SELECT count(*) FROM worker_credentials c WHERE c.worker_instance_id = w.id AND c.revoked_at IS NULL) AS live_credentials,
       s.disconnected_at, s.lease_expires_at, s.last_seen_at, s.readiness_json, s.models_status
  FROM worker_instances w LEFT JOIN worker_agent_sessions s ON s.worker_instance_id = w.id
 ORDER BY w.created_at DESC;

\echo == Why the latest request failed: tasks, runs, workflow run and messages
WITH req AS (
  SELECT r.id FROM work_requests r
   WHERE r.thread_id IN (SELECT t.id FROM threads t JOIN spaces s ON s.id = t.space_id
                          WHERE s.name = :'space_name' AND t.name = :'thread_name')
   ORDER BY r.created_at DESC LIMIT 1)
SELECT 'workflow_task' AS what, to_jsonb(x) - 'input_json' - 'snapshot_json' AS row FROM workflow_tasks x WHERE x.work_request_id IN (SELECT id FROM req)
UNION ALL
SELECT 'run', to_jsonb(x) - 'input_json' - 'snapshot_json' FROM runs x WHERE x.work_request_id IN (SELECT id FROM req)
UNION ALL
SELECT 'workflow_run', to_jsonb(x) - 'snapshot_json' FROM conversation_workflow_runs x WHERE x.work_request_id IN (SELECT id FROM req)
UNION ALL
SELECT 'message', to_jsonb(x) FROM discussion_messages x WHERE x.work_request_id IN (SELECT id FROM req);
