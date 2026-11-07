-- New personal connections start without a Thread. Preserve existing General
-- Threads and their protections, while allowing future rows to omit one.
CREATE TABLE direct_spaces_new (
  space_id TEXT PRIMARY KEY REFERENCES spaces(id) ON DELETE CASCADE,
  user_low_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_high_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  general_thread_id TEXT REFERENCES threads(id) ON DELETE RESTRICT,
  created_at TEXT NOT NULL,
  CHECK (user_low_id < user_high_id),
  UNIQUE (user_low_id, user_high_id)
);
INSERT INTO direct_spaces_new SELECT space_id, user_low_id, user_high_id, general_thread_id, created_at FROM direct_spaces;
DROP TABLE direct_spaces;
ALTER TABLE direct_spaces_new RENAME TO direct_spaces;
CREATE INDEX idx_direct_spaces_high ON direct_spaces(user_high_id, user_low_id);
CREATE TRIGGER validate_direct_space_general_thread
BEFORE INSERT ON direct_spaces WHEN NEW.general_thread_id IS NOT NULL
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM threads t WHERE t.id = NEW.general_thread_id AND t.space_id = NEW.space_id
  ) THEN RAISE(ABORT, 'general_thread_id must belong to the same Direct Space') END;
END;
CREATE TRIGGER validate_direct_space_general_thread_update
BEFORE UPDATE OF general_thread_id, space_id ON direct_spaces WHEN NEW.general_thread_id IS NOT NULL
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM threads t WHERE t.id = NEW.general_thread_id AND t.space_id = NEW.space_id
  ) THEN RAISE(ABORT, 'general_thread_id must belong to the same Direct Space') END;
END;
