-- Clears execution state orphaned by cancelled/failed Work Requests in a
-- LOCAL development PostgreSQL database: active Thread leases, never-launched
-- assignments (and their Agent commands), and Work Requests stuck in `queued`.
-- Safe to re-run. Apply with scripts/local-cleanup-stale-execution.sh.
BEGIN;

UPDATE thread_runtime_leases
   SET status = 'released', released_at = now()
 WHERE status = 'active'
   AND work_request_id IN (
     SELECT id FROM work_requests WHERE status IN ('cancelled', 'failed', 'completed'));

-- Assignments that were never sent. Their pending Agent commands follow the
-- assignment (agent_commands_follow_assignment_fn); cancel the rest explicitly.
UPDATE worker_assignments
   SET status = 'cancelled', updated_at = now()
 WHERE status = 'created'
   AND dispatched_at IS NULL
   AND task_id IN (
     SELECT wt.id FROM workflow_tasks wt
       JOIN work_requests wr ON wr.id = wt.work_request_id
      WHERE wr.status IN ('cancelled', 'failed', 'completed'));

UPDATE agent_commands
   SET status = 'cancelled', updated_at = now()
 WHERE status IN ('pending', 'sent')
   AND assignment_id IN (SELECT id FROM worker_assignments WHERE status IN ('cancelled', 'failed', 'completed'));

-- Work Requests still `queued` for more than 5 minutes never started; cancel them.
UPDATE work_requests
   SET status = 'cancelled', updated_at = now()
 WHERE status = 'queued'
   AND created_at < now() - interval '5 minutes';

UPDATE runs
   SET status = 'cancelled', finished_at = now(), updated_at = now()
 WHERE status IN ('created', 'running')
   AND work_request_id IN (SELECT id FROM work_requests WHERE status = 'cancelled');

UPDATE workflow_tasks
   SET status = 'cancelled', finished_at = now(), updated_at = now()
 WHERE status IN ('queued', 'waiting', 'running')
   AND work_request_id IN (SELECT id FROM work_requests WHERE status = 'cancelled');

COMMIT;
