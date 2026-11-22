-- Models and efforts every non-owner member may use on a shared Worker (ADR-042).
-- Additive only: one row per Worker, applied in all Spaces. Allow-list: with no
-- row nothing is allowed, so a new Worker or a newly reported model starts
-- closed. The owner is never restricted by it.

CREATE TABLE worker_member_model_access (
  worker_id text PRIMARY KEY REFERENCES worker_instances(id) ON DELETE CASCADE,
  allowed_models_json text NOT NULL DEFAULT '[]' CHECK (allowed_models_json IS JSON),
  allowed_efforts_json text NOT NULL DEFAULT '{}' CHECK (allowed_efforts_json IS JSON),
  updated_at timestamptz NOT NULL DEFAULT now()
);
