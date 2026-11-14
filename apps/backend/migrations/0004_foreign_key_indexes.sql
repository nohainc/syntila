-- migrate:no-transaction
-- Indexes for foreign-key columns that had none. Without them PostgreSQL scans
-- the whole child table on every delete/update of the parent row (and SQLite's
-- automatic behaviour hid that), and joins from parent to child are slow.
-- Built CONCURRENTLY so writes continue; safe to re-run.

CREATE INDEX CONCURRENTLY IF NOT EXISTS artifacts_assignment_id_fkidx ON artifacts (assignment_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS artifacts_run_id_fkidx ON artifacts (run_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS artifacts_space_id_fkidx ON artifacts (space_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS artifacts_thread_id_fkidx ON artifacts (thread_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS auth_audit_events_user_id_fkidx ON auth_audit_events (user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS conversation_turns_user_message_id_conversation_id_fkidx ON conversation_turns (user_message_id, conversation_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS conversation_user_messages_conversation_id_fkidx ON conversation_user_messages (conversation_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS conversation_workflow_runs_conversation_id_fkidx ON conversation_workflow_runs (conversation_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS conversation_workflow_runs_user_message_id_conversa_fkidx ON conversation_workflow_runs (user_message_id, conversation_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS direct_spaces_general_thread_id_fkidx ON direct_spaces (general_thread_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS discussion_messages_author_user_id_fkidx ON discussion_messages (author_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS issue_report_events_actor_user_id_fkidx ON issue_report_events (actor_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS issue_report_groups_created_by_user_id_fkidx ON issue_report_groups (created_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS issue_reports_workspace_id_fkidx ON issue_reports (workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS mcp_tool_calls_workspace_id_fkidx ON mcp_tool_calls (workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS person_invitations_accepted_by_user_id_fkidx ON person_invitations (accepted_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS release_signing_key_revocations_revoked_by_user_id_fkidx ON release_signing_key_revocations (revoked_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS runs_space_id_fkidx ON runs (space_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS runs_work_request_id_fkidx ON runs (work_request_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS space_invitations_accepted_by_user_id_fkidx ON space_invitations (accepted_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS space_invitations_invited_by_user_id_fkidx ON space_invitations (invited_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS space_memberships_user_id_fkidx ON space_memberships (user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS space_workflow_settings_workspace_id_fkidx ON space_workflow_settings (workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS thread_execution_policies_primary_workspace_id_fkidx ON thread_execution_policies (primary_workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS thread_read_states_user_id_fkidx ON thread_read_states (user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS thread_runtime_leases_workspace_id_fkidx ON thread_runtime_leases (workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS thread_work_configs_updated_by_user_id_fkidx ON thread_work_configs (updated_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS threads_lead_user_id_fkidx ON threads (lead_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS user_notification_reads_work_request_id_fkidx ON user_notification_reads (work_request_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS user_workflow_configurations_workspace_id_fkidx ON user_workflow_configurations (workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS user_workflow_defaults_workspace_id_fkidx ON user_workflow_defaults (workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS user_workflow_settings_workspace_id_fkidx ON user_workflow_settings (workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS work_requests_primary_workspace_id_fkidx ON work_requests (primary_workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS work_requests_requested_by_user_id_fkidx ON work_requests (requested_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_assignments_execution_workspace_id_fkidx ON worker_assignments (execution_workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_assignments_run_id_fkidx ON worker_assignments (run_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_assignments_runtime_identity_id_fkidx ON worker_assignments (runtime_identity_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_assignments_space_id_fkidx ON worker_assignments (space_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_assignments_thread_id_fkidx ON worker_assignments (thread_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_assignments_worker_type_id_fkidx ON worker_assignments (worker_type_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_assignments_workspace_space_grant_id_fkidx ON worker_assignments (workspace_space_grant_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_catalog_owner_user_id_fkidx ON worker_catalog (owner_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_profile_history_actor_user_id_fkidx ON worker_profile_history (actor_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_profiles_updated_by_user_id_fkidx ON worker_profiles (updated_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_scheduling_audit_actor_user_id_fkidx ON worker_scheduling_audit (actor_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_scheduling_drain_requested_by_user_id_fkidx ON worker_scheduling (drain_requested_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS worker_scheduling_updated_by_user_id_fkidx ON worker_scheduling (updated_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workflow_events_instance_id_fkidx ON workflow_events (instance_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workflow_task_dependencies_depends_on_task_id_fkidx ON workflow_task_dependencies (depends_on_task_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_installations_owner_user_id_fkidx ON workspace_installations (owner_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_installations_workspace_id_fkidx ON workspace_installations (workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_invitations_accepted_by_user_id_fkidx ON workspace_invitations (accepted_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_invitations_invited_by_user_id_fkidx ON workspace_invitations (invited_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_invitations_workspace_id_fkidx ON workspace_invitations (workspace_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_member_overrides_user_id_fkidx ON workspace_member_overrides (user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_person_grants_granted_by_user_id_fkidx ON workspace_person_grants (granted_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_person_grants_user_id_fkidx ON workspace_person_grants (user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_sessions_runtime_identity_id_fkidx ON workspace_sessions (runtime_identity_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_space_grants_workspace_id_granted_by_user_id_fkidx ON workspace_space_grants (workspace_id, granted_by_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_worker_inventory_workspace_id_owner_user_id_fkidx ON workspace_worker_inventory (workspace_id, owner_user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_worker_plugin_enablements_plugin_ref_version_fkidx ON workspace_worker_plugin_enablements (plugin_ref, version);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_worker_plugin_enablements_plugin_ref_fkidx ON workspace_worker_plugin_enablements (plugin_ref);
CREATE INDEX CONCURRENTLY IF NOT EXISTS workspace_worker_preferences_workspace_id_fkidx ON workspace_worker_preferences (workspace_id);
