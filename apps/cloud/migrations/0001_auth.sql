-- Syntila auth Worker D1 schema (fresh start after the VPS migration).
-- D1 now holds only accounts and sign-in state; all product data lives in the
-- backend's PostgreSQL. The users row is Better Auth's user model; the backend
-- keeps its own users table, synced from tokens and /internal calls.

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deactivated')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  avatar_url TEXT,
  email_verified INTEGER NOT NULL DEFAULT 0 CHECK (email_verified IN (0, 1))
);

CREATE TABLE auth_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token TEXT NOT NULL UNIQUE,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  ip_address TEXT,
  user_agent TEXT
);

CREATE INDEX idx_auth_sessions_user ON auth_sessions(user_id);

CREATE TABLE auth_accounts (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  access_token TEXT,
  refresh_token TEXT,
  id_token TEXT,
  access_token_expires_at TEXT,
  refresh_token_expires_at TEXT,
  scope TEXT,
  password TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (provider_id, account_id)
);

CREATE INDEX idx_auth_accounts_user ON auth_accounts(user_id);

CREATE TABLE auth_verifications (
  id TEXT PRIMARY KEY,
  identifier TEXT NOT NULL,
  value TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_auth_verifications_identifier ON auth_verifications(identifier);

CREATE TABLE passkeys (
  id TEXT PRIMARY KEY,
  name TEXT,
  public_key TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  credential_id TEXT NOT NULL UNIQUE,
  counter INTEGER NOT NULL DEFAULT 0,
  device_type TEXT NOT NULL,
  backed_up INTEGER NOT NULL DEFAULT 0 CHECK (backed_up IN (0, 1)),
  transports TEXT,
  created_at TEXT,
  aaguid TEXT
);

CREATE INDEX idx_passkeys_user ON passkeys(user_id);

CREATE TABLE desktop_auth_intents (
  id TEXT PRIMARY KEY,
  poll_token_hash TEXT NOT NULL,
  client_name TEXT NOT NULL,
  audience TEXT NOT NULL DEFAULT 'syntila.desktop.management' CHECK (audience IN ('syntila.desktop.management', 'syntila.profile-lab.management')),
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
  audience TEXT NOT NULL CHECK (audience IN ('syntila.desktop.management', 'syntila.profile-lab.management')),
  created_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  device_id TEXT
);

CREATE INDEX idx_desktop_human_sessions_user
  ON desktop_human_sessions(user_id, created_at DESC);

CREATE INDEX idx_desktop_human_sessions_device
  ON desktop_human_sessions(user_id, device_id)
  WHERE device_id IS NOT NULL AND revoked_at IS NULL;

CREATE TABLE auth_step_up_events (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  method TEXT NOT NULL CHECK (method IN ('passkey', 'totp')),
  created_at TEXT NOT NULL,
  consumed_at TEXT
);

CREATE TABLE auth_step_up_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL,
  method TEXT NOT NULL CHECK (method IN ('passkey', 'totp')),
  authenticated_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  UNIQUE (session_id)
);

CREATE TABLE auth_audit_events (
  id TEXT PRIMARY KEY,
  user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  session_id TEXT,
  action TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('success', 'failure', 'denied')),
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);

CREATE INDEX idx_auth_audit_events_user ON auth_audit_events(user_id, created_at);
CREATE INDEX idx_auth_audit_events_created ON auth_audit_events(created_at);
CREATE INDEX idx_auth_sessions_expires ON auth_sessions(expires_at);
CREATE INDEX idx_auth_step_up_events_user ON auth_step_up_events(user_id, created_at);
