-- Worker-targeted dispatch (ADR-035, phase P5). Expand only.
--
-- * The Workspace columns of an assignment become optional. They stay as
--   legacy metadata on historical attempts; a Worker-targeted assignment never
--   sets them.
-- * execution_path names the one path an assignment runs on, fixed when the
--   row is created: 'workspace' (legacy Workspace gateway) or 'worker' (Worker
--   inbox, Agent session fence). The CHECK makes "one path per assignment" a
--   database rule: a row cannot carry both identities or neither.
-- * worker_snapshot_json: what was true when the request was accepted (Worker,
--   Actor, Type, Profile digest and revision, model, effort, permissions).
--   Later renames, Profile changes or Worker removal never rewrite it.
-- Existing rows keep execution_path = 'workspace' and satisfy the CHECK.

ALTER TABLE worker_assignments ALTER COLUMN execution_workspace_id DROP NOT NULL;
ALTER TABLE worker_assignments ALTER COLUMN runtime_identity_id DROP NOT NULL;

ALTER TABLE worker_assignments
  ADD COLUMN execution_path text NOT NULL DEFAULT 'workspace'
    CHECK (execution_path IN ('workspace', 'worker'));
ALTER TABLE worker_assignments
  ADD COLUMN worker_snapshot_json text
    CHECK (worker_snapshot_json IS NULL OR (worker_snapshot_json IS JSON));

-- NOT VALID + VALIDATE so the large table is not held under an exclusive lock.
ALTER TABLE worker_assignments ADD CONSTRAINT worker_assignments_one_path_check CHECK (
  (execution_path = 'workspace'
     AND execution_workspace_id IS NOT NULL AND runtime_identity_id IS NOT NULL)
  OR
  (execution_path = 'worker'
     AND worker_instance_id IS NOT NULL
     AND execution_workspace_id IS NULL AND runtime_identity_id IS NULL
     AND worker_snapshot_json IS NOT NULL)
) NOT VALID;
ALTER TABLE worker_assignments VALIDATE CONSTRAINT worker_assignments_one_path_check;

-- The Worker's live work: assignments on the Worker path by Worker and status.
CREATE INDEX worker_assignments_worker_path_idx
  ON worker_assignments (worker_instance_id, status)
  WHERE execution_path = 'worker';
