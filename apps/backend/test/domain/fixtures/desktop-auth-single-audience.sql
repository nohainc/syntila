-- Deployed desktop-auth schema from the original v8 baseline, before the
-- Profile Lab audience was introduced. Keep this fixture independent from
-- 0001 so migrations are tested against the schema that was already live.
CREATE TABLE desktop_auth_intents (
  id TEXT PRIMARY KEY,
  user_code_hash TEXT NOT NULL,
  poll_token_hash TEXT NOT NULL,
  client_name TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  approved_at TEXT,
  approved_user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
  claimed_at TEXT,
  claimed_session_id TEXT,
  denied_at TEXT
);

CREATE INDEX idx_desktop_auth_intents_expiry
  ON desktop_auth_intents(expires_at)
  WHERE claimed_at IS NULL AND denied_at IS NULL;

CREATE TABLE desktop_human_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  audience TEXT NOT NULL CHECK (audience = 'syntila.desktop.management'),
  created_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT
);

CREATE INDEX idx_desktop_human_sessions_user
  ON desktop_human_sessions(user_id, created_at DESC);
