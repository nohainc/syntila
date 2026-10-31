-- A desktop install identifies itself so a new sign-in replaces, rather than
-- accumulates beside, that install's earlier sessions. NULL for older clients.
ALTER TABLE desktop_human_sessions ADD COLUMN device_id TEXT;

CREATE INDEX idx_desktop_human_sessions_device
  ON desktop_human_sessions(user_id, device_id)
  WHERE device_id IS NOT NULL AND revoked_at IS NULL;
