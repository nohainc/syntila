-- Cross-Worker artifact service (ADR-037, phase P8).
--
-- `artifacts` is the metadata table of Worker-produced handoff files. The
-- bytes live in R2 under `storage_key` (the same object a Thread file uses, so
-- quota and size limits are shared). Downstream steps name an artifact by ID and
-- download with an expiring grant bound to the artifact and to the Worker.

-- The old `artifacts` table was dropped in 0015 (nothing wrote it); this is the new one.
CREATE TABLE artifacts (
  id text PRIMARY KEY,
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  thread_id text REFERENCES threads(id) ON DELETE SET NULL,
  work_request_id text REFERENCES work_requests(id) ON DELETE SET NULL,
  assignment_id text REFERENCES worker_assignments(id) ON DELETE SET NULL,
  worker_instance_id text REFERENCES worker_instances(id) ON DELETE SET NULL,
  name text NOT NULL,
  media_type text NOT NULL,
  size_bytes bigint NOT NULL CHECK (size_bytes >= 0),
  content_digest text NOT NULL,
  storage_key text NOT NULL,
  state text NOT NULL DEFAULT 'available' CHECK (state IN ('available', 'expired', 'removed')),
  expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX artifacts_space_idx ON artifacts (space_id);
CREATE INDEX artifacts_work_request_idx ON artifacts (work_request_id);
CREATE INDEX artifacts_assignment_idx ON artifacts (assignment_id);
CREATE INDEX artifacts_worker_instance_idx ON artifacts (worker_instance_id);
CREATE INDEX artifacts_thread_idx ON artifacts (thread_id, created_at);
CREATE INDEX artifacts_retention_idx ON artifacts (expires_at) WHERE state = 'available';

-- One expiring, revocable download right. Only a digest of the token is kept.
CREATE TABLE artifact_download_grants (
  id text PRIMARY KEY,
  artifact_id text NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
  worker_instance_id text NOT NULL REFERENCES worker_instances(id) ON DELETE CASCADE,
  assignment_id text REFERENCES worker_assignments(id) ON DELETE CASCADE,
  token_digest text NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX artifact_download_grants_artifact_idx ON artifact_download_grants (artifact_id);
CREATE INDEX artifact_download_grants_worker_idx ON artifact_download_grants (worker_instance_id);
CREATE INDEX artifact_download_grants_assignment_idx ON artifact_download_grants (assignment_id);
CREATE INDEX artifact_download_grants_expiry_idx ON artifact_download_grants (expires_at);
