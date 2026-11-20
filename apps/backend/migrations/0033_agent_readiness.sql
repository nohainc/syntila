-- The Agent reports its own readiness (credential, Profile, folders, Engine) when it
-- connects. It belongs to the session, so a new login replaces it and a stale
-- report can never outlive its connection.
ALTER TABLE worker_agent_sessions ADD COLUMN readiness_json text CHECK (readiness_json IS NULL OR readiness_json IS JSON);
ALTER TABLE worker_agent_sessions ADD COLUMN readiness_reported_at timestamptz;
