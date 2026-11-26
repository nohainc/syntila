-- Remove the last Workspace columns and the legacy `execution_workspace` stream kind.
-- Execution events of the removed Workspace system had no consumer; their streams
-- are deleted, so every remaining stream has a `stream_id`.

DELETE FROM realtime_events WHERE stream_kind = 'execution_workspace';
DELETE FROM realtime_event_cursors WHERE stream_kind = 'execution_workspace';

DROP INDEX IF EXISTS
  idx_realtime_event_cursors_stream,
  idx_realtime_events_stream_idempotency,
  idx_realtime_events_stream_seq,
  idx_realtime_events_stream_time,
  idx_realtime_events_workspace_time;

ALTER TABLE realtime_event_cursors
  DROP CONSTRAINT realtime_event_cursors_pkey,
  DROP CONSTRAINT realtime_event_cursors_check,
  DROP CONSTRAINT realtime_event_cursors_stream_kind_check;
ALTER TABLE realtime_events
  DROP CONSTRAINT realtime_events_check,
  DROP CONSTRAINT realtime_events_check1,
  DROP CONSTRAINT realtime_events_stream_kind_check;

ALTER TABLE realtime_event_cursors DROP COLUMN stream_key;
ALTER TABLE realtime_event_cursors DROP COLUMN workspace_id;
ALTER TABLE realtime_events DROP COLUMN workspace_id, DROP COLUMN workspace_runtime_id;

ALTER TABLE realtime_event_cursors
  ALTER COLUMN stream_id SET NOT NULL,
  ALTER COLUMN stream_kind DROP DEFAULT;
ALTER TABLE realtime_events
  ALTER COLUMN stream_id SET NOT NULL,
  ALTER COLUMN stream_kind DROP DEFAULT;

ALTER TABLE realtime_event_cursors
  ADD CONSTRAINT realtime_event_cursors_pkey PRIMARY KEY (stream_kind, stream_id),
  ADD CONSTRAINT realtime_event_cursors_stream_kind_check
    CHECK (stream_kind IN ('space', 'user', 'thread', 'worker_inbox', 'assignment'));
ALTER TABLE realtime_events
  ADD CONSTRAINT realtime_events_stream_kind_check
    CHECK (stream_kind IN ('space', 'user', 'thread', 'worker_inbox', 'assignment'));

CREATE UNIQUE INDEX idx_realtime_events_stream_idempotency
  ON realtime_events(stream_kind, stream_id, idempotency_key);
CREATE UNIQUE INDEX idx_realtime_events_stream_seq
  ON realtime_events(stream_kind, stream_id, sequence);
CREATE INDEX idx_realtime_events_stream_time
  ON realtime_events(stream_kind, stream_id, occurred_at);

ALTER TABLE issue_reports DROP COLUMN workspace_id;
DROP INDEX IF EXISTS idx_worker_activity_history_workspace;
ALTER TABLE worker_activity_history DROP COLUMN workspace_id;

DROP FUNCTION IF EXISTS workspace_space_grant_status_transition_valid_fn();

-- Diagnostic vocabulary: Connect is the component, not a Workspace.
UPDATE issue_reports SET component = 'connect_service' WHERE component = 'workspace_service';
UPDATE issue_reports SET failure_stage = CASE failure_stage
    WHEN 'workspace_disconnect' THEN 'connect_disconnect'
    WHEN 'workspace_lease' THEN 'connect_lease'
    WHEN 'workspace_start_failed' THEN 'worker_start_failed'
    WHEN 'workspace_not_reached' THEN 'connect_not_reached'
    ELSE failure_stage END
  WHERE failure_stage IN ('workspace_disconnect', 'workspace_lease',
    'workspace_start_failed', 'workspace_not_reached');
