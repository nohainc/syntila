-- JSON stored as text must be valid JSON.
--
-- The schema came from SQLite, where 53 JSON documents live in text columns.
-- Converting them to jsonb would change what every query binds and reads,
-- so the type stays text for now; these constraints give the guarantee that
-- matters (a write of malformed JSON fails at once instead of breaking a
-- later reader) without touching a single query.
--
-- NOT VALID: enforced for every new or updated row from now on, without
-- scanning or locking existing rows. Once `scripts/check-json-columns.sql`
-- reports no bad rows in production, a later migration can VALIDATE them.
ALTER TABLE account_worker_plugin_versions ADD CONSTRAINT account_worker_plugin_versions_manifest_json_is_json CHECK (manifest_json IS JSON) NOT VALID;
ALTER TABLE account_worker_plugin_versions ADD CONSTRAINT account_worker_plugin_versions_origin_json_is_json CHECK (origin_json IS JSON) NOT VALID;
ALTER TABLE account_worker_plugin_versions ADD CONSTRAINT account_worker_plugin_versions_signer_json_is_json CHECK (signer_json IS JSON) NOT VALID;
ALTER TABLE auth_audit_events ADD CONSTRAINT auth_audit_events_details_json_is_json CHECK (details_json IS JSON) NOT VALID;
ALTER TABLE conversation_history_entries ADD CONSTRAINT conversation_history_entries_metadata_json_is_json CHECK (metadata_json IS JSON) NOT VALID;
ALTER TABLE discussion_messages ADD CONSTRAINT discussion_messages_attachments_json_is_json CHECK (attachments_json IS JSON) NOT VALID;
ALTER TABLE discussion_messages ADD CONSTRAINT discussion_messages_references_json_is_json CHECK (references_json IS JSON) NOT VALID;
ALTER TABLE discussion_messages ADD CONSTRAINT discussion_messages_reply_to_json_is_json CHECK (reply_to_json IS JSON) NOT VALID;
ALTER TABLE issue_report_diagnostics ADD CONSTRAINT issue_report_diagnostics_diagnostic_json_is_json CHECK (diagnostic_json IS JSON) NOT VALID;
ALTER TABLE issue_report_events ADD CONSTRAINT issue_report_events_details_json_is_json CHECK (details_json IS JSON) NOT VALID;
ALTER TABLE mcp_tool_calls ADD CONSTRAINT mcp_tool_calls_result_json_is_json CHECK (result_json IS JSON) NOT VALID;
ALTER TABLE mutation_receipts ADD CONSTRAINT mutation_receipts_response_json_is_json CHECK (response_json IS JSON) NOT VALID;
ALTER TABLE realtime_events ADD CONSTRAINT realtime_events_payload_json_is_json CHECK (payload_json IS JSON) NOT VALID;
ALTER TABLE runs ADD CONSTRAINT runs_policy_snapshot_json_is_json CHECK (policy_snapshot_json IS JSON) NOT VALID;
ALTER TABLE space_audit_log ADD CONSTRAINT space_audit_log_details_json_is_json CHECK (details_json IS JSON) NOT VALID;
ALTER TABLE space_workflow_configurations ADD CONSTRAINT space_workflow_configurations_configuration_json_is_json CHECK (configuration_json IS JSON) NOT VALID;
ALTER TABLE spaces ADD CONSTRAINT spaces_settings_json_is_json CHECK (settings_json IS JSON) NOT VALID;
ALTER TABLE thread_execution_policies ADD CONSTRAINT thread_execution_policies_allowed_models_json_is_json CHECK (allowed_models_json IS JSON) NOT VALID;
ALTER TABLE thread_execution_policies ADD CONSTRAINT thread_execution_policies_allowed_worker_type_ids_js_is_json CHECK (allowed_worker_type_ids_json IS JSON) NOT VALID;
ALTER TABLE thread_request_queue ADD CONSTRAINT thread_request_queue_request_json_is_json CHECK (request_json IS JSON) NOT VALID;
ALTER TABLE thread_work_configs ADD CONSTRAINT thread_work_configs_config_json_is_json CHECK (config_json IS JSON) NOT VALID;
ALTER TABLE threads ADD CONSTRAINT threads_access_policy_json_is_json CHECK (access_policy_json IS JSON) NOT VALID;
ALTER TABLE threads ADD CONSTRAINT threads_metadata_json_is_json CHECK (metadata_json IS JSON) NOT VALID;
ALTER TABLE user_workflow_configurations ADD CONSTRAINT user_workflow_configurations_configuration_json_is_json CHECK (configuration_json IS JSON) NOT VALID;
ALTER TABLE work_requests ADD CONSTRAINT work_requests_input_json_is_json CHECK (input_json IS JSON) NOT VALID;
ALTER TABLE work_requests ADD CONSTRAINT work_requests_snapshot_json_is_json CHECK (snapshot_json IS JSON) NOT VALID;
ALTER TABLE work_requests ADD CONSTRAINT work_requests_workflow_snapshot_json_is_json CHECK (workflow_snapshot_json IS JSON) NOT VALID;
ALTER TABLE worker_activity_history ADD CONSTRAINT worker_activity_history_details_json_is_json CHECK (details_json IS JSON) NOT VALID;
ALTER TABLE worker_assignments ADD CONSTRAINT worker_assignments_command_payload_json_is_json CHECK (command_payload_json IS JSON) NOT VALID;
ALTER TABLE worker_assignments ADD CONSTRAINT worker_assignments_config_json_is_json CHECK (config_json IS JSON) NOT VALID;
ALTER TABLE worker_assignments ADD CONSTRAINT worker_assignments_effective_permissions_json_is_json CHECK (effective_permissions_json IS JSON) NOT VALID;
ALTER TABLE worker_assignments ADD CONSTRAINT worker_assignments_error_json_is_json CHECK (error_json IS JSON) NOT VALID;
ALTER TABLE worker_assignments ADD CONSTRAINT worker_assignments_input_json_is_json CHECK (input_json IS JSON) NOT VALID;
ALTER TABLE worker_assignments ADD CONSTRAINT worker_assignments_output_json_is_json CHECK (output_json IS JSON) NOT VALID;
ALTER TABLE worker_assignments ADD CONSTRAINT worker_assignments_permission_snapshot_json_is_json CHECK (permission_snapshot_json IS JSON) NOT VALID;
ALTER TABLE worker_assignments ADD CONSTRAINT worker_assignments_startup_detail_json_is_json CHECK (startup_detail_json IS JSON) NOT VALID;
ALTER TABLE worker_profile_history ADD CONSTRAINT worker_profile_history_profile_json_is_json CHECK (profile_json IS JSON) NOT VALID;
ALTER TABLE worker_profiles ADD CONSTRAINT worker_profiles_profile_json_is_json CHECK (profile_json IS JSON) NOT VALID;
ALTER TABLE worker_scheduling_audit ADD CONSTRAINT worker_scheduling_audit_details_json_is_json CHECK (details_json IS JSON) NOT VALID;
ALTER TABLE workflow_tasks ADD CONSTRAINT workflow_tasks_output_json_is_json CHECK (output_json IS JSON) NOT VALID;
ALTER TABLE workspace_audit_log ADD CONSTRAINT workspace_audit_log_details_json_is_json CHECK (details_json IS JSON) NOT VALID;
ALTER TABLE workspace_member_access ADD CONSTRAINT workspace_member_access_policy_json_is_json CHECK (policy_json IS JSON) NOT VALID;
ALTER TABLE workspace_member_overrides ADD CONSTRAINT workspace_member_overrides_policy_json_is_json CHECK (policy_json IS JSON) NOT VALID;
ALTER TABLE workspace_releases ADD CONSTRAINT workspace_releases_supported_arch_json_is_json CHECK (supported_arch_json IS JSON) NOT VALID;
ALTER TABLE workspace_releases ADD CONSTRAINT workspace_releases_supported_os_json_is_json CHECK (supported_os_json IS JSON) NOT VALID;
ALTER TABLE workspace_runtime_facts ADD CONSTRAINT workspace_runtime_facts_runtime_capabilities_json_is_json CHECK (runtime_capabilities_json IS JSON) NOT VALID;
ALTER TABLE workspace_space_grants ADD CONSTRAINT workspace_space_grants_allowed_permissions_json_is_json CHECK (allowed_permissions_json IS JSON) NOT VALID;
ALTER TABLE workspace_space_grants ADD CONSTRAINT workspace_space_grants_allowed_worker_ids_json_is_json CHECK (allowed_worker_ids_json IS JSON) NOT VALID;
ALTER TABLE workspace_space_grants ADD CONSTRAINT workspace_space_grants_concurrency_json_is_json CHECK (concurrency_json IS JSON) NOT VALID;
ALTER TABLE workspace_space_grants ADD CONSTRAINT workspace_space_grants_network_policy_json_is_json CHECK (network_policy_json IS JSON) NOT VALID;
ALTER TABLE workspace_worker_inventory ADD CONSTRAINT workspace_worker_inventory_executor_json_is_json CHECK (executor_json IS JSON) NOT VALID;
ALTER TABLE workspace_worker_inventory ADD CONSTRAINT workspace_worker_inventory_model_catalog_json_is_json CHECK (model_catalog_json IS JSON) NOT VALID;
ALTER TABLE workspace_worker_preferences ADD CONSTRAINT workspace_worker_preferences_preferences_json_is_json CHECK (preferences_json IS JSON) NOT VALID;
