-- Plan-based attachment storage (see ADR-025). A reservation holds capacity
-- for one in-flight upload and is converted to a `user_files` row (and
-- deleted) in the same batch that finalizes it. Admission counts live
-- reservations next to retained files; an expired reservation counts for
-- nothing, so an abandoned upload can never consume quota permanently.
CREATE TABLE user_file_reservations (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  size_bytes INTEGER NOT NULL CHECK (size_bytes >= 0),
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE INDEX idx_user_file_reservations_user
  ON user_file_reservations(user_id, expires_at);
