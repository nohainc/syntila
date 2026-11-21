-- The models and efforts a paired Agent's provider CLI offers. The Agent captures
-- them every time its service starts (or when the owner runs `syntila-connect
-- models`) and publishes them to its Worker. They belong to the Worker, not to
-- one connection: the last report stays until the next one replaces it.
ALTER TABLE worker_agent_sessions ADD COLUMN models_json text CHECK (models_json IS NULL OR models_json IS JSON);
ALTER TABLE worker_agent_sessions ADD COLUMN models_reported_at timestamptz;
-- `ok`, or a short reason code when the Agent could not capture models.
ALTER TABLE worker_agent_sessions ADD COLUMN models_status text;
