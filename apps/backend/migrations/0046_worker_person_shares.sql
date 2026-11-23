-- Person Shares for Worker Instances (ADR-043).
-- Additive only: an owner lets one person use a Worker for Chat in that
-- person's own Spaces and personal Threads, never Work or shell. Models and
-- efforts follow the Worker-wide member allow-list (worker_member_model_access).
-- One row per (Worker, person); deleting the row revokes the share.

CREATE TABLE worker_person_shares (
  worker_id text NOT NULL REFERENCES worker_instances(id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  max_concurrent_requests integer NOT NULL DEFAULT 1
    CHECK (max_concurrent_requests BETWEEN 1 AND 10),
  max_run_seconds_per_month integer
    CHECK (max_run_seconds_per_month IS NULL OR max_run_seconds_per_month > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (worker_id, user_id)
);

CREATE INDEX worker_person_shares_user_idx ON worker_person_shares (user_id);
