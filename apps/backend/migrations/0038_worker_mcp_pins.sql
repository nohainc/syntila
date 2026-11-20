-- ADR-041: the exact MCP Worker (version and manifest digest) a Worker Instance
-- of a `plugin-<12 hex>` Type runs. The owner sets it; the Agent still refuses
-- anything its local allow list does not approve. A pin follows its Instance and
-- its library version, so removing either removes the pin.
CREATE TABLE worker_instance_mcp_pins (
  worker_instance_id text PRIMARY KEY REFERENCES worker_instances(id) ON DELETE CASCADE,
  plugin_ref text NOT NULL,
  version text NOT NULL,
  manifest_digest text NOT NULL CHECK (length(manifest_digest) = 64 AND manifest_digest !~ '[^0-9a-f]'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (plugin_ref, version) REFERENCES account_worker_plugin_versions(plugin_ref, version) ON DELETE CASCADE
);
CREATE INDEX worker_instance_mcp_pins_plugin_ref_version_fkidx ON worker_instance_mcp_pins (plugin_ref, version);
