-- Syntila initial PostgreSQL schema (generated from the final D1 schema, then reviewed).
-- Regenerate: python3 scripts/internal/d1-to-postgres-schema.py

CREATE TABLE users (
  id text PRIMARY KEY,
  email text NOT NULL UNIQUE,
  display_name text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deactivated')),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  avatar_url text,
  email_verified smallint NOT NULL DEFAULT 0 CHECK (email_verified IN (0, 1)),
  share_read_receipts smallint NOT NULL DEFAULT 1
  CHECK (share_read_receipts IN (0, 1))
);

CREATE TABLE auth_verifications (
  id text PRIMARY KEY,
  identifier text NOT NULL,
  value text NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE realtime_event_cursors (
  stream_kind text NOT NULL DEFAULT 'execution_workspace' CHECK (stream_kind IN ('execution_workspace', 'space', 'user')),
  stream_id text,
  workspace_id text,
  next_sequence bigint NOT NULL DEFAULT 0,
  CHECK (COALESCE(stream_id, workspace_id) IS NOT NULL)
);

CREATE TABLE realtime_events (
  event_id text PRIMARY KEY,
  stream_kind text NOT NULL DEFAULT 'execution_workspace' CHECK (stream_kind IN ('execution_workspace', 'space', 'user')),
  stream_id text,
  workspace_id text,
  thread_id text,
  space_id text,
  run_id text,
  task_id text,
  attempt_id text,
  assignment_id text,
  workspace_runtime_id text,
  sequence bigint NOT NULL,
  event_type text NOT NULL,
  payload_json text NOT NULL,
  idempotency_key text NOT NULL,
  occurred_at timestamptz NOT NULL,
  CHECK (COALESCE(stream_id, workspace_id) IS NOT NULL),
  CHECK ((stream_kind = 'execution_workspace' AND workspace_id IS NOT NULL AND (stream_id IS NULL OR stream_id = workspace_id)) OR
         (stream_kind <> 'execution_workspace' AND workspace_id IS NULL AND stream_id IS NOT NULL))
);

CREATE TABLE workspace_releases (
  version text PRIMARY KEY,
  channel text NOT NULL DEFAULT 'stable'
    CHECK (channel IN ('stable', 'beta', 'development')),
  min_supported_workspace_version text,
  supported_os_json text NOT NULL DEFAULT '["macos","linux","windows"]',
  supported_arch_json text NOT NULL DEFAULT '["arm64","x64"]',
  package_digest text NOT NULL,
  package_r2_key text NOT NULL,
  signature text NOT NULL,
  release_notes text,
  is_revoked smallint NOT NULL DEFAULT 0 CHECK (is_revoked IN (0, 1)),
  revoked_at timestamptz,
  revocation_reason text,
  created_at timestamptz NOT NULL,
  signing_key_id text
);

CREATE TABLE workspace_service_readiness (
  workspace_id text PRIMARY KEY,
  runtime_identity_id text NOT NULL,
  session_id text NOT NULL,
  sync_generation bigint NOT NULL DEFAULT 0,
  state text NOT NULL,
  ready_for_assignments bigint NOT NULL DEFAULT 0,
  source text NOT NULL DEFAULT 'service',
  reason text,
  updated_at timestamptz NOT NULL
);

CREATE TABLE account_execution_waiters (
  task_id text PRIMARY KEY,
  requester_user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  run_id text NOT NULL,
  work_request_id text,
  reason text NOT NULL CHECK (
    reason IN ('account_concurrency_limit', 'workspace_not_ready')
  ),
  enqueued_at timestamptz NOT NULL,
  heartbeat_at timestamptz NOT NULL
);

CREATE TABLE account_plans (
  user_id text PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  tier text NOT NULL CHECK (tier IN ('free', 'paid')),
  status text NOT NULL CHECK (status IN ('active', 'trialing', 'past_due', 'canceled')),
  source text NOT NULL CHECK (source IN ('manual', 'provider')),
  current_period_end timestamptz,
  provider_customer_id text,
  provider_subscription_id text,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE account_worker_plugins (
  plugin_ref text PRIMARY KEY,
  owner_user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plugin_id text NOT NULL CHECK (length(plugin_id) BETWEEN 1 AND 48),
  display_name text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 128),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (owner_user_id, plugin_id)
);

CREATE TABLE auth_accounts (
  id text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  account_id text NOT NULL,
  provider_id text NOT NULL,
  access_token text,
  refresh_token text,
  id_token text,
  access_token_expires_at timestamptz,
  refresh_token_expires_at timestamptz,
  scope text,
  password text,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (provider_id, account_id)
);

CREATE TABLE auth_audit_events (
  id text PRIMARY KEY,
  user_id text REFERENCES users(id) ON DELETE SET NULL,
  session_id text,
  action text NOT NULL,
  outcome text NOT NULL CHECK (outcome IN ('success', 'failure', 'denied')),
  details_json text NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL
);

CREATE TABLE auth_sessions (
  id text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  ip_address text,
  user_agent text
);

CREATE TABLE auth_step_up_events (
  id text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  method text NOT NULL CHECK (method IN ('passkey', 'totp')),
  created_at timestamptz NOT NULL,
  consumed_at timestamptz
);

CREATE TABLE auth_step_up_sessions (
  id text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_id text NOT NULL,
  method text NOT NULL CHECK (method IN ('passkey', 'totp')),
  authenticated_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  UNIQUE (session_id)
);

CREATE TABLE desktop_auth_intents (
  id text PRIMARY KEY,
  poll_token_hash text NOT NULL,
  client_name text NOT NULL,
  audience text NOT NULL DEFAULT 'syntila.desktop.management' CHECK (audience IN ('syntila.desktop.management', 'syntila.profile-lab.management')),
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  approved_at timestamptz,
  approved_user_id text REFERENCES users(id) ON DELETE CASCADE,
  claimed_at timestamptz,
  claimed_session_id text,
  denied_at timestamptz
);

CREATE TABLE desktop_human_sessions (
  id text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  audience text NOT NULL CHECK (audience IN ('syntila.desktop.management', 'syntila.profile-lab.management')),
  created_at timestamptz NOT NULL,
  last_used_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  device_id text
);

CREATE TABLE execution_workspaces (
  id text PRIMARY KEY,
  owner_user_id text NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  name text NOT NULL,
  status text NOT NULL DEFAULT 'offline' CHECK (
    status IN ('online', 'offline', 'busy', 'draining', 'revoked')
  ),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  parallel_slots bigint
  CHECK (parallel_slots IS NULL OR parallel_slots BETWEEN 1 AND 1024),
  space_ai_chat smallint NOT NULL DEFAULT 0
  CHECK (space_ai_chat IN (0, 1)),
  space_ai_work smallint NOT NULL DEFAULT 0
  CHECK (space_ai_work IN (0, 1)),
  UNIQUE (id, owner_user_id)
);

CREATE TABLE issue_report_groups (
  id text PRIMARY KEY,
  public_reference text NOT NULL UNIQUE,
  label text NOT NULL,
  fingerprint text,
  created_by_user_id text REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE mutation_receipts (
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  scope text NOT NULL,
  idempotency_key text NOT NULL,
  request_hash text NOT NULL,
  response_json text NOT NULL,
  response_status bigint NOT NULL CHECK (response_status BETWEEN 200 AND 299),
  created_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, scope, idempotency_key)
);

CREATE TABLE passkeys (
  id text PRIMARY KEY,
  name text,
  public_key text NOT NULL,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  credential_id text NOT NULL UNIQUE,
  counter bigint NOT NULL DEFAULT 0,
  device_type text NOT NULL,
  backed_up smallint NOT NULL DEFAULT 0 CHECK (backed_up IN (0, 1)),
  transports text,
  created_at timestamptz,
  aaguid text
);

CREATE TABLE people_relationships (
  user_low_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_high_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  established_at timestamptz NOT NULL,
  PRIMARY KEY (user_low_id, user_high_id),
  CHECK (user_low_id < user_high_id)
);

CREATE TABLE person_invitations (
  id text PRIMARY KEY,
  inviter_user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  invitee_user_id text REFERENCES users(id) ON DELETE CASCADE,
  email text,
  status text NOT NULL CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled', 'expired')),
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  accepted_by_user_id text REFERENCES users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL,
  CHECK (invitee_user_id IS NOT NULL OR email IS NOT NULL),
  CHECK (invitee_user_id IS NULL OR inviter_user_id <> invitee_user_id)
);

CREATE TABLE release_signing_key_revocations (
  key_id text PRIMARY KEY,
  revoked_at timestamptz NOT NULL,
  revoked_by_user_id text REFERENCES users(id) ON DELETE SET NULL,
  reason text NOT NULL
);

CREATE TABLE spaces (
  id text PRIMARY KEY,
  owner_user_id text NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  name text NOT NULL,
  description text,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  settings_json text NOT NULL DEFAULT '{}',
  kind text NOT NULL DEFAULT 'group' CHECK (kind IN ('group', 'direct'))
);

CREATE TABLE user_blocks (
  blocker_user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL,
  PRIMARY KEY (blocker_user_id, blocked_user_id),
  CHECK (blocker_user_id <> blocked_user_id)
);

CREATE TABLE user_file_reservations (
  id text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  size_bytes bigint NOT NULL CHECK (size_bytes >= 0),
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL
);

CREATE TABLE user_files (
  id text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  thread_id text,
  space_id text,
  name text NOT NULL,
  media_type text NOT NULL,
  size_bytes bigint NOT NULL CHECK (size_bytes >= 0),
  created_at timestamptz NOT NULL
);

CREATE TABLE user_notes (
  id text PRIMARY KEY,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title text NOT NULL DEFAULT '',
  body text NOT NULL DEFAULT '',
  thread_id text,
  space_id text,
  linked_title text,
  revision bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  linked_space_title text
);

CREATE TABLE user_pins (
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('space', 'thread')),
  target_id text NOT NULL,
  pinned_at timestamptz NOT NULL,
  "position" bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, kind, target_id)
);

CREATE TABLE worker_catalog (
  worker_type_id text PRIMARY KEY,
  display_name text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 128),
  description text NOT NULL DEFAULT '',
  lifecycle_state text NOT NULL DEFAULT 'active'
    CHECK (lifecycle_state IN ('active', 'retired')),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  engine_family text NOT NULL DEFAULT 'cli' CHECK (engine_family = 'cli'),
  visibility_state text NOT NULL DEFAULT 'visible' CHECK (
    visibility_state IN ('hidden', 'visible')
  ),
  release_stage text NOT NULL DEFAULT 'stable' CHECK (
    release_stage IN ('testing', 'beta', 'stable')
  ),
  sort_order bigint NOT NULL DEFAULT 100 CHECK (
    sort_order >= 0 AND sort_order <= 10000
  ),
  profile_definition_id text,
  provider_tool_name text,
  origin text NOT NULL DEFAULT 'official'
  CHECK (origin IN ('official', 'plugin')),
  owner_user_id text
  REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE account_worker_plugin_versions (
  plugin_ref text NOT NULL
    REFERENCES account_worker_plugins(plugin_ref) ON DELETE CASCADE,
  version text NOT NULL CHECK (length(version) BETWEEN 5 AND 64),
  manifest_digest text NOT NULL CHECK (
    length(manifest_digest) = 64 AND manifest_digest !~ '^.*[^0-9a-f].*$'
  ),
  manifest_json text NOT NULL CHECK (
    (manifest_json IS JSON) AND length(manifest_json) <= 262144
  ),
  origin_json text NOT NULL CHECK ((origin_json IS JSON)),
  signer_json text CHECK (signer_json IS NULL OR (signer_json IS JSON)),
  created_at timestamptz NOT NULL,
  PRIMARY KEY (plugin_ref, version)
);

CREATE TABLE user_workflow_configurations (
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  workflow_id text NOT NULL,
  schema_version bigint NOT NULL CHECK (schema_version = 1),
  configuration_json text NOT NULL CHECK ((configuration_json IS JSON)),
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, workspace_id, workflow_id)
);

CREATE TABLE user_workflow_defaults (
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  workflow_id text NOT NULL DEFAULT 'chat',
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, workspace_id)
);

CREATE TABLE user_workflow_settings (
  user_id text PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  workspace_id text REFERENCES execution_workspaces(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE workspace_allowed_folders (
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  folder_id text NOT NULL,
  display_name text NOT NULL,
  status text NOT NULL CHECK (status IN ('available','read_only','denied','missing')),
  checked_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, folder_id)
);

CREATE TABLE workspace_audit_log (
  id text PRIMARY KEY,
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  actor_type text NOT NULL CHECK (actor_type IN ('user', 'workspace', 'worker', 'system')),
  actor_id text NOT NULL,
  action text NOT NULL,
  target_type text NOT NULL,
  target_id text NOT NULL,
  details_json text NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL
);

CREATE TABLE workspace_installations (
  installation_id text PRIMARY KEY,
  owner_user_id text NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  status text NOT NULL CHECK (status IN ('active', 'released')),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  released_at timestamptz,
  CHECK (
    (status = 'active' AND released_at IS NULL)
    OR (status = 'released' AND released_at IS NOT NULL)
  )
);

CREATE TABLE workspace_invitations (
  id text PRIMARY KEY,
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  email text NOT NULL,
  token_hash text NOT NULL UNIQUE,
  invited_by_user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'accepted', 'expired', 'revoked')
  ),
  expires_at timestamptz NOT NULL,
  accepted_by_user_id text REFERENCES users(id) ON DELETE SET NULL,
  accepted_at timestamptz,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE workspace_member_access (
  workspace_id text PRIMARY KEY REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  policy_json text NOT NULL CHECK ((policy_json IS JSON)),
  updated_at timestamptz NOT NULL
);

CREATE TABLE workspace_member_overrides (
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  policy_json text NOT NULL CHECK ((policy_json IS JSON)),
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, user_id)
);

CREATE TABLE workspace_person_grants (
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  granted_by_user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  max_concurrent_requests bigint NOT NULL DEFAULT 1
  CHECK (max_concurrent_requests BETWEEN 1 AND 10),
  max_run_seconds_per_month bigint
  CHECK (max_run_seconds_per_month IS NULL OR max_run_seconds_per_month > 0),
  PRIMARY KEY (workspace_id, user_id)
);

CREATE TABLE workspace_runtime_facts (
  workspace_id text PRIMARY KEY REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  platform text,
  architecture text,
  hostname text,
  app_version text,
  runtime_capabilities_json text NOT NULL DEFAULT '[]',
  updated_at timestamptz NOT NULL
);

CREATE TABLE workspace_runtime_identities (
  id text PRIMARY KEY,
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  credential_token_hash text NOT NULL,
  installation_id text,
  created_at timestamptz NOT NULL,
  revoked_at timestamptz,
  CHECK (installation_id IS NOT NULL OR revoked_at IS NOT NULL)
);

CREATE TABLE workspace_worker_inventory (
  worker_id text PRIMARY KEY,
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  owner_user_id text NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  worker_type_id text NOT NULL,
  activation_state text NOT NULL CHECK (activation_state IN ('enabled', 'disabled')),
  readiness_state text NOT NULL CHECK (readiness_state IN (
    'not_probed', 'ready', 'setup_required', 'sign_in_required',
    'worker_runtime_unavailable', 'test_failed'
  )),
  readiness_issue_code text,
  provider_tool_name text,
  provider_tool_version text,
  local_concurrency_limit bigint NOT NULL CHECK (local_concurrency_limit BETWEEN 1 AND 1024),
  revision bigint NOT NULL CHECK (revision > 0),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL,
  engine_version text,
  profile_definition_id text,
  profile_release_version bigint CHECK (
    profile_release_version IS NULL OR profile_release_version > 0
  ),
  model_catalog_json text CHECK (model_catalog_json IS NULL OR (model_catalog_json IS JSON)),
  executor_json text
  CHECK (executor_json IS NULL OR (executor_json IS JSON)),
  FOREIGN KEY (workspace_id, owner_user_id)
    REFERENCES execution_workspaces(id, owner_user_id)
);

CREATE TABLE workspace_worker_preferences (
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  preferences_json text NOT NULL CHECK ((preferences_json IS JSON)),
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, workspace_id)
);

CREATE TABLE issue_reports (
  id text PRIMARY KEY,
  public_reference text NOT NULL UNIQUE,
  reporter_user_id text REFERENCES users(id) ON DELETE SET NULL,
  workspace_id text REFERENCES execution_workspaces(id) ON DELETE SET NULL,
  request_id text NOT NULL,
  assignment_id text,
  attempt_key text NOT NULL,
  component text NOT NULL,
  error_code text NOT NULL,
  failure_stage text NOT NULL,
  fingerprint text NOT NULL,
  status text NOT NULL CHECK (status IN ('open', 'investigating', 'resolved', 'dismissed')),
  diagnostic_state text NOT NULL CHECK (diagnostic_state IN ('complete', 'partial', 'unavailable')),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  worker_type_id text,
  model_id text,
  effort text,
  engine_version text,
  profile_definition_id text,
  profile_release_version bigint,
  provider_tool_version text,
  application_version text,
  incident_group_id text REFERENCES issue_report_groups(id) ON DELETE SET NULL,
  UNIQUE (reporter_user_id, attempt_key)
);

CREATE TABLE direct_space_user_state (
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  hidden smallint NOT NULL DEFAULT 0 CHECK (hidden IN (0, 1)),
  last_opened_at timestamptz,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  personal_name text,
  PRIMARY KEY (space_id, user_id)
);

CREATE TABLE person_connections (
  user_low_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_high_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status text NOT NULL CHECK (status IN ('connected', 'disconnected')),
  established_at timestamptz NOT NULL,
  disconnected_at timestamptz,
  direct_space_id text REFERENCES spaces(id) ON DELETE SET NULL,
  PRIMARY KEY (user_low_id, user_high_id),
  CHECK (user_low_id < user_high_id)
);

CREATE TABLE space_audit_log (
  id text PRIMARY KEY,
  space_id text REFERENCES spaces(id) ON DELETE CASCADE,
  actor_type text NOT NULL CHECK (actor_type IN ('user', 'workspace_runtime', 'worker', 'system')),
  actor_id text NOT NULL,
  action text NOT NULL,
  target_type text NOT NULL,
  target_id text NOT NULL,
  details_json text NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL
);

CREATE TABLE space_invitations (
  id text PRIMARY KEY,
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  email text NOT NULL,
  "role" text NOT NULL CHECK (role IN ('collaborator', 'viewer')),
  token_hash text NOT NULL UNIQUE,
  invited_by_user_id text NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'accepted', 'declined', 'expired', 'revoked')
  ),
  expires_at timestamptz NOT NULL,
  accepted_by_user_id text REFERENCES users(id) ON DELETE SET NULL,
  accepted_at timestamptz,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  invitee_user_id text REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE space_memberships (
  id text PRIMARY KEY,
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  "role" text NOT NULL CHECK (role IN ('owner', 'collaborator', 'viewer')),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (space_id, user_id)
);

CREATE TABLE space_workflow_configurations (
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  workflow_id text NOT NULL,
  schema_version bigint NOT NULL CHECK (schema_version = 1),
  configuration_json text NOT NULL CHECK ((configuration_json IS JSON)),
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (space_id, workflow_id)
);

CREATE TABLE space_workflow_defaults (
  space_id text PRIMARY KEY REFERENCES spaces(id) ON DELETE CASCADE,
  workflow_id text NOT NULL DEFAULT 'chat',
  updated_at timestamptz NOT NULL
);

CREATE TABLE space_workflow_settings (
  space_id text PRIMARY KEY REFERENCES spaces(id) ON DELETE CASCADE,
  workspace_id text REFERENCES execution_workspaces(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE support_spaces (
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  support_user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  space_id text NOT NULL UNIQUE REFERENCES spaces(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, support_user_id),
  CHECK (user_id <> support_user_id)
);

CREATE TABLE threads (
  id text PRIMARY KEY,
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  name text NOT NULL,
  status text NOT NULL CHECK (status IN ('active', 'paused', 'blocked', 'completed', 'archived')),
  access_policy_json text NOT NULL DEFAULT '{}',
  lead_user_id text NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  work_session_generation bigint NOT NULL DEFAULT 0,
  lease_fence_counter bigint NOT NULL DEFAULT 0
  CHECK (lease_fence_counter >= 0),
  metadata_json text NOT NULL DEFAULT '{}',
  ai_history_cleared_at timestamptz,
  has_other_contributions smallint NOT NULL DEFAULT 0
  CHECK (has_other_contributions IN (0, 1)),
  ai_context_generation bigint NOT NULL DEFAULT 0,
  is_general smallint NOT NULL DEFAULT 0 CHECK (is_general IN (0, 1))
);

CREATE TABLE workspace_space_grants (
  id text PRIMARY KEY,
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  workspace_id text NOT NULL,
  granted_by_user_id text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (
    status IN ('active', 'suspended', 'revoked', 'expired')
  ),
  allowed_worker_ids_json text NOT NULL DEFAULT '[]',
  allowed_permissions_json text NOT NULL DEFAULT '[]',
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  expires_at timestamptz,
  network_policy_json text NOT NULL DEFAULT '{"mode":"deny_all","allowedHosts":[]}',
  concurrency_json text NOT NULL DEFAULT '{"maxConcurrentAssignments":1}',
  UNIQUE (id, space_id, workspace_id),
  FOREIGN KEY (workspace_id, granted_by_user_id)
    REFERENCES execution_workspaces(id, owner_user_id)
);

CREATE TABLE worker_profile_history (
  worker_type_id text NOT NULL
    REFERENCES worker_catalog(worker_type_id) ON DELETE RESTRICT,
  revision bigint NOT NULL CHECK (revision >= 1),
  schema_version bigint NOT NULL CHECK (schema_version >= 1),
  profile_json text NOT NULL CHECK (
    (profile_json IS JSON)
    AND length(profile_json) <= 262144
    AND (profile_json::jsonb ->> 'schemaVersion') = schema_version::text
  ),
  digest text NOT NULL CHECK (
    length(digest) = 64
    AND digest !~ '^.*[^0-9a-f].*$'
  ),
  actor_user_id text REFERENCES users(id) ON DELETE SET NULL,
  published_at timestamptz NOT NULL,
  restoration_reason text,
  PRIMARY KEY (worker_type_id, revision)
);

CREATE TABLE worker_profiles (
  worker_type_id text PRIMARY KEY
    REFERENCES worker_catalog(worker_type_id) ON DELETE RESTRICT,
  schema_version bigint NOT NULL CHECK (schema_version >= 1),
  profile_json text NOT NULL CHECK (
    (profile_json IS JSON)
    AND length(profile_json) <= 262144
    AND (profile_json::jsonb ->> 'schemaVersion') = schema_version::text
  ),
  revision bigint NOT NULL DEFAULT 1 CHECK (revision >= 1),
  digest text NOT NULL CHECK (
    length(digest) = 64
    AND digest !~ '^.*[^0-9a-f].*$'
  ),
  updated_by_user_id text REFERENCES users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (worker_type_id, revision)
);

CREATE TABLE workspace_worker_plugin_enablements (
  workspace_id text NOT NULL
    REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  plugin_ref text NOT NULL
    REFERENCES account_worker_plugins(plugin_ref) ON DELETE CASCADE,
  version text NOT NULL,
  manifest_digest text NOT NULL CHECK (length(manifest_digest) = 64),
  consent_hash text NOT NULL CHECK (length(consent_hash) = 64),
  intent text NOT NULL CHECK (intent IN ('enabled', 'disabled')),
  shareable smallint NOT NULL DEFAULT 0 CHECK (shareable IN (0, 1)),
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, plugin_ref),
  FOREIGN KEY (plugin_ref, version)
    REFERENCES account_worker_plugin_versions(plugin_ref, version)
);

CREATE TABLE space_additional_folders (
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  workspace_id text NOT NULL,
  folder_id text NOT NULL,
  created_at timestamptz NOT NULL,
  PRIMARY KEY (space_id, folder_id),
  FOREIGN KEY (workspace_id, folder_id)
    REFERENCES workspace_allowed_folders(workspace_id, folder_id) ON DELETE CASCADE
);

CREATE TABLE workspace_sessions (
  id text PRIMARY KEY,
  workspace_id text NOT NULL
    REFERENCES execution_workspaces(id)
    ON DELETE CASCADE,
  runtime_identity_id text NOT NULL
    REFERENCES workspace_runtime_identities(id)
    ON DELETE CASCADE,
  client_version text NOT NULL,
  protocol_version text NOT NULL,
  ip_address text,
  connected_at timestamptz NOT NULL,
  last_heartbeat_at timestamptz NOT NULL,
  disconnected_at timestamptz
);

CREATE TABLE worker_scheduling (
  worker_id text PRIMARY KEY REFERENCES workspace_worker_inventory(worker_id) ON DELETE CASCADE,
  state text NOT NULL DEFAULT 'disabled' CHECK (state IN ('enabled', 'disabled', 'draining')),
  cloud_concurrency_limit bigint CHECK (cloud_concurrency_limit IS NULL OR cloud_concurrency_limit BETWEEN 1 AND 1024),
  updated_by_user_id text REFERENCES users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL,
  drain_requested_by_user_id text REFERENCES users(id) ON DELETE SET NULL,
  drain_requested_at timestamptz,
  drain_completed_at timestamptz
);

CREATE TABLE worker_scheduling_audit (
  id text PRIMARY KEY,
  worker_id text NOT NULL REFERENCES workspace_worker_inventory(worker_id) ON DELETE CASCADE,
  actor_user_id text REFERENCES users(id) ON DELETE SET NULL,
  action text NOT NULL CHECK (action IN ('enabled', 'disabled', 'drain_requested', 'drain_completed')),
  requested_at timestamptz NOT NULL,
  completed_at timestamptz,
  details_json text NOT NULL DEFAULT '{}'
);

CREATE TABLE issue_report_diagnostics (
  report_id text PRIMARY KEY REFERENCES issue_reports(id) ON DELETE CASCADE,
  schema_version bigint NOT NULL DEFAULT 1,
  diagnostic_json text NOT NULL CHECK ((diagnostic_json IS JSON)),
  bundle_key text,
  bundle_sha256 text,
  created_at timestamptz NOT NULL
);

CREATE TABLE issue_report_events (
  id text PRIMARY KEY,
  report_id text NOT NULL REFERENCES issue_reports(id) ON DELETE CASCADE,
  actor_user_id text REFERENCES users(id) ON DELETE SET NULL,
  event_type text NOT NULL,
  from_status text,
  to_status text,
  details_json text NOT NULL DEFAULT '{}' CHECK ((details_json IS JSON)),
  created_at timestamptz NOT NULL
);

CREATE TABLE conversations (
  id text PRIMARY KEY,
  thread_id text NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  workflow_id text NOT NULL CHECK (workflow_id IN ('chat', 'work')),
  workflow_version bigint NOT NULL CHECK (workflow_version > 0),
  conversation_revision bigint NOT NULL DEFAULT 0 CHECK (conversation_revision >= 0),
  context_revision bigint NOT NULL DEFAULT 0 CHECK (context_revision >= 0 AND context_revision <= conversation_revision),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  context_floor_sequence bigint NOT NULL DEFAULT 0,
  UNIQUE (thread_id, workflow_id)
);

CREATE TABLE direct_spaces (
  space_id text PRIMARY KEY REFERENCES spaces(id) ON DELETE CASCADE,
  user_low_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_high_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  general_thread_id text REFERENCES threads(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL,
  CHECK (user_low_id < user_high_id),
  UNIQUE (user_low_id, user_high_id)
);

CREATE TABLE discussion_messages (
  id text PRIMARY KEY,
  thread_id text NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  author_user_id text NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  body text NOT NULL,
  references_json text NOT NULL DEFAULT '[]',
  edited_at timestamptz,
  created_at timestamptz NOT NULL,
  kind text NOT NULL DEFAULT 'message'
  CHECK (kind IN ('message', 'ai_request', 'ai_answer')),
  work_request_id text,
  worker_display_name text,
  attachments_json text NOT NULL DEFAULT '[]',
  event_type text,
  reply_to_json text
);

CREATE TABLE thread_execution_policies (
  thread_id text PRIMARY KEY REFERENCES threads(id) ON DELETE CASCADE,
  mode text NOT NULL CHECK (mode IN ('stateless', 'stateful')),
  primary_workspace_id text REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  allowed_worker_type_ids_json text NOT NULL DEFAULT '[]',
  allowed_models_json text NOT NULL DEFAULT '[]'
);

CREATE TABLE thread_read_states (
  thread_id text NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  read_at timestamptz NOT NULL,
  PRIMARY KEY (thread_id, user_id)
);

CREATE TABLE thread_request_queue (
  id text PRIMARY KEY,
  thread_id text NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  author_user_id text NOT NULL,
  request_json text NOT NULL,
  "position" double precision NOT NULL,
  status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sending')),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE thread_request_queue_state (
  thread_id text PRIMARY KEY REFERENCES threads(id) ON DELETE CASCADE,
  paused_reason text NOT NULL CHECK (paused_reason IN ('user', 'failure')),
  paused_by_user_id text,
  failure_message text,
  updated_at timestamptz NOT NULL
);

CREATE TABLE thread_work_configs (
  thread_id text PRIMARY KEY REFERENCES threads(id) ON DELETE CASCADE,
  config_json text NOT NULL DEFAULT '{"defaultWorkflowId":"full_cycle","bindings":{}}',
  updated_by_user_id text REFERENCES users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE work_requests (
  id text PRIMARY KEY,
  thread_id text NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  requested_by_user_id text NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  mode text NOT NULL CHECK (mode IN ('stateless', 'stateful')),
  workflow_id text NOT NULL CHECK (
    workflow_id IN ('chat', 'direct', 'research', 'plan_implement', 'implement_verify', 'full_cycle')
  ),
  workflow_version bigint NOT NULL CHECK (workflow_version > 0),
  workflow_snapshot_json text NOT NULL,
  status text NOT NULL CHECK (
    status IN ('queued', 'running', 'waiting', 'completed', 'failed', 'cancelled')
  ),
  primary_workspace_id text REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  input_json text NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  snapshot_json text NOT NULL DEFAULT '{}',
  cancel_requested_at timestamptz,
  ai_context_generation bigint NOT NULL DEFAULT 0
);

CREATE TABLE conversation_history_entries (
  id text PRIMARY KEY DEFAULT ('history-' || replace(gen_random_uuid()::text, '-', '')),
  conversation_id text NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sequence bigint NOT NULL CHECK (TRUE AND sequence > 0),
  schema_version bigint NOT NULL DEFAULT 1 CHECK (schema_version = 1),
  kind text NOT NULL CHECK (kind IN ('user_message', 'worker_response', 'workflow_event', 'execution_event', 'artifact_event', 'context_event')),
  event_type text NOT NULL,
  actor_type text NOT NULL CHECK (actor_type IN ('user', 'worker', 'syntila')),
  actor_id text,
  work_request_id text,
  turn_id text,
  artifact_id text,
  source_id text NOT NULL,
  text text,
  metadata_json text NOT NULL DEFAULT '{}' CHECK ((metadata_json IS JSON) AND (metadata_json IS JSON OBJECT)),
  deduplication_key text,
  occurred_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (conversation_id, sequence),
  UNIQUE (conversation_id, deduplication_key),
  CHECK ((kind IN ('user_message', 'worker_response')) = (text IS NOT NULL)),
  CHECK (kind != 'worker_response' OR turn_id IS NOT NULL),
  CHECK (kind != 'artifact_event' OR artifact_id IS NOT NULL)
);

CREATE TABLE conversation_user_messages (
  id text PRIMARY KEY,
  conversation_id text NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  work_request_id text NOT NULL UNIQUE REFERENCES work_requests(id) ON DELETE CASCADE,
  author_user_id text NOT NULL,
  text text NOT NULL,
  created_at timestamptz NOT NULL,
  UNIQUE (id, conversation_id)
);

CREATE TABLE conversation_work_requests (
  conversation_id text NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  work_request_id text PRIMARY KEY REFERENCES work_requests(id) ON DELETE CASCADE,
  conversation_revision bigint NOT NULL CHECK (conversation_revision > 0),
  UNIQUE (conversation_id, conversation_revision)
);

CREATE TABLE runs (
  id text PRIMARY KEY,
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  thread_id text REFERENCES threads(id) ON DELETE SET NULL,
  work_request_id text REFERENCES work_requests(id) ON DELETE SET NULL,
  status text NOT NULL CHECK (
    status IN ('created', 'running', 'paused', 'completed', 'failed', 'cancelled')
  ),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  started_at timestamptz,
  finished_at timestamptz,
  workflow_instance_id text,
  policy_snapshot_json text NOT NULL DEFAULT '{}'
);

CREATE TABLE thread_runtime_leases (
  id text PRIMARY KEY,
  thread_id text NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  work_request_id text NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  fencing_token bigint NOT NULL CHECK (fencing_token > 0),
  status text NOT NULL CHECK (status IN ('active', 'released', 'expired')),
  acquired_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  released_at timestamptz,
  UNIQUE (thread_id, fencing_token)
);

CREATE TABLE user_notification_reads (
  user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  work_request_id text NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  read_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, work_request_id)
);

CREATE TABLE work_request_inputs (
  id text PRIMARY KEY,
  work_request_id text NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  thread_id text NOT NULL,
  workspace_id text NOT NULL,
  user_id text NOT NULL,
  "position" bigint NOT NULL CHECK (position >= 0),
  name text NOT NULL,
  media_type text NOT NULL,
  size_bytes bigint NOT NULL CHECK (size_bytes >= 0),
  content_digest text,
  preview_text text,
  preview_image text,
  state text NOT NULL CHECK (
    state IN ('awaiting_upload', 'uploaded', 'delivered', 'failed')
  ),
  upload_attempts bigint NOT NULL DEFAULT 0,
  delivery_attempts bigint NOT NULL DEFAULT 0,
  error_message text,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (work_request_id, position)
);

CREATE TABLE workflow_tasks (
  id text PRIMARY KEY,
  work_request_id text NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  step_kind text NOT NULL CHECK (
    step_kind IN ('chat', 'research', 'plan', 'implement', 'test', 'verify', 'synthesis', 'tool_call')
  ),
  execution_mode text NOT NULL CHECK (
    execution_mode IN ('stateless_read', 'stateful_thread')
  ),
  timeout_ms bigint NOT NULL CHECK (timeout_ms >= 1000),
  prompt_profile_version text NOT NULL,
  status text NOT NULL CHECK (
    status IN ('queued', 'running', 'waiting', 'completed', 'failed', 'cancelled')
  ),
  attempt bigint NOT NULL DEFAULT 0 CHECK (attempt >= 0),
  output_json text,
  error text,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  started_at timestamptz,
  finished_at timestamptz,
  step_instance_id text CHECK (
    step_instance_id IS NULL OR length(step_instance_id) BETWEEN 1 AND 64
  ),
  step_id text GENERATED ALWAYS AS (COALESCE(step_instance_id, step_kind)) STORED,
  UNIQUE (work_request_id, step_id)
);

CREATE TABLE conversation_workflow_runs (
  id text PRIMARY KEY,
  conversation_id text NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_message_id text NOT NULL,
  work_request_id text NOT NULL UNIQUE REFERENCES work_requests(id) ON DELETE CASCADE,
  workflow_id text NOT NULL,
  workflow_version bigint NOT NULL CHECK (workflow_version > 0),
  created_at timestamptz NOT NULL,
  started_at timestamptz,
  completed_at timestamptz,
  FOREIGN KEY (user_message_id, conversation_id) REFERENCES conversation_user_messages(id, conversation_id) ON DELETE CASCADE
);

CREATE TABLE worker_assignments (
  id text PRIMARY KEY,
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  run_id text REFERENCES runs(id) ON DELETE SET NULL,
  thread_id text REFERENCES threads(id) ON DELETE SET NULL,
  work_request_id text REFERENCES work_requests(id) ON DELETE SET NULL,
  execution_workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  runtime_identity_id text NOT NULL REFERENCES workspace_runtime_identities(id) ON DELETE RESTRICT,
  worker_type_id text NOT NULL REFERENCES worker_catalog(worker_type_id) ON DELETE RESTRICT,
  status text NOT NULL,
  input_json text NOT NULL DEFAULT '{}',
  output_json text,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  workspace_space_grant_id text REFERENCES workspace_space_grants(id) ON DELETE SET NULL,
  error_json text,
  requested_by_user_id text REFERENCES users(id) ON DELETE SET NULL,
  workspace_worker_id text,
  task_id text,
  attempt_id text,
  engine_version text,
  model text,
  config_json text NOT NULL DEFAULT '{}',
  effective_permissions_json text NOT NULL DEFAULT '[]',
  permission_snapshot_json text NOT NULL DEFAULT '{}',
  timeout_ms bigint,
  idempotency_key text,
  session_policy text NOT NULL DEFAULT 'stateless' CHECK (
    session_policy IN ('stateless', 'durable_session')
  ),
  queue_wait_timeout_ms bigint NOT NULL DEFAULT 120000,
  start_permit_required bigint NOT NULL DEFAULT 0,
  start_permit_issued_at timestamptz,
  dispatched_at timestamptz,
  acknowledged_at timestamptz,
  running_at timestamptz,
  command_payload_json text,
  startup_stage text,
  startup_stage_at timestamptz,
  startup_detail_json text,
  workflow_signaled_at timestamptz,
  workflow_signal_attempts bigint NOT NULL DEFAULT 0,
  engine_alive_at timestamptz,
  engine_missing_reports bigint NOT NULL DEFAULT 0,
  cloud_queue_reason text
  CHECK (cloud_queue_reason IN ('workspace_capacity', 'service_not_ready')),
  cloud_queue_since timestamptz
);

CREATE TABLE mcp_tool_calls (
  task_id text PRIMARY KEY REFERENCES workflow_tasks(id) ON DELETE CASCADE,
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  dispatch_key text NOT NULL UNIQUE,
  claimed_at timestamptz NOT NULL,
  state text CHECK (state IS NULL OR state IN ('completed', 'toolError', 'rejected', 'unknown')),
  code text,
  result_json text,
  completed_at timestamptz,
  CHECK ((state IS NULL) = (completed_at IS NULL)),
  CHECK (result_json IS NULL OR state IN ('completed', 'toolError'))
);

CREATE TABLE workflow_task_dependencies (
  task_id text NOT NULL REFERENCES workflow_tasks(id) ON DELETE CASCADE,
  depends_on_task_id text NOT NULL REFERENCES workflow_tasks(id) ON DELETE RESTRICT,
  PRIMARY KEY (task_id, depends_on_task_id),
  CHECK (task_id <> depends_on_task_id)
);

CREATE TABLE conversation_workflow_step_runs (
  id text PRIMARY KEY,
  workflow_run_id text NOT NULL REFERENCES conversation_workflow_runs(id) ON DELETE CASCADE,
  task_id text NOT NULL UNIQUE REFERENCES workflow_tasks(id) ON DELETE CASCADE,
  step_id text NOT NULL,
  "role" text NOT NULL,
  created_at timestamptz NOT NULL,
  UNIQUE (workflow_run_id, step_id)
);

CREATE TABLE artifacts (
  id text PRIMARY KEY,
  space_id text NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  run_id text REFERENCES runs(id) ON DELETE SET NULL,
  thread_id text REFERENCES threads(id) ON DELETE SET NULL,
  work_request_id text REFERENCES work_requests(id) ON DELETE SET NULL,
  assignment_id text REFERENCES worker_assignments(id) ON DELETE SET NULL,
  content_digest text NOT NULL,
  storage_key text NOT NULL,
  created_at timestamptz NOT NULL
);

CREATE TABLE worker_activity_history (
  history_id text PRIMARY KEY,
  assignment_id text NOT NULL REFERENCES worker_assignments(id) ON DELETE CASCADE,
  workspace_id text NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  attempt_id text NOT NULL,
  execution_id text NOT NULL,
  worker_id text NOT NULL,
  source_event_id text NOT NULL,
  provider_sequence bigint NOT NULL CHECK (provider_sequence > 0),
  event_type text NOT NULL CHECK (event_type IN (
    'execution.started',
    'model.started',
    'tool.started',
    'tool.completed',
    'tool.failed',
    'execution.completed',
    'execution.failed',
    'execution.cancelled'
  )),
  status text NOT NULL CHECK (status IN ('running', 'completed', 'failed', 'cancelled')),
  activity_id text,
  title text NOT NULL CHECK (length(title) BETWEEN 1 AND 256),
  details_json text NOT NULL DEFAULT '{}',
  occurred_at timestamptz NOT NULL,
  duration_ms bigint,
  tool_id text,
  tool_name text,
  UNIQUE (assignment_id, attempt_id, source_event_id),
  UNIQUE (assignment_id, attempt_id, provider_sequence)
);

CREATE TABLE conversation_turns (
  id text PRIMARY KEY,
  conversation_id text NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_message_id text NOT NULL,
  work_request_id text NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  assignment_id text NOT NULL UNIQUE REFERENCES worker_assignments(id) ON DELETE CASCADE,
  task_id text NOT NULL,
  step_kind text NOT NULL,
  workflow_id text NOT NULL,
  workflow_version bigint NOT NULL CHECK (workflow_version > 0),
  worker_id text NOT NULL,
  worker_type_id text NOT NULL,
  worker_display_name text NOT NULL,
  profile_id text NOT NULL,
  profile_version bigint NOT NULL CHECK (profile_version > 0),
  model_id text,
  effort text,
  worker_session_id text,
  base_context_revision bigint NOT NULL CHECK (base_context_revision >= 0),
  status text NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed', 'cancelled')),
  started_at timestamptz,
  completed_at timestamptz,
  result_text text,
  created_at timestamptz NOT NULL,
  workflow_run_id text REFERENCES conversation_workflow_runs(id) ON DELETE CASCADE,
  workflow_step_run_id text REFERENCES conversation_workflow_step_runs(id) ON DELETE CASCADE,
  FOREIGN KEY (user_message_id, conversation_id) REFERENCES conversation_user_messages(id, conversation_id) ON DELETE CASCADE,
  CHECK ((status IN ('completed', 'failed', 'cancelled')) = (completed_at IS NOT NULL))
);

CREATE INDEX idx_account_execution_waiters_requester
  ON account_execution_waiters(requester_user_id, enqueued_at, task_id);
CREATE INDEX idx_account_worker_plugins_owner
  ON account_worker_plugins(owner_user_id, created_at);
CREATE INDEX idx_artifacts_work_request ON artifacts(work_request_id, created_at);
CREATE INDEX idx_assignments_work_request ON worker_assignments(work_request_id, created_at);
CREATE INDEX idx_assignments_workspace_worker
  ON worker_assignments(workspace_worker_id, status);
CREATE INDEX idx_auth_accounts_user ON auth_accounts(user_id);
CREATE INDEX idx_auth_sessions_user ON auth_sessions(user_id);
CREATE INDEX idx_conversation_history_request ON conversation_history_entries(work_request_id, sequence);
CREATE INDEX idx_conversation_history_turn ON conversation_history_entries(turn_id, kind);
CREATE INDEX idx_conversation_turns_history ON conversation_turns(conversation_id, created_at, id);
CREATE INDEX idx_conversation_turns_request ON conversation_turns(work_request_id, created_at, id);
CREATE INDEX idx_conversation_turns_step_run ON conversation_turns(workflow_step_run_id,created_at,id);
CREATE INDEX idx_conversation_turns_workflow_run ON conversation_turns(workflow_run_id,created_at,id);
CREATE INDEX idx_conversation_workflow_runs_message ON conversation_workflow_runs(user_message_id, created_at, id);
CREATE INDEX idx_desktop_auth_intents_expiry
  ON desktop_auth_intents(expires_at)
  WHERE claimed_at IS NULL AND denied_at IS NULL;
CREATE INDEX idx_desktop_human_sessions_device
  ON desktop_human_sessions(user_id, device_id)
  WHERE device_id IS NOT NULL AND revoked_at IS NULL;
CREATE INDEX idx_desktop_human_sessions_user
  ON desktop_human_sessions(user_id, created_at DESC);
CREATE INDEX idx_direct_space_user_state_user ON direct_space_user_state(user_id);
CREATE INDEX idx_direct_spaces_high ON direct_spaces(user_high_id, user_low_id);
CREATE INDEX idx_discussion_messages_thread ON discussion_messages(thread_id, created_at);
CREATE INDEX idx_issue_report_events_report
  ON issue_report_events(report_id, created_at, id);
CREATE INDEX idx_issue_report_groups_fingerprint
  ON issue_report_groups(fingerprint, updated_at DESC);
CREATE INDEX idx_issue_reports_fingerprint
  ON issue_reports(fingerprint, status, created_at DESC);
CREATE INDEX idx_issue_reports_incident_group
  ON issue_reports(incident_group_id, created_at DESC);
CREATE INDEX idx_issue_reports_investigation_filters
  ON issue_reports(status, component, error_code, worker_type_id, created_at DESC);
CREATE INDEX idx_issue_reports_reporter_created
  ON issue_reports(reporter_user_id, created_at DESC);
CREATE INDEX idx_issue_reports_request
  ON issue_reports(request_id, created_at DESC);
CREATE INDEX idx_passkeys_user ON passkeys(user_id);
CREATE INDEX idx_people_relationships_high ON people_relationships(user_high_id, user_low_id);
CREATE INDEX idx_person_connections_high ON person_connections(user_high_id, user_low_id);
CREATE INDEX idx_person_connections_space ON person_connections(direct_space_id);
CREATE INDEX idx_person_invitations_invitee ON person_invitations(invitee_user_id, status);
CREATE INDEX idx_person_invitations_inviter ON person_invitations(inviter_user_id, status);
CREATE UNIQUE INDEX idx_person_invitations_pending_email
  ON person_invitations (inviter_user_id, LOWER(email))
  WHERE status = 'pending' AND email IS NOT NULL;
CREATE UNIQUE INDEX idx_person_invitations_pending_pair
  ON person_invitations ((LEAST(inviter_user_id, invitee_user_id)), (GREATEST(inviter_user_id, invitee_user_id)))
  WHERE status = 'pending' AND invitee_user_id IS NOT NULL;
CREATE UNIQUE INDEX idx_realtime_event_cursors_stream
  ON realtime_event_cursors(stream_kind, COALESCE(stream_id, workspace_id));
CREATE INDEX idx_realtime_events_assignment_activity
  ON realtime_events(assignment_id, event_type, occurred_at, sequence);
CREATE UNIQUE INDEX idx_realtime_events_stream_idempotency
  ON realtime_events(stream_kind, COALESCE(stream_id, workspace_id), idempotency_key);
CREATE UNIQUE INDEX idx_realtime_events_stream_seq
  ON realtime_events(stream_kind, COALESCE(stream_id, workspace_id), sequence);
CREATE INDEX idx_realtime_events_stream_time
  ON realtime_events(stream_kind, COALESCE(stream_id, workspace_id), occurred_at);
CREATE INDEX idx_realtime_events_workspace_time
  ON realtime_events(workspace_id, occurred_at);
CREATE INDEX idx_runs_thread ON runs(thread_id, created_at);
CREATE UNIQUE INDEX idx_runs_workflow_instance
  ON runs(workflow_instance_id)
  WHERE workflow_instance_id IS NOT NULL;
CREATE UNIQUE INDEX idx_runtime_installation_active
  ON workspace_runtime_identities(installation_id)
  WHERE revoked_at IS NULL;
CREATE INDEX idx_space_audit_log_space ON space_audit_log(space_id, created_at);
CREATE INDEX idx_space_invitations_invitee ON space_invitations(invitee_user_id,status);
CREATE UNIQUE INDEX idx_space_invitations_pending_email ON space_invitations(space_id,LOWER(email)) WHERE status='pending';
CREATE UNIQUE INDEX idx_space_invitations_pending_user ON space_invitations(space_id,invitee_user_id)
WHERE status='pending' AND invitee_user_id IS NOT NULL;
CREATE INDEX idx_space_invitations_space ON space_invitations(space_id, status);
CREATE UNIQUE INDEX idx_space_one_owner
  ON space_memberships(space_id) WHERE role = 'owner';
CREATE INDEX idx_spaces_owner ON spaces(owner_user_id);
CREATE INDEX idx_support_spaces_support_user ON support_spaces(support_user_id);
CREATE UNIQUE INDEX idx_thread_one_active_runtime_lease
  ON thread_runtime_leases(thread_id) WHERE status = 'active';
CREATE INDEX idx_thread_request_queue_thread
  ON thread_request_queue(thread_id, position);
CREATE INDEX idx_thread_runtime_lease_request
  ON thread_runtime_leases(work_request_id, status);
CREATE INDEX idx_threads_space ON threads(space_id, status);
CREATE INDEX idx_user_blocks_blocked ON user_blocks(blocked_user_id);
CREATE INDEX idx_user_file_reservations_user
  ON user_file_reservations(user_id, expires_at);
CREATE INDEX idx_user_files_user ON user_files(user_id, created_at, size_bytes);
CREATE UNIQUE INDEX idx_user_notes_thread
  ON user_notes(user_id, thread_id) WHERE thread_id IS NOT NULL;
CREATE INDEX idx_user_notes_user ON user_notes(user_id, updated_at);
CREATE INDEX idx_work_request_inputs_workspace
  ON work_request_inputs(workspace_id, state, created_at);
CREATE INDEX idx_work_requests_thread
  ON work_requests(thread_id, status, created_at);
CREATE INDEX idx_worker_activity_history_assignment
  ON worker_activity_history(assignment_id, occurred_at, provider_sequence);
CREATE INDEX idx_worker_activity_history_workspace
  ON worker_activity_history(workspace_id, occurred_at);
CREATE INDEX idx_worker_assignments_requester
  ON worker_assignments(requested_by_user_id, created_at);
CREATE INDEX idx_worker_assignments_requester_active
  ON worker_assignments(requested_by_user_id)
  WHERE status IN ('created', 'dispatched', 'acknowledged', 'running',
                   'revocation_pending', 'reconciling');
CREATE INDEX idx_worker_assignments_unsignaled_terminal
  ON worker_assignments(updated_at)
  WHERE workflow_signaled_at IS NULL
    AND status IN ('completed', 'failed', 'cancelled', 'timed_out');
CREATE INDEX idx_worker_profile_history_worker_time
  ON worker_profile_history(worker_type_id, published_at DESC, revision DESC);
CREATE INDEX idx_worker_scheduling_audit_worker
  ON worker_scheduling_audit(worker_id, requested_at);
CREATE INDEX idx_workflow_step_runs_run ON conversation_workflow_step_runs(workflow_run_id,created_at,id);
CREATE INDEX idx_workflow_tasks_request
  ON workflow_tasks(work_request_id, status, created_at);
CREATE INDEX idx_workspace_audit_time
  ON workspace_audit_log(workspace_id, created_at DESC);
CREATE UNIQUE INDEX idx_workspace_installations_active_workspace
  ON workspace_installations(workspace_id)
  WHERE status = 'active';
CREATE INDEX idx_workspace_invitations_email ON workspace_invitations(LOWER(email), status);
CREATE UNIQUE INDEX idx_workspace_invitations_pending_email
  ON workspace_invitations(workspace_id, LOWER(email)) WHERE status = 'pending';
CREATE INDEX idx_workspace_runtime_active
  ON workspace_runtime_identities(workspace_id, revoked_at);
CREATE UNIQUE INDEX idx_workspace_runtime_identities_active_workspace
  ON workspace_runtime_identities(workspace_id)
  WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX idx_workspace_runtime_token_hash
  ON workspace_runtime_identities(credential_token_hash);
CREATE INDEX idx_workspace_sessions_workspace
  ON workspace_sessions(workspace_id);
CREATE INDEX idx_workspace_space_grants_space
  ON workspace_space_grants(space_id, status);
CREATE INDEX idx_workspace_worker_inventory_owner
  ON workspace_worker_inventory(owner_user_id, updated_at);
CREATE INDEX idx_workspace_worker_inventory_workspace
  ON workspace_worker_inventory(workspace_id, worker_type_id);
CREATE INDEX idx_workspaces_owner ON execution_workspaces(owner_user_id);
CREATE INDEX space_additional_folders_workspace
  ON space_additional_folders(workspace_id, folder_id);
-- Triggers translated from D1 (generated by scripts/internal/d1-to-postgres-schema.py, reviewed).
CREATE FUNCTION syntila_iso(ts timestamptz) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') $$;

CREATE FUNCTION establish_people_on_membership_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO people_relationships(user_low_id,user_high_id,established_at)
  SELECT LEAST(NEW.user_id, m.user_id),GREATEST(NEW.user_id, m.user_id),NEW.created_at
  FROM space_memberships m WHERE m.space_id=NEW.space_id AND m.user_id<>NEW.user_id
  ON CONFLICT(user_low_id,user_high_id) DO NOTHING;
  RETURN NEW;
END $$;
CREATE TRIGGER establish_people_on_membership AFTER INSERT ON space_memberships FOR EACH ROW EXECUTE FUNCTION establish_people_on_membership_fn();

CREATE FUNCTION trg_assignment_context_snapshot_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM conversation_turns WHERE assignment_id=OLD.id)
  AND (OLD.permission_snapshot_json::jsonb #>> '{contextSnapshot}')
      IS DISTINCT FROM (NEW.permission_snapshot_json::jsonb #>> '{contextSnapshot}') THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Assignment context snapshot is immutable';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_assignment_context_snapshot_immutable BEFORE UPDATE OF permission_snapshot_json ON worker_assignments FOR EACH ROW EXECUTE FUNCTION trg_assignment_context_snapshot_immutable_fn();

CREATE FUNCTION trg_assignment_execution_selection_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.model IS DISTINCT FROM OLD.model
  OR NEW.worker_type_id IS DISTINCT FROM OLD.worker_type_id
  OR NEW.workspace_worker_id IS DISTINCT FROM OLD.workspace_worker_id
  OR (NEW.permission_snapshot_json::jsonb #>> '{executionSelection}') IS DISTINCT FROM (OLD.permission_snapshot_json::jsonb #>> '{executionSelection}')
  OR (NEW.permission_snapshot_json::jsonb #>> '{workerDisplayName}') IS DISTINCT FROM (OLD.permission_snapshot_json::jsonb #>> '{workerDisplayName}')
  OR (NEW.permission_snapshot_json::jsonb #>> '{reasoningEffort}') IS DISTINCT FROM (OLD.permission_snapshot_json::jsonb #>> '{reasoningEffort}')
  OR (NEW.permission_snapshot_json::jsonb #>> '{profileDefinitionId}') IS DISTINCT FROM (OLD.permission_snapshot_json::jsonb #>> '{profileDefinitionId}')
  OR (NEW.permission_snapshot_json::jsonb #>> '{profileReleaseVersion}')::bigint IS DISTINCT FROM (OLD.permission_snapshot_json::jsonb #>> '{profileReleaseVersion}')::bigint THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Assignment execution selection is immutable';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_assignment_execution_selection_immutable BEFORE UPDATE OF permission_snapshot_json, model, worker_type_id, workspace_worker_id ON worker_assignments FOR EACH ROW EXECUTE FUNCTION trg_assignment_execution_selection_immutable_fn();

CREATE FUNCTION trg_conversation_history_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Canonical Conversation history is append-only';
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_history_immutable BEFORE UPDATE ON conversation_history_entries FOR EACH ROW EXECUTE FUNCTION trg_conversation_history_immutable_fn();

CREATE FUNCTION trg_conversation_history_no_delete_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM conversations WHERE id = OLD.conversation_id) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Canonical Conversation history cannot be deleted independently';
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER trg_conversation_history_no_delete BEFORE DELETE ON conversation_history_entries FOR EACH ROW EXECUTE FUNCTION trg_conversation_history_no_delete_fn();

CREATE FUNCTION trg_conversation_identity_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.id IS DISTINCT FROM NEW.id OR OLD.thread_id IS DISTINCT FROM NEW.thread_id
  OR OLD.workflow_id IS DISTINCT FROM NEW.workflow_id OR OLD.workflow_version IS DISTINCT FROM NEW.workflow_version THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Conversation identity and Workflow are immutable';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_identity_immutable BEFORE UPDATE OF id, thread_id, workflow_id, workflow_version ON conversations FOR EACH ROW EXECUTE FUNCTION trg_conversation_identity_immutable_fn();

CREATE FUNCTION trg_conversation_request_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Conversation request associations are immutable';
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_request_immutable BEFORE UPDATE ON conversation_work_requests FOR EACH ROW EXECUTE FUNCTION trg_conversation_request_immutable_fn();

CREATE FUNCTION trg_conversation_revisions_monotonic_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.conversation_revision < OLD.conversation_revision OR NEW.context_revision < OLD.context_revision THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Conversation revisions cannot decrease';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_revisions_monotonic BEFORE UPDATE OF conversation_revision, context_revision ON conversations FOR EACH ROW EXECUTE FUNCTION trg_conversation_revisions_monotonic_fn();

CREATE FUNCTION trg_conversation_turn_assignment_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO conversation_turns (
    id, conversation_id, user_message_id, work_request_id, assignment_id, workflow_run_id, workflow_step_run_id,
    task_id, step_kind, workflow_id, workflow_version,
    worker_id, worker_type_id, worker_display_name, profile_id, profile_version,
    model_id, effort, worker_session_id, base_context_revision, status, created_at
  )
  SELECT 'turn-' || NEW.id, c.id, m.id, wr.id, NEW.id, wfr.id, wsr.id,
    wt.id, wt.step_kind, wr.workflow_id, wr.workflow_version,
    NEW.workspace_worker_id, NEW.worker_type_id,
    COALESCE((NEW.permission_snapshot_json::jsonb #>> '{workerDisplayName}'), NEW.worker_type_id),
    (NEW.permission_snapshot_json::jsonb #>> '{profileDefinitionId}'),
    (NEW.permission_snapshot_json::jsonb #>> '{profileReleaseVersion}')::bigint,
    NEW.model, (NEW.permission_snapshot_json::jsonb #>> '{reasoningEffort}'),
    CASE WHEN NEW.session_policy = 'durable_session' THEN (NEW.permission_snapshot_json::jsonb #>> '{workerSessionId}') ELSE NULL END,
    COALESCE((NEW.permission_snapshot_json::jsonb #>> '{baseContextRevision}')::bigint, cr.conversation_revision - 1), 'queued', NEW.created_at
  FROM workflow_tasks wt
  JOIN work_requests wr ON wr.id = wt.work_request_id
  JOIN conversation_work_requests cr ON cr.work_request_id = wr.id
  JOIN conversations c ON c.id = cr.conversation_id
  JOIN conversation_user_messages m ON m.work_request_id = wr.id
  JOIN conversation_workflow_runs wfr ON wfr.work_request_id = wr.id
  JOIN conversation_workflow_step_runs wsr ON wsr.task_id = wt.id AND wsr.workflow_run_id = wfr.id
  WHERE wt.id = NEW.task_id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_turn_assignment_insert AFTER INSERT ON worker_assignments FOR EACH ROW EXECUTE FUNCTION trg_conversation_turn_assignment_insert_fn();

CREATE FUNCTION trg_conversation_turn_assignment_status_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    UPDATE conversation_turns SET
    status = CASE WHEN NEW.status IN ('timed_out', 'lost') THEN 'failed'
      WHEN NEW.status IN ('completed', 'failed', 'cancelled', 'running') THEN NEW.status ELSE status END,
    started_at = COALESCE(started_at, NEW.running_at,
      CASE WHEN NEW.status = 'running' THEN NEW.updated_at END),
    completed_at = CASE WHEN NEW.status IN ('completed', 'failed', 'cancelled', 'timed_out', 'lost')
      THEN NEW.updated_at ELSE completed_at END,
    result_text = CASE WHEN NEW.status = 'completed' THEN (NEW.output_json::jsonb #>> '{output,text}') ELSE result_text END
  WHERE assignment_id = NEW.id AND status IN ('queued', 'running');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_turn_assignment_status AFTER UPDATE OF status ON worker_assignments FOR EACH ROW EXECUTE FUNCTION trg_conversation_turn_assignment_status_fn();

CREATE FUNCTION trg_conversation_turn_context_boundary_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF FALSE OR NOT EXISTS (
  SELECT 1 FROM conversation_work_requests cr
  WHERE cr.conversation_id=NEW.conversation_id
    AND cr.work_request_id=NEW.work_request_id
    AND NEW.base_context_revision=cr.conversation_revision-1) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Worker turn context revision must match its request boundary';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_turn_context_boundary_insert BEFORE INSERT ON conversation_turns FOR EACH ROW EXECUTE FUNCTION trg_conversation_turn_context_boundary_insert_fn();

CREATE FUNCTION trg_conversation_turn_identity_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.id IS DISTINCT FROM NEW.id OR OLD.conversation_id IS DISTINCT FROM NEW.conversation_id
  OR OLD.user_message_id IS DISTINCT FROM NEW.user_message_id OR OLD.work_request_id IS DISTINCT FROM NEW.work_request_id
  OR OLD.assignment_id IS DISTINCT FROM NEW.assignment_id OR OLD.task_id IS DISTINCT FROM NEW.task_id OR OLD.step_kind IS DISTINCT FROM NEW.step_kind
  OR OLD.workflow_id IS DISTINCT FROM NEW.workflow_id OR OLD.workflow_version IS DISTINCT FROM NEW.workflow_version
  OR OLD.worker_id IS DISTINCT FROM NEW.worker_id OR OLD.worker_type_id IS DISTINCT FROM NEW.worker_type_id
  OR OLD.worker_display_name IS DISTINCT FROM NEW.worker_display_name
  OR OLD.profile_id IS DISTINCT FROM NEW.profile_id OR OLD.profile_version IS DISTINCT FROM NEW.profile_version
  OR OLD.model_id IS DISTINCT FROM NEW.model_id OR OLD.effort IS DISTINCT FROM NEW.effort
  OR OLD.worker_session_id IS DISTINCT FROM NEW.worker_session_id OR OLD.base_context_revision IS DISTINCT FROM NEW.base_context_revision
  OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Conversation turn execution attribution is immutable';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_turn_identity_immutable BEFORE UPDATE ON conversation_turns FOR EACH ROW EXECUTE FUNCTION trg_conversation_turn_identity_immutable_fn();

CREATE FUNCTION trg_conversation_turn_lifecycle_guard_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (OLD.status IN ('completed', 'failed', 'cancelled') AND
  (OLD.status IS DISTINCT FROM NEW.status OR OLD.started_at IS DISTINCT FROM NEW.started_at
   OR OLD.completed_at IS DISTINCT FROM NEW.completed_at OR OLD.result_text IS DISTINCT FROM NEW.result_text))
 OR (OLD.status = 'running' AND NEW.status = 'queued')
 OR (OLD.started_at IS NOT NULL AND OLD.started_at IS DISTINCT FROM NEW.started_at) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Conversation turn lifecycle cannot regress or rewrite terminal evidence';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_turn_lifecycle_guard BEFORE UPDATE ON conversation_turns FOR EACH ROW EXECUTE FUNCTION trg_conversation_turn_lifecycle_guard_fn();

CREATE FUNCTION trg_conversation_turn_step_run_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.workflow_step_run_id IS DISTINCT FROM NEW.workflow_step_run_id THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Worker turn Workflow Step Run is immutable';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_turn_step_run_immutable BEFORE UPDATE OF workflow_step_run_id ON conversation_turns FOR EACH ROW EXECUTE FUNCTION trg_conversation_turn_step_run_immutable_fn();

CREATE FUNCTION trg_conversation_turn_step_run_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.workflow_step_run_id IS NULL OR NOT EXISTS (SELECT 1 FROM conversation_workflow_step_runs s
 WHERE s.id=NEW.workflow_step_run_id AND s.workflow_run_id=NEW.workflow_run_id AND s.task_id=NEW.task_id) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Worker turn must belong to its scoped Workflow Step Run';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_turn_step_run_insert BEFORE INSERT ON conversation_turns FOR EACH ROW EXECUTE FUNCTION trg_conversation_turn_step_run_insert_fn();

CREATE FUNCTION trg_conversation_turn_workflow_run_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.workflow_run_id IS DISTINCT FROM NEW.workflow_run_id THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Worker turn Workflow Run is immutable';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_turn_workflow_run_immutable BEFORE UPDATE OF workflow_run_id ON conversation_turns FOR EACH ROW EXECUTE FUNCTION trg_conversation_turn_workflow_run_immutable_fn();

CREATE FUNCTION trg_conversation_turn_workflow_run_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.workflow_run_id IS NULL OR NOT EXISTS (
 SELECT 1 FROM conversation_workflow_runs r WHERE r.id=NEW.workflow_run_id
 AND r.conversation_id=NEW.conversation_id AND r.user_message_id=NEW.user_message_id
 AND r.work_request_id=NEW.work_request_id AND r.workflow_id=NEW.workflow_id AND r.workflow_version=NEW.workflow_version) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Worker turn must belong to its scoped Workflow Run';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_turn_workflow_run_insert BEFORE INSERT ON conversation_turns FOR EACH ROW EXECUTE FUNCTION trg_conversation_turn_workflow_run_insert_fn();

CREATE FUNCTION trg_conversation_user_message_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Conversation user messages are immutable';
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_user_message_immutable BEFORE UPDATE ON conversation_user_messages FOR EACH ROW EXECUTE FUNCTION trg_conversation_user_message_immutable_fn();

CREATE FUNCTION trg_conversation_user_message_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO conversation_user_messages(id, conversation_id, work_request_id, author_user_id, text, created_at)
  SELECT 'message-user-' || wr.id, NEW.conversation_id, wr.id, wr.requested_by_user_id,
    COALESCE((wr.input_json::jsonb #>> '{originalRequest}'), (wr.input_json::jsonb #>> '{request}'), ''), wr.created_at
  FROM work_requests wr WHERE wr.id = NEW.work_request_id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_user_message_insert AFTER INSERT ON conversation_work_requests FOR EACH ROW EXECUTE FUNCTION trg_conversation_user_message_insert_fn();

CREATE FUNCTION trg_conversation_workflow_run_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.id IS DISTINCT FROM NEW.id OR OLD.conversation_id IS DISTINCT FROM NEW.conversation_id
 OR OLD.user_message_id IS DISTINCT FROM NEW.user_message_id OR OLD.work_request_id IS DISTINCT FROM NEW.work_request_id
 OR OLD.workflow_id IS DISTINCT FROM NEW.workflow_id OR OLD.workflow_version IS DISTINCT FROM NEW.workflow_version OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Workflow Run identity is immutable';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_workflow_run_immutable BEFORE UPDATE ON conversation_workflow_runs FOR EACH ROW EXECUTE FUNCTION trg_conversation_workflow_run_immutable_fn();

CREATE FUNCTION trg_conversation_workflow_run_message_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO conversation_workflow_runs(id,conversation_id,user_message_id,work_request_id,workflow_id,workflow_version,created_at)
  SELECT 'workflow-run-' || wr.id,NEW.conversation_id,NEW.id,wr.id,wr.workflow_id,wr.workflow_version,wr.created_at
  FROM work_requests wr WHERE wr.id=NEW.work_request_id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_workflow_run_message_insert AFTER INSERT ON conversation_user_messages FOR EACH ROW EXECUTE FUNCTION trg_conversation_workflow_run_message_insert_fn();

CREATE FUNCTION trg_conversation_workflow_run_scope_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
 SELECT 1 FROM conversation_user_messages m JOIN work_requests wr ON wr.id=m.work_request_id
 WHERE m.id=NEW.user_message_id AND m.conversation_id=NEW.conversation_id
 AND wr.id=NEW.work_request_id AND wr.workflow_id=NEW.workflow_id AND wr.workflow_version=NEW.workflow_version) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Workflow Run must belong to its scoped user message';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_conversation_workflow_run_scope_insert BEFORE INSERT ON conversation_workflow_runs FOR EACH ROW EXECUTE FUNCTION trg_conversation_workflow_run_scope_insert_fn();

CREATE FUNCTION trg_history_artifact_created_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'artifact_event',
    'artifact.created',
    'syntila',
    NULL,
    cr.work_request_id,
    NULL,
    NEW.id,
    NEW.id,
    NULL,
    jsonb_build_object('contentDigest', NEW.content_digest)::text,
    NULL,
    NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = COALESCE(NEW.work_request_id, (SELECT wt.work_request_id FROM workflow_tasks wt JOIN worker_assignments wa ON wa.task_id = wt.id WHERE wa.id = NEW.assignment_id), (SELECT work_request_id FROM runs WHERE id = NEW.run_id));
  RETURN NEW;
END $$;
CREATE TRIGGER trg_history_artifact_created AFTER INSERT ON artifacts FOR EACH ROW EXECUTE FUNCTION trg_history_artifact_created_fn();

CREATE FUNCTION trg_history_artifact_removed_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'artifact_event',
    'artifact.removed',
    'syntila',
    NULL,
    cr.work_request_id,
    NULL,
    OLD.id,
    OLD.id,
    NULL,
    jsonb_build_object('contentDigest', OLD.content_digest)::text,
    NULL,
    now()
  FROM conversation_work_requests cr WHERE cr.work_request_id = COALESCE(OLD.work_request_id, (SELECT wt.work_request_id FROM workflow_tasks wt JOIN worker_assignments wa ON wa.task_id = wt.id WHERE wa.id = OLD.assignment_id), (SELECT work_request_id FROM runs WHERE id = OLD.run_id));
  RETURN OLD;
END $$;
CREATE TRIGGER trg_history_artifact_removed AFTER DELETE ON artifacts FOR EACH ROW EXECUTE FUNCTION trg_history_artifact_removed_fn();

CREATE FUNCTION trg_history_context_revision_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.context_revision > OLD.context_revision THEN
    PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.id), 0) + 1,
    'context_event',
    'context.revision_advanced',
    'syntila',
    NULL,
    NULL,
    NULL,
    NULL,
    NEW.id,
    NULL,
    jsonb_build_object('previousRevision', OLD.context_revision, 'contextRevision', NEW.context_revision)::text,
    NULL,
    NEW.updated_at;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_history_context_revision AFTER UPDATE OF context_revision ON conversations FOR EACH ROW EXECUTE FUNCTION trg_history_context_revision_fn();

CREATE FUNCTION trg_history_execution_created_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'execution_event',
    'execution.created',
    'syntila',
    NULL,
    NEW.work_request_id,
    NEW.id,
    NULL,
    NEW.id,
    NULL,
    jsonb_build_object('workerId', NEW.worker_id, 'workerTypeId', NEW.worker_type_id, 'workerDisplayName', NEW.worker_display_name, 'profileId', NEW.profile_id, 'profileVersion', NEW.profile_version, 'modelId', NEW.model_id, 'effort', NEW.effort, 'workflowId', NEW.workflow_id, 'workflowVersion', NEW.workflow_version, 'userMessageId', NEW.user_message_id, 'assignmentId', NEW.assignment_id, 'taskId', NEW.task_id, 'stepKind', NEW.step_kind, 'workerSessionId', NEW.worker_session_id, 'baseContextRevision', NEW.base_context_revision)::text,
    NULL,
    NEW.created_at;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_history_execution_created AFTER INSERT ON conversation_turns FOR EACH ROW EXECUTE FUNCTION trg_history_execution_created_fn();

CREATE FUNCTION trg_history_execution_status_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'execution_event',
    'execution.' || CASE WHEN NEW.status = 'running' THEN 'started' ELSE NEW.status END,
    'syntila',
    NULL,
    NEW.work_request_id,
    NEW.id,
    NULL,
    NEW.id,
    NULL,
    jsonb_build_object('from', OLD.status, 'to', NEW.status, 'assignmentId', NEW.assignment_id, 'startedAt', syntila_iso(NEW.started_at), 'completedAt', syntila_iso(NEW.completed_at))::text,
    NULL,
    COALESCE(NEW.completed_at, NEW.started_at, NEW.created_at);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_history_execution_status AFTER UPDATE OF status ON conversation_turns FOR EACH ROW EXECUTE FUNCTION trg_history_execution_status_fn();

CREATE FUNCTION trg_history_request_accepted_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.request_accepted',
    'syntila',
    NULL,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.work_request_id,
    NULL,
    jsonb_build_object('workflowId', wr.workflow_id, 'workflowVersion', wr.workflow_version, 'status', wr.status, 'conversationRevision', NEW.conversation_revision)::text,
    NULL,
    wr.created_at
  FROM work_requests wr WHERE wr.id = NEW.work_request_id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_history_request_accepted AFTER INSERT ON conversation_work_requests FOR EACH ROW EXECUTE FUNCTION trg_history_request_accepted_fn();

CREATE FUNCTION trg_history_request_status_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.request_status_changed',
    'syntila',
    NULL,
    NEW.id,
    NULL,
    NULL,
    NEW.id,
    NULL,
    jsonb_build_object('from', OLD.status, 'to', NEW.status, 'workflowId', NEW.workflow_id, 'workflowVersion', NEW.workflow_version)::text,
    NULL,
    NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_history_request_status AFTER UPDATE OF status ON work_requests FOR EACH ROW EXECUTE FUNCTION trg_history_request_status_fn();

CREATE FUNCTION trg_history_run_created_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.run_created',
    'syntila',
    NULL,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.id,
    NULL,
    jsonb_build_object('status', NEW.status)::text,
    NULL,
    NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_history_run_created AFTER INSERT ON runs FOR EACH ROW EXECUTE FUNCTION trg_history_run_created_fn();

CREATE FUNCTION trg_history_run_status_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.run_status_changed',
    'syntila',
    NULL,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.id,
    NULL,
    jsonb_build_object('from', OLD.status, 'to', NEW.status)::text,
    NULL,
    NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_history_run_status AFTER UPDATE OF status ON runs FOR EACH ROW EXECUTE FUNCTION trg_history_run_status_fn();

CREATE FUNCTION trg_history_step_created_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event', 'workflow.step_created', 'syntila', NULL,
    NEW.work_request_id, NULL, NULL, NEW.id, NULL,
    jsonb_build_object('status', NEW.status, 'stepKind', NEW.step_kind, 'stepId', NEW.step_id, 'attempt', NEW.attempt)::text,
    NULL, NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_history_step_created AFTER INSERT ON workflow_tasks FOR EACH ROW EXECUTE FUNCTION trg_history_step_created_fn();

CREATE FUNCTION trg_history_step_status_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event', 'workflow.step_status_changed', 'syntila', NULL,
    NEW.work_request_id, NULL, NULL, NEW.id, NULL,
    jsonb_build_object('from', OLD.status, 'to', NEW.status, 'stepKind', NEW.step_kind, 'stepId', NEW.step_id, 'attempt', NEW.attempt)::text,
    NULL, NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_history_step_status AFTER UPDATE OF status ON workflow_tasks FOR EACH ROW EXECUTE FUNCTION trg_history_step_status_fn();

CREATE FUNCTION trg_history_user_message_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'user_message',
    'message.user_created',
    'user',
    NEW.author_user_id,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.id,
    NEW.text,
    jsonb_build_object('userMessageId', NEW.id)::text,
    'user:' || NEW.id,
    NEW.created_at;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_history_user_message AFTER INSERT ON conversation_user_messages FOR EACH ROW EXECUTE FUNCTION trg_history_user_message_fn();

CREATE FUNCTION trg_history_worker_response_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'completed' AND NEW.result_text IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext('syntila.conversation_history'));
    INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'worker_response',
    'message.worker_created',
    'worker',
    NEW.worker_id,
    NEW.work_request_id,
    NEW.id,
    NULL,
    NEW.id,
    NEW.result_text,
    jsonb_build_object('workerId', NEW.worker_id, 'workerTypeId', NEW.worker_type_id, 'workerDisplayName', NEW.worker_display_name, 'profileId', NEW.profile_id, 'profileVersion', NEW.profile_version, 'modelId', NEW.model_id, 'effort', NEW.effort, 'workflowId', NEW.workflow_id, 'workflowVersion', NEW.workflow_version, 'userMessageId', NEW.user_message_id, 'assignmentId', NEW.assignment_id, 'taskId', NEW.task_id, 'stepKind', NEW.step_kind, 'workerSessionId', NEW.worker_session_id, 'baseContextRevision', NEW.base_context_revision)::text,
    'worker:' || NEW.id,
    NEW.completed_at;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_history_worker_response AFTER UPDATE OF status ON conversation_turns FOR EACH ROW EXECUTE FUNCTION trg_history_worker_response_fn();

CREATE FUNCTION trg_request_ai_generation_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE work_requests SET ai_context_generation =
    (SELECT ai_context_generation FROM threads WHERE id = NEW.thread_id)
    WHERE id = NEW.id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_request_ai_generation AFTER INSERT ON work_requests FOR EACH ROW EXECUTE FUNCTION trg_request_ai_generation_fn();

CREATE FUNCTION trg_thread_discussion_contributor_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.event_type IS NULL AND NEW.kind != 'ai_answer' THEN
    UPDATE threads SET has_other_contributions = 1
  WHERE id = NEW.thread_id AND lead_user_id != NEW.author_user_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_thread_discussion_contributor AFTER INSERT ON discussion_messages FOR EACH ROW EXECUTE FUNCTION trg_thread_discussion_contributor_fn();

CREATE FUNCTION trg_thread_request_contributor_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE threads SET has_other_contributions = 1
  WHERE id = NEW.thread_id AND lead_user_id != NEW.requested_by_user_id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_thread_request_contributor AFTER INSERT ON work_requests FOR EACH ROW EXECUTE FUNCTION trg_thread_request_contributor_fn();

CREATE FUNCTION trg_work_requests_snapshot_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.thread_id IS DISTINCT FROM NEW.thread_id
  OR OLD.requested_by_user_id IS DISTINCT FROM NEW.requested_by_user_id
  OR OLD.mode IS DISTINCT FROM NEW.mode
  OR OLD.workflow_id IS DISTINCT FROM NEW.workflow_id
  OR OLD.workflow_version IS DISTINCT FROM NEW.workflow_version
  OR OLD.workflow_snapshot_json IS DISTINCT FROM NEW.workflow_snapshot_json
  OR OLD.snapshot_json IS DISTINCT FROM NEW.snapshot_json
  OR OLD.primary_workspace_id IS DISTINCT FROM NEW.primary_workspace_id
  OR OLD.input_json IS DISTINCT FROM NEW.input_json THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Work Request snapshots are immutable';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_work_requests_snapshot_immutable BEFORE UPDATE OF thread_id, requested_by_user_id, mode, workflow_id,
  workflow_version, workflow_snapshot_json, snapshot_json,
  primary_workspace_id, input_json ON work_requests FOR EACH ROW EXECUTE FUNCTION trg_work_requests_snapshot_immutable_fn();

CREATE FUNCTION trg_workflow_run_first_start_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.started_at IS NOT NULL AND OLD.started_at IS DISTINCT FROM NEW.started_at THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Workflow Run first start is immutable';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_workflow_run_first_start_immutable BEFORE UPDATE OF started_at ON conversation_workflow_runs FOR EACH ROW EXECUTE FUNCTION trg_workflow_run_first_start_immutable_fn();

CREATE FUNCTION trg_workflow_run_initial_lifecycle_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE conversation_workflow_runs SET
  started_at=(SELECT CASE WHEN status='running' THEN updated_at ELSE NULL END FROM work_requests WHERE id=NEW.work_request_id),
  completed_at=(SELECT CASE WHEN status IN ('completed','failed','cancelled') THEN updated_at ELSE NULL END FROM work_requests WHERE id=NEW.work_request_id)
 WHERE id=NEW.id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_workflow_run_initial_lifecycle AFTER INSERT ON conversation_workflow_runs FOR EACH ROW EXECUTE FUNCTION trg_workflow_run_initial_lifecycle_fn();

CREATE FUNCTION trg_workflow_run_request_lifecycle_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    UPDATE conversation_workflow_runs SET
  started_at=CASE WHEN NEW.status='running' THEN COALESCE(started_at,NEW.updated_at) ELSE started_at END,
  completed_at=CASE WHEN NEW.status IN ('completed','failed','cancelled') THEN NEW.updated_at ELSE NULL END
 WHERE work_request_id=NEW.id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_workflow_run_request_lifecycle AFTER UPDATE OF status ON work_requests FOR EACH ROW EXECUTE FUNCTION trg_workflow_run_request_lifecycle_fn();

CREATE FUNCTION trg_workflow_step_run_immutable_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Workflow Step Run identity is immutable';
  RETURN NEW;
END $$;
CREATE TRIGGER trg_workflow_step_run_immutable BEFORE UPDATE ON conversation_workflow_step_runs FOR EACH ROW EXECUTE FUNCTION trg_workflow_step_run_immutable_fn();

CREATE FUNCTION trg_workflow_step_run_run_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO conversation_workflow_step_runs(id,workflow_run_id,task_id,step_id,role,created_at)
 SELECT 'step-run-' || t.id,NEW.id,t.id,t.step_kind,t.step_kind,t.created_at
 FROM workflow_tasks t WHERE t.work_request_id=NEW.work_request_id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_workflow_step_run_run_insert AFTER INSERT ON conversation_workflow_runs FOR EACH ROW EXECUTE FUNCTION trg_workflow_step_run_run_insert_fn();

CREATE FUNCTION trg_workflow_step_run_scope_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM workflow_tasks t JOIN conversation_workflow_runs r ON r.work_request_id=t.work_request_id
 WHERE t.id=NEW.task_id AND r.id=NEW.workflow_run_id AND t.step_id=NEW.step_id AND t.step_kind=NEW.role) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'Workflow Step Run must belong to its scoped task and Workflow Run';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_workflow_step_run_scope_insert BEFORE INSERT ON conversation_workflow_step_runs FOR EACH ROW EXECUTE FUNCTION trg_workflow_step_run_scope_insert_fn();

CREATE FUNCTION trg_workflow_step_run_task_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO conversation_workflow_step_runs(id,workflow_run_id,task_id,step_id,role,created_at)
 SELECT 'step-run-' || NEW.id,r.id,NEW.id,NEW.step_id,NEW.step_kind,NEW.created_at
 FROM conversation_workflow_runs r WHERE r.work_request_id=NEW.work_request_id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_workflow_step_run_task_insert AFTER INSERT ON workflow_tasks FOR EACH ROW EXECUTE FUNCTION trg_workflow_step_run_task_insert_fn();

CREATE FUNCTION validate_direct_space_general_thread_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.general_thread_id IS NOT NULL THEN
    IF NOT EXISTS (
    SELECT 1 FROM threads t WHERE t.id = NEW.general_thread_id AND t.space_id = NEW.space_id
  ) THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'general_thread_id must belong to the same Direct Space'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER validate_direct_space_general_thread BEFORE INSERT ON direct_spaces FOR EACH ROW EXECUTE FUNCTION validate_direct_space_general_thread_fn();

CREATE FUNCTION validate_direct_space_general_thread_update_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.general_thread_id IS NOT NULL THEN
    IF NOT EXISTS (
    SELECT 1 FROM threads t WHERE t.id = NEW.general_thread_id AND t.space_id = NEW.space_id
  ) THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'general_thread_id must belong to the same Direct Space'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER validate_direct_space_general_thread_update BEFORE UPDATE OF general_thread_id, space_id ON direct_spaces FOR EACH ROW EXECUTE FUNCTION validate_direct_space_general_thread_update_fn();

CREATE FUNCTION worker_catalog_origin_invariants_insert_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.origin = 'plugin') <> (NEW.owner_user_id IS NOT NULL)
  OR (NEW.origin = 'official' AND NEW.worker_type_id LIKE 'plugin-%')
  OR (NEW.origin = 'plugin'
      AND NOT (length(NEW.worker_type_id) = 19
        AND substr(NEW.worker_type_id, 1, 7) = 'plugin-'
        AND substr(NEW.worker_type_id, 8) ~ '^[0-9a-f]*$')) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'invalid worker_catalog origin';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER worker_catalog_origin_invariants_insert BEFORE INSERT ON worker_catalog FOR EACH ROW EXECUTE FUNCTION worker_catalog_origin_invariants_insert_fn();

CREATE FUNCTION workspace_space_grant_status_transition_valid_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status AND NOT (
  (OLD.status = 'active' AND NEW.status IN ('suspended', 'revoked', 'expired')) OR
  (OLD.status = 'suspended' AND NEW.status IN ('active', 'revoked', 'expired'))
) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'invalid Workspace Space Grant status transition';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER workspace_space_grant_status_transition_valid BEFORE UPDATE OF status ON workspace_space_grants FOR EACH ROW EXECUTE FUNCTION workspace_space_grant_status_transition_valid_fn();


-- Reference data: official logical Workers (from the D1 migrations).
INSERT INTO worker_catalog (worker_type_id, display_name, description, lifecycle_state, created_at, updated_at, engine_family, visibility_state, release_stage, sort_order, profile_definition_id, provider_tool_name, origin, owner_user_id) VALUES ('chatgpt', 'ChatGPT', 'Logical Worker implemented by approved local tools.', 'active', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z', 'cli', 'visible', 'stable', 10, 'chatgpt-codex', 'codex', 'official', NULL);
INSERT INTO worker_catalog (worker_type_id, display_name, description, lifecycle_state, created_at, updated_at, engine_family, visibility_state, release_stage, sort_order, profile_definition_id, provider_tool_name, origin, owner_user_id) VALUES ('gemini', 'Gemini', 'Logical Worker implemented by approved local tools.', 'active', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z', 'cli', 'visible', 'stable', 20, 'gemini-antigravity', 'agy', 'official', NULL);
INSERT INTO worker_catalog (worker_type_id, display_name, description, lifecycle_state, created_at, updated_at, engine_family, visibility_state, release_stage, sort_order, profile_definition_id, provider_tool_name, origin, owner_user_id) VALUES ('claude', 'Claude', 'Logical Worker implemented by approved local tools.', 'active', '2026-10-13T00:00:00Z', '2026-10-13T00:00:00Z', 'cli', 'visible', 'testing', 30, 'claude-code', 'claude', 'official', NULL);
INSERT INTO worker_catalog (worker_type_id, display_name, description, lifecycle_state, created_at, updated_at, engine_family, visibility_state, release_stage, sort_order, profile_definition_id, provider_tool_name, origin, owner_user_id) VALUES ('copilot', 'Copilot', 'Logical Worker implemented by approved local tools.', 'active', '2026-10-23T00:00:00Z', '2026-10-23T00:00:00Z', 'cli', 'visible', 'testing', 40, 'copilot-cli', 'copilot', 'official', NULL);
INSERT INTO worker_catalog (worker_type_id, display_name, description, lifecycle_state, created_at, updated_at, engine_family, visibility_state, release_stage, sort_order, profile_definition_id, provider_tool_name, origin, owner_user_id) VALUES ('grok', 'Grok', 'Logical Worker implemented by approved local tools.', 'active', '2026-10-23T00:00:00Z', '2026-10-23T00:00:00Z', 'cli', 'visible', 'testing', 50, 'grok-cli', 'grok', 'official', NULL);

-- ---------------------------------------------------------------------------
-- JSON helpers with SQLite JSON1 semantics, used where the domain code passes
-- JSON paths ('$.a.b') as parameters. Documents are stored as text.
CREATE FUNCTION syntila_json_path(path text) RETURNS text[] LANGUAGE sql IMMUTABLE STRICT AS
$$ SELECT CASE WHEN path = '$' THEN ARRAY[]::text[] ELSE ARRAY(
     SELECT COALESCE(m[1], m[2]) FROM regexp_matches(substr(path, 3), '"((?:[^"\\]|\\.)*)"|([^.]+)', 'g') AS m) END $$;

-- Like SQLite json_set: creates missing intermediate objects.
CREATE FUNCTION syntila_json_set(doc text, path text, value text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE p text[] := syntila_json_path(path); d jsonb := COALESCE(doc, '{}')::jsonb; i int;
BEGIN
  FOR i IN 1 .. coalesce(array_length(p, 1), 0) - 1 LOOP
    IF jsonb_typeof(d #> p[1:i]) IS DISTINCT FROM 'object' THEN d := jsonb_set(d, p[1:i], '{}'::jsonb, true); END IF;
  END LOOP;
  RETURN jsonb_set(d, p, value::jsonb, true)::text;
END $$;

CREATE FUNCTION syntila_json_remove(doc text, path text) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT (COALESCE(doc, '{}')::jsonb #- syntila_json_path(path))::text $$;

-- RFC 7386 JSON merge patch (SQLite json_patch).
CREATE FUNCTION syntila_jsonb_merge_patch(target jsonb, patch jsonb) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE k text; v jsonb; result jsonb;
BEGIN
  IF patch IS NULL OR jsonb_typeof(patch) <> 'object' THEN RETURN patch; END IF;
  result := CASE WHEN target IS NULL OR jsonb_typeof(target) <> 'object' THEN '{}'::jsonb ELSE target END;
  FOR k, v IN SELECT * FROM jsonb_each(patch) LOOP
    IF jsonb_typeof(v) = 'null' THEN result := result - k;
    ELSE result := jsonb_set(result, ARRAY[k], syntila_jsonb_merge_patch(result -> k, v), true);
    END IF;
  END LOOP;
  RETURN result;
END $$;

CREATE FUNCTION syntila_json_patch(doc text, patch text) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT syntila_jsonb_merge_patch(COALESCE(doc, '{}')::jsonb, patch::jsonb)::text $$;

-- ---------------------------------------------------------------------------
-- In-process Durable Object host (src/platform/durable-objects.ts).
CREATE TABLE durable_object_storage (
  namespace   text NOT NULL,
  object_name text NOT NULL,
  key         text NOT NULL,
  value       jsonb NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (namespace, object_name, key)
);
CREATE TABLE durable_object_alarms (
  namespace   text NOT NULL,
  object_name text NOT NULL,
  at          timestamptz NOT NULL,
  PRIMARY KEY (namespace, object_name)
);

-- ---------------------------------------------------------------------------
-- Durable Workflow runner (src/platform/workflows.ts), replaces Cloudflare Workflows.
CREATE TABLE workflow_instances (
  id                 text PRIMARY KEY,
  workflow           text NOT NULL,
  params             jsonb,
  status             text NOT NULL CHECK (status IN ('queued', 'running', 'waiting', 'complete', 'errored', 'terminated')),
  output             jsonb,
  error              text,
  wake_at            timestamptz,
  waiting_event_type text,
  lease_owner        text,
  lease_until        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX workflow_instances_runnable_idx ON workflow_instances (workflow, created_at)
  WHERE status IN ('queued', 'waiting', 'running');
CREATE TABLE workflow_steps (
  instance_id text NOT NULL REFERENCES workflow_instances(id) ON DELETE CASCADE,
  name        text NOT NULL,
  outcome     text NOT NULL CHECK (outcome IN ('done', 'timeout', 'failed')),
  result      jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (instance_id, name)
);
CREATE TABLE workflow_pending (
  instance_id text NOT NULL REFERENCES workflow_instances(id) ON DELETE CASCADE,
  name        text NOT NULL,
  deadline    timestamptz NOT NULL,
  PRIMARY KEY (instance_id, name)
);
CREATE TABLE workflow_events (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id text NOT NULL REFERENCES workflow_instances(id) ON DELETE CASCADE,
  type        text NOT NULL,
  payload     jsonb,
  consumed_by text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX workflow_events_pending_idx ON workflow_events (instance_id, type, id) WHERE consumed_by IS NULL;

-- ---------------------------------------------------------------------------
-- Insertion order (SQLite rowid) for rows the domain lists in creation order.
ALTER TABLE conversation_turns ADD COLUMN seq bigint GENERATED ALWAYS AS IDENTITY;
ALTER TABLE workflow_tasks ADD COLUMN seq bigint GENERATED ALWAYS AS IDENTITY;
