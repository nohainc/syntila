-- Owner decision (2026-11-15): Work history is deleted together with its
-- Thread. Deleting a Thread or a Space now removes, by cascade, its Work
-- Requests, Workflow tasks, Worker assignments, Runs and conversation turns.
-- Before, assignments and runs were kept with their links set to NULL, so the
-- deletion code had to remove children by hand in a fixed order.

-- 1. History that already outlived its Thread or task.
DELETE FROM conversation_turns t WHERE NOT EXISTS (SELECT 1 FROM workflow_tasks k WHERE k.id = t.task_id);
DELETE FROM worker_assignments a
 WHERE a.thread_id IS NULL OR a.work_request_id IS NULL
    OR (a.task_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM workflow_tasks k WHERE k.id = a.task_id));
DELETE FROM runs r WHERE r.thread_id IS NULL;

-- 2. Children follow their parent instead of being detached.
ALTER TABLE worker_assignments DROP CONSTRAINT worker_assignments_thread_id_fkey,
  ADD CONSTRAINT worker_assignments_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE;
ALTER TABLE worker_assignments DROP CONSTRAINT worker_assignments_work_request_id_fkey,
  ADD CONSTRAINT worker_assignments_work_request_id_fkey FOREIGN KEY (work_request_id) REFERENCES work_requests(id) ON DELETE CASCADE;
ALTER TABLE worker_assignments DROP CONSTRAINT worker_assignments_run_id_fkey,
  ADD CONSTRAINT worker_assignments_run_id_fkey FOREIGN KEY (run_id) REFERENCES runs(id) ON DELETE CASCADE;
ALTER TABLE runs DROP CONSTRAINT runs_thread_id_fkey,
  ADD CONSTRAINT runs_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE;
ALTER TABLE runs DROP CONSTRAINT runs_work_request_id_fkey,
  ADD CONSTRAINT runs_work_request_id_fkey FOREIGN KEY (work_request_id) REFERENCES work_requests(id) ON DELETE CASCADE;
ALTER TABLE workflow_task_dependencies DROP CONSTRAINT workflow_task_dependencies_depends_on_task_id_fkey,
  ADD CONSTRAINT workflow_task_dependencies_depends_on_task_id_fkey FOREIGN KEY (depends_on_task_id) REFERENCES workflow_tasks(id) ON DELETE CASCADE;
-- NO ACTION (checked at the end of the statement) instead of RESTRICT, so a
-- Space deletion can remove the Direct Space and its General Thread together.
-- Deleting the General Thread on its own is still refused.
ALTER TABLE direct_spaces DROP CONSTRAINT direct_spaces_general_thread_id_fkey,
  ADD CONSTRAINT direct_spaces_general_thread_id_fkey FOREIGN KEY (general_thread_id) REFERENCES threads(id);

-- 3. Task references become foreign keys.
ALTER TABLE worker_assignments
  ADD CONSTRAINT worker_assignments_task_id_fkey FOREIGN KEY (task_id) REFERENCES workflow_tasks(id) ON DELETE CASCADE;
ALTER TABLE conversation_turns
  ADD CONSTRAINT conversation_turns_task_id_fkey FOREIGN KEY (task_id) REFERENCES workflow_tasks(id) ON DELETE CASCADE;
