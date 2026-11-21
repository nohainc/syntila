-- The owner asks a connected Agent to re-read the models its provider CLI
-- offers (Workers page "Refresh models"). The Agent sees the request on its
-- next heartbeat and answers by publishing, which stamps models_reported_at.
ALTER TABLE worker_agent_sessions ADD COLUMN models_refresh_requested_at timestamptz;
