-- ADR-040: a Thread lease may be held by a Worker Instance (its Agent's Space
-- folder is the checkout) instead of an execution Workspace. Exactly one holder.
ALTER TABLE thread_runtime_leases ALTER COLUMN workspace_id DROP NOT NULL;
ALTER TABLE thread_runtime_leases
  ADD COLUMN worker_instance_id text REFERENCES worker_instances(id) ON DELETE RESTRICT;
ALTER TABLE thread_runtime_leases
  ADD CONSTRAINT thread_runtime_leases_one_holder
  CHECK (num_nonnulls(workspace_id, worker_instance_id) = 1);

-- The Worker a stateful request runs on (all its steps), set only on the Worker path.
ALTER TABLE work_requests
  ADD COLUMN primary_worker_instance_id text REFERENCES worker_instances(id) ON DELETE RESTRICT;
ALTER TABLE work_requests
  ADD CONSTRAINT work_requests_one_primary
  CHECK (primary_workspace_id IS NULL OR primary_worker_instance_id IS NULL);
