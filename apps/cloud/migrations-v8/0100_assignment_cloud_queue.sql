-- Cloud owns pre-delivery queue reasons. Service startup evidence stays separate.
ALTER TABLE worker_assignments ADD COLUMN cloud_queue_reason TEXT
  CHECK (cloud_queue_reason IN ('workspace_capacity', 'service_not_ready'));
ALTER TABLE worker_assignments ADD COLUMN cloud_queue_since TEXT;
