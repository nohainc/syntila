-- Per-Space member access grants for Worker Instances (ADR-042).
-- Additive only: owners can share a Worker with selected members of a Space,
-- specifying enabled state and an execution mode ceiling ("chat" | "work" | "work+shell").

CREATE TABLE worker_space_members (
  worker_id text NOT NULL REFERENCES worker_instances(id) ON DELETE CASCADE,
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT true,
  permissions_json text NOT NULL DEFAULT '{"mode":"chat"}' CHECK (permissions_json IS JSON),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (worker_id, space_id, user_id)
);

CREATE INDEX worker_space_members_space_user_idx ON worker_space_members (space_id, user_id);
CREATE INDEX worker_space_members_user_idx ON worker_space_members (user_id);
