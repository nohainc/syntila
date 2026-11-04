-- Custom Worker plugins (ADR-027, Syntila Plus).
--
-- Cloud stores metadata only: the account library entry, the manifest as
-- imported, its digest and a per-Workspace pin. Never an executable, a local
-- path, an environment value or a credential.

-- A plugin needs a catalog row because worker_assignments.worker_type_id
-- references worker_catalog. `origin` and `owner_user_id` keep it out of every
-- other account's catalog (readers filter on them).
ALTER TABLE worker_catalog ADD COLUMN origin TEXT NOT NULL DEFAULT 'official'
  CHECK (origin IN ('official', 'plugin'));
ALTER TABLE worker_catalog ADD COLUMN owner_user_id TEXT
  REFERENCES users(id) ON DELETE CASCADE;

-- SQLite cannot add a cross-column CHECK with ALTER TABLE, so the invariants
-- are triggers: plugin rows have an owner and a plugin-shaped ID; official
-- rows have no owner and may never use the reserved `plugin-` prefix.
CREATE TRIGGER worker_catalog_origin_invariants_insert
BEFORE INSERT ON worker_catalog
WHEN (NEW.origin = 'plugin') <> (NEW.owner_user_id IS NOT NULL)
  OR (NEW.origin = 'official' AND NEW.worker_type_id LIKE 'plugin-%')
  OR (NEW.origin = 'plugin'
      AND NEW.worker_type_id NOT GLOB
        'plugin-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]')
BEGIN
  SELECT RAISE(ABORT, 'invalid worker_catalog origin');
END;

CREATE TABLE account_worker_plugins (
  plugin_ref TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plugin_id TEXT NOT NULL CHECK (length(plugin_id) BETWEEN 1 AND 48),
  display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 128),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (owner_user_id, plugin_id)
);

CREATE INDEX idx_account_worker_plugins_owner
  ON account_worker_plugins(owner_user_id, created_at);

CREATE TABLE account_worker_plugin_versions (
  plugin_ref TEXT NOT NULL
    REFERENCES account_worker_plugins(plugin_ref) ON DELETE CASCADE,
  version TEXT NOT NULL CHECK (length(version) BETWEEN 5 AND 64),
  manifest_digest TEXT NOT NULL CHECK (
    length(manifest_digest) = 64 AND manifest_digest NOT GLOB '*[^0-9a-f]*'
  ),
  manifest_json TEXT NOT NULL CHECK (
    json_valid(manifest_json) AND length(manifest_json) <= 262144
  ),
  origin_json TEXT NOT NULL CHECK (json_valid(origin_json)),
  signer_json TEXT CHECK (signer_json IS NULL OR json_valid(signer_json)),
  created_at TEXT NOT NULL,
  PRIMARY KEY (plugin_ref, version)
);

-- One pin per Workspace and plugin. `intent` survives a plan lapse; whether the
-- plugin is effective is decided live from the owner's plan.
CREATE TABLE workspace_worker_plugin_enablements (
  workspace_id TEXT NOT NULL
    REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  plugin_ref TEXT NOT NULL
    REFERENCES account_worker_plugins(plugin_ref) ON DELETE CASCADE,
  version TEXT NOT NULL,
  manifest_digest TEXT NOT NULL CHECK (length(manifest_digest) = 64),
  consent_hash TEXT NOT NULL CHECK (length(consent_hash) = 64),
  intent TEXT NOT NULL CHECK (intent IN ('enabled', 'disabled')),
  shareable INTEGER NOT NULL DEFAULT 0 CHECK (shareable IN (0, 1)),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, plugin_ref),
  FOREIGN KEY (plugin_ref, version)
    REFERENCES account_worker_plugin_versions(plugin_ref, version)
);

-- The executor the Service reported for a plugin Worker (digests, isolation
-- tier). NULL for every official Worker.
ALTER TABLE workspace_worker_inventory ADD COLUMN executor_json TEXT
  CHECK (executor_json IS NULL OR json_valid(executor_json));
