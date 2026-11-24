-- Input Delivery v1 on the Worker path (ADR-035, ADR-037).
-- Additive: a file input is delivered either to a Workspace (legacy path) or
-- to the one Worker Instance that runs the request, never to both. The Agent
-- downloads it with its own session; nothing else about delivery changes.

ALTER TABLE work_request_inputs ALTER COLUMN workspace_id DROP NOT NULL;
ALTER TABLE work_request_inputs
  ADD COLUMN worker_instance_id text REFERENCES worker_instances(id) ON DELETE CASCADE;
ALTER TABLE work_request_inputs
  ADD CONSTRAINT work_request_inputs_one_target
  CHECK (num_nonnulls(workspace_id, worker_instance_id) = 1);
CREATE INDEX work_request_inputs_worker_instance_id_fkidx
  ON work_request_inputs (worker_instance_id);
