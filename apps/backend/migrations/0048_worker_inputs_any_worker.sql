-- Files on the Worker path have no single receiver (replaces the 0047 rule).
-- They live in R2 once uploaded; any Worker that runs a Step of the request
-- downloads them with its own session when the Step starts. A Workspace-path
-- row still names its Workspace.

ALTER TABLE work_request_inputs DROP CONSTRAINT work_request_inputs_one_target;
ALTER TABLE work_request_inputs DROP COLUMN worker_instance_id;
