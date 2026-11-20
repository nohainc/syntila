-- Workspace-free Workflow configuration (ADR-035, phase P6). Expand only.
--
-- user_workflow_configurations is keyed by Workspace. With Worker-targeted
-- dispatch a person's Workflow preferences belong to the person, so they get
-- their own table. The old rows stay as they are; they are read through the
-- legacy Worker mapping until a person saves again.

CREATE TABLE user_worker_workflow_configurations (
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  workflow_id text NOT NULL,
  schema_version bigint NOT NULL CHECK (schema_version IN (1, 2)),
  configuration_json text NOT NULL CHECK (configuration_json IS JSON),
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, workflow_id)
);
