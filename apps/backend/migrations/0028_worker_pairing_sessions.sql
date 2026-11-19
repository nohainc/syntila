-- Worker pairing, credentials and session fencing (ADR-034, phase P3). Additive only.
--
-- * worker_pairing_challenges: a single-use, expiring secret the owner hands to
--   an Agent ('pair' for the first credential, 'transfer' to move a paired
--   Worker to another host). Only a digest of the secret is stored.
-- * worker_credentials: the Agent's public key (Ed25519, raw, base64url). The
--   private key never leaves the host. One active credential per Worker; a key
--   cannot be active on two Workers (a copied installation is not a Worker).
-- * worker_auth_nonces: short-lived server nonces the Agent signs to prove it
--   holds the private key. Consumed atomically, so a replay is refused.
-- * worker_agent_sessions: ONE row per Worker, the current session. Connecting
--   increments session_epoch in the same statement that replaces the session,
--   which locks out the previous one. Acknowledgements and terminal results are
--   fenced against this row in the same UPDATE.
-- * worker_audit_log: pairing, rotation, revocation, transfer and connection
--   records. Written per event, never per heartbeat.

CREATE TABLE worker_pairing_challenges (
  id text PRIMARY KEY,
  worker_instance_id text NOT NULL REFERENCES worker_instances(id) ON DELETE CASCADE,
  owner_user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('pair', 'transfer')),
  secret_digest text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  consumed_credential_id text
);
CREATE INDEX worker_pairing_challenges_worker_idx ON worker_pairing_challenges (worker_instance_id, created_at);
CREATE INDEX worker_pairing_challenges_owner_idx ON worker_pairing_challenges (owner_user_id);

CREATE TABLE worker_credentials (
  id text PRIMARY KEY,
  worker_instance_id text NOT NULL REFERENCES worker_instances(id) ON DELETE CASCADE,
  public_key text NOT NULL CHECK (public_key ~ '^[A-Za-z0-9_-]{43}$'),
  key_fingerprint text NOT NULL CHECK (key_fingerprint ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  revoked_reason text CHECK (revoked_reason IS NULL OR revoked_reason IN ('rotated', 'transferred', 'revoked', 'worker_removed')),
  CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL))
);
CREATE INDEX worker_credentials_worker_idx ON worker_credentials (worker_instance_id, created_at);
CREATE UNIQUE INDEX worker_credentials_active_uq ON worker_credentials (worker_instance_id) WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX worker_credentials_active_key_uq ON worker_credentials (key_fingerprint) WHERE revoked_at IS NULL;

CREATE TABLE worker_auth_nonces (
  id text PRIMARY KEY,
  worker_instance_id text NOT NULL REFERENCES worker_instances(id) ON DELETE CASCADE,
  nonce text NOT NULL CHECK (length(nonce) BETWEEN 32 AND 128),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  used_at timestamptz
);
CREATE INDEX worker_auth_nonces_worker_idx ON worker_auth_nonces (worker_instance_id, expires_at);

CREATE TABLE worker_agent_sessions (
  worker_instance_id text PRIMARY KEY REFERENCES worker_instances(id) ON DELETE CASCADE,
  session_id text NOT NULL UNIQUE,
  session_epoch bigint NOT NULL CHECK (session_epoch >= 1),
  credential_id text NOT NULL REFERENCES worker_credentials(id) ON DELETE CASCADE,
  token_digest text NOT NULL,
  client_version text NOT NULL DEFAULT 'unknown' CHECK (length(client_version) <= 64),
  connected_at timestamptz NOT NULL DEFAULT now(),
  lease_expires_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  disconnected_at timestamptz,
  disconnect_reason text CHECK (disconnect_reason IS NULL OR disconnect_reason IN
    ('closed', 'lease_expired', 'superseded', 'credential_revoked', 'worker_removed')),
  CHECK ((disconnected_at IS NULL) = (disconnect_reason IS NULL))
);
CREATE INDEX worker_agent_sessions_credential_idx ON worker_agent_sessions (credential_id);
CREATE INDEX worker_agent_sessions_lease_idx ON worker_agent_sessions (lease_expires_at) WHERE disconnected_at IS NULL;

CREATE TABLE worker_audit_log (
  id text PRIMARY KEY,
  worker_instance_id text NOT NULL REFERENCES worker_instances(id) ON DELETE CASCADE,
  owner_user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  actor_type text NOT NULL CHECK (actor_type IN ('user', 'agent', 'system')),
  actor_id text NOT NULL,
  action text NOT NULL CHECK (length(action) BETWEEN 1 AND 80),
  details_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX worker_audit_log_worker_idx ON worker_audit_log (worker_instance_id, created_at);
CREATE INDEX worker_audit_log_owner_idx ON worker_audit_log (owner_user_id);

-- Removing a Worker (tombstone) closes its credential and session.
CREATE FUNCTION worker_instances_close_agent_fn() RETURNS trigger AS $$
BEGIN
  UPDATE worker_credentials SET revoked_at = now(), revoked_reason = 'worker_removed'
   WHERE worker_instance_id = NEW.id AND revoked_at IS NULL;
  UPDATE worker_agent_sessions SET disconnected_at = now(), disconnect_reason = 'worker_removed'
   WHERE worker_instance_id = NEW.id AND disconnected_at IS NULL;
  UPDATE worker_pairing_challenges SET expires_at = LEAST(expires_at, now())
   WHERE worker_instance_id = NEW.id AND consumed_at IS NULL;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER worker_instances_close_agent AFTER UPDATE OF revoked_at ON worker_instances
  FOR EACH ROW WHEN (OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL)
  EXECUTE FUNCTION worker_instances_close_agent_fn();
