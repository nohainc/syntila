# VPS port inventory (generated)

Generated from `apps/cloud` and the final local D1 schema (migration 0114). Regenerate with `scripts/internal/vps-port-inventory.py`.

## Source files by port slice

| Slice | Files | Lines |
| --- | --- | --- |
| 6 Foundation (router) | `routes/router.ts` | 1487 |
| 7.1 Identity & accounts | `account-execution-slots.ts`, `account-plan.ts`, `auth/better-auth.ts`, `auth/identity-service.ts`, `auth/index.ts`, `auth/observability.ts`, `auth/provisioning-service.ts`, `auth/session-retention.ts`, `auth/step-up.ts`, `people.ts`, `routes/auth.ts`, `routes/handlers.ts`, `routes/http-security.ts`, `routes/profile-lab-policy.ts`, `routes/profile.ts` | 4619 |
| 7.2 Spaces & people | `routes/conditional-read.ts`, `routes/home.ts`, `routes/mutation-idempotency.ts`, `routes/notes.ts`, `routes/notifications.ts`, `routes/people.ts`, `routes/pins.ts`, `routes/space-additional-folders.ts`, `routes/space-permissions.ts`, `routes/space-workflow-configurations.ts`, `routes/spaces.ts`, `routes/user-files.ts`, `routes/workspace-invitations.ts`, `routes/workspace-people-with-access.ts` | 5391 |
| 7.3 Threads & conversation | `collaboration-events.ts`, `routes/conversation-bootstrap.ts`, `routes/conversation-history.ts`, `routes/conversation-turns.ts`, `routes/conversation-workflow-runs.ts`, `routes/conversation-workflow-step-runs.ts`, `routes/conversations.ts`, `routes/reply-references.ts`, `routes/thread-activity.ts`, `routes/thread-history-actions.ts`, `routes/thread-policy.ts`, `routes/thread-request-queue.ts`, `routes/threads.ts`, `routes/work-request-inputs.ts`, `thread-coordinator.ts`, `work-session-key.ts` | 5188 |
| 7.4 Execution & workflows | `assignment-delivery.ts`, `assignment-dispatcher.ts`, `assignment-liveness.ts`, `assignment-phase-events.ts`, `assignment-revocation.ts`, `assignment-start-permit.ts`, `assignment-startup.ts`, `assignment-transitions.ts`, `assignment-workflow-signal.ts`, `attachment-storage.ts`, `execution-engine.ts`, `execution-phase.ts`, `execution-selection-snapshot.ts`, `mcp-tool-dispatch-claim.ts`, `mcp-tool-step.ts`, `routes/implement-plan.ts`, `routes/mcp-action.ts`, `routes/mcp-inventory.ts`, `routes/mcp-tool-call.ts`, `routes/work-creation.ts`, `routes/work-lifecycle.ts`, `routes/work-request-files.ts`, `routes/work.ts`, `routes/worker-output-images.ts`, `routes/worker-plugins.ts`, `routes/workflow-configurations.ts`, `routes/workflow-default.ts`, `routes/workflow-execution-configuration.ts`, `routes/workflow-step-execution-config.ts`, `routes/workflow-workspace.ts`, `routes/workspace-access.ts`, `routes/workspace-member-access.ts`, `routes/workspace-worker-preferences.ts`, `routes/workspaces-artifacts.ts`, `routes/workspaces-grants.ts`, `routes/workspaces-management.ts`, `routes/workspaces-registration.ts`, `routes/workspaces-runtime.ts`, `routes/workspaces-shared.ts`, `routes/workspaces.ts`, `scheduler.ts`, `upload-stream.ts`, `worker-execution-options.ts`, `workflow-prompts.ts`, `workflow.ts` | 18162 |
| 7.5 Workspace runtime | `plugin-manifest-digest.ts`, `workspace-audit.ts`, `workspace-gateway.ts`, `workspace-gateway/contracts.ts`, `workspace-gateway/inventory.ts`, `workspace-gateway/release-cleanup.ts`, `workspace-gateway/runtime-authenticator.ts`, `workspace-gateway/session-store.ts` | 4639 |
| 7.6 Catalog, releases & admin | `canonical-json.ts`, `issue-report-retention.ts`, `release-trust.ts`, `routes/issue-reports.ts`, `routes/profile-admin.ts`, `routes/profiles.ts`, `routes/releases.ts`, `tool-profile-validation.ts`, `worker-activity-history.ts`, `worker-profile-registry.ts` | 3364 |
| 7.7 Realtime, cron & email | `avatar-storage.ts`, `email/email-config.ts`, `email/email-escaping.ts`, `email/email-layout.ts`, `email/email-service.ts`, `email/email-types.ts`, `email/index.ts`, `email/notification-policy.ts`, `email/preview-fixtures.ts`, `email/templates/index.ts`, `event-publisher.ts`, `index.ts`, `invitation-email.ts`, `observability.ts`, `realtime-gateway.ts`, `realtime-queue.ts`, `realtime-retention.ts`, `service-readiness.ts` | 4117 |
| 8 Stays on Cloudflare | `backend-token.ts` | 98 |

## Route handlers (151)

| Handler | Defined in | Slice |
| --- | --- | --- |
| `handleAcceptPersonInvitation` | `routes/people.ts` | 7.2 Spaces & people |
| `handleAcceptSpaceInvitation` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleAcceptWorkspaceInvitation` | `routes/workspace-invitations.ts` | 7.2 Spaces & people |
| `handleAccountPlan` | `routes/profile.ts` | 7.1 Identity & accounts |
| `handleApproveDesktopAuthIntent` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleApprovePlan` | `routes/implement-plan.ts` | 7.4 Execution & workflows |
| `handleBlockPerson` | `routes/people.ts` | 7.2 Spaces & people |
| `handleCancelDesktopAuthIntent` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleCancelPersonInvitation` | `routes/people.ts` | 7.2 Spaces & people |
| `handleCancelWorkRequest` | `routes/work-lifecycle.ts` | 7.4 Execution & workflows |
| `handleChangeSpaceMemberRole` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleCheckWorkspaceOwnership` | `routes/workspaces-registration.ts` | 7.4 Execution & workflows |
| `handleClaimDesktopAuthIntent` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleClearChatHistory` | `routes/threads.ts` | 7.3 Threads & conversation |
| `handleClearWorkHistory` | `routes/work-lifecycle.ts` | 7.4 Execution & workflows |
| `handleConfirmRuntimeInput` | `routes/work-request-inputs.ts` | 7.3 Threads & conversation |
| `handleCreateAdminIssueReportGroup` | `routes/issue-reports.ts` | 7.6 Catalog, releases & admin |
| `handleCreateDesktopAuthIntent` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleCreateDiscussionMessage` | `routes/threads.ts` | 7.3 Threads & conversation |
| `handleCreateIssueReport` | `routes/issue-reports.ts` | 7.6 Catalog, releases & admin |
| `handleCreateNote` | `routes/notes.ts` | 7.2 Spaces & people |
| `handleCreatePersonInvitation` | `routes/people.ts` | 7.2 Spaces & people |
| `handleCreateSpace` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleCreateSpaceInvitation` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleCreateThread` | `routes/threads.ts` | 7.3 Threads & conversation |
| `handleCreateWorkRequest` | `routes/work-creation.ts` | 7.4 Execution & workflows |
| `handleDeclinePersonInvitation` | `routes/people.ts` | 7.2 Spaces & people |
| `handleDeclineSpaceInvitation` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleDeclineWorkspaceInvitation` | `routes/workspace-invitations.ts` | 7.2 Spaces & people |
| `handleDeleteDiscussionMessage` | `routes/threads.ts` | 7.3 Threads & conversation |
| `handleDeleteSpace` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleDeleteThread` | `routes/threads.ts` | 7.3 Threads & conversation |
| `handleDeleteUserFile` | `routes/user-files.ts` | 7.2 Spaces & people |
| `handleDenyDesktopAuthIntent` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleDesktopAuthIntentBrowserStatus` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleDesktopAuthIntentStatus` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleDesktopPasswordSignIn` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleDisconnectDesktopWorkspace` | `routes/workspaces-registration.ts` | 7.4 Execution & workflows |
| `handleDisconnectPersonConnection` | `routes/people.ts` | 7.2 Spaces & people |
| `handleDownloadRuntimeInput` | `routes/work-request-inputs.ts` | 7.3 Threads & conversation |
| `handleDownloadThreadFile` | `routes/work-request-files.ts` | 7.4 Execution & workflows |
| `handleDownloadUserFile` | `routes/user-files.ts` | 7.2 Spaces & people |
| `handleDownloadWorkspaceRelease` | `routes/releases.ts` | 7.6 Catalog, releases & admin |
| `handleEditDiscussionMessage` | `routes/threads.ts` | 7.3 Threads & conversation |
| `handleEnsureSupportSpace` | `routes/people.ts` | 7.2 Spaces & people |
| `handleExpireSpaceInvitation` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleExportWorkspaceAudit` | `routes/workspaces-management.ts` | 7.4 Execution & workflows |
| `handleFailWorkRequestInputUpload` | `routes/work-request-inputs.ts` | 7.3 Threads & conversation |
| `handleGetAdminIssueReport` | `routes/issue-reports.ts` | 7.6 Catalog, releases & admin |
| `handleGetAdminIssueReportGroup` | `routes/issue-reports.ts` | 7.6 Catalog, releases & admin |
| `handleGetArtifact` | `routes/workspaces-artifacts.ts` | 7.4 Execution & workflows |
| `handleGetAvatar` | `routes/profile.ts` | 7.1 Identity & accounts |
| `handleGetDesktopHumanSession` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleGetDiscussionMessage` | `routes/threads.ts` | 7.3 Threads & conversation |
| `handleGetHomeReadModel` | `routes/home.ts` | 7.2 Spaces & people |
| `handleGetIssueReport` | `routes/issue-reports.ts` | 7.6 Catalog, releases & admin |
| `handleGetIssueReportForRequest` | `routes/issue-reports.ts` | 7.6 Catalog, releases & admin |
| `handleGetLatestWorkspaceRelease` | `routes/releases.ts` | 7.6 Catalog, releases & admin |
| `handleGetReleaseTrustState` | `routes/releases.ts` | 7.6 Catalog, releases & admin |
| `handleGetSpace` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleGetV9WorkerProfile` | `routes/profile-admin.ts` | 7.6 Catalog, releases & admin |
| `handleGetWorkRequest` | `routes/work-lifecycle.ts` | 7.4 Execution & workflows |
| `handleGetWorkspace` | `routes/workspaces-management.ts` | 7.4 Execution & workflows |
| `handleGetWorkspaceRelease` | `routes/releases.ts` | 7.6 Catalog, releases & admin |
| `handleGetWorkspaceV9WorkerProfile` | `routes/profile-admin.ts` | 7.6 Catalog, releases & admin |
| `handleListAdminIssueReportGroups` | `routes/issue-reports.ts` | 7.6 Catalog, releases & admin |
| `handleListAdminIssueReports` | `routes/issue-reports.ts` | 7.6 Catalog, releases & admin |
| `handleListConversationHistory` | `routes/conversation-history.ts` | 7.3 Threads & conversation |
| `handleListConversations` | `routes/conversations.ts` | 7.3 Threads & conversation |
| `handleListCurrentUserInvitations` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleListDiscussionMessages` | `routes/threads.ts` | 7.3 Threads & conversation |
| `handleListNotes` | `routes/notes.ts` | 7.2 Spaces & people |
| `handleListNotifications` | `routes/notifications.ts` | 7.2 Spaces & people |
| `handleListPeople` | `routes/people.ts` | 7.2 Spaces & people |
| `handleListPersonInvitations` | `routes/people.ts` | 7.2 Spaces & people |
| `handleListRuntimeInputs` | `routes/work-request-inputs.ts` | 7.3 Threads & conversation |
| `handleListSpaceAudit` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleListSpaceInvitations` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleListSpaceMembers` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleListSpaceThreads` | `routes/threads.ts` | 7.3 Threads & conversation |
| `handleListSpaces` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleListThreadReadStates` | `routes/threads.ts` | 7.3 Threads & conversation |
| `handleListUserFiles` | `routes/user-files.ts` | 7.2 Spaces & people |
| `handleListV9WorkerProfileHistory` | `routes/profile-admin.ts` | 7.6 Catalog, releases & admin |
| `handleListV9WorkerProfiles` | `routes/profile-admin.ts` | 7.6 Catalog, releases & admin |
| `handleListWorkRequests` | `routes/work-lifecycle.ts` | 7.4 Execution & workflows |
| `handleListWorkerCatalog` | `routes/profiles.ts` | 7.6 Catalog, releases & admin |
| `handleListWorkspaceWorkerCatalog` | `routes/profiles.ts` | 7.6 Catalog, releases & admin |
| `handleListWorkspaceWorkerInventory` | `routes/profiles.ts` | 7.6 Catalog, releases & admin |
| `handleListWorkspaces` | `routes/workspaces-management.ts` | 7.4 Execution & workflows |
| `handleMarkNotificationsRead` | `routes/notifications.ts` | 7.2 Spaces & people |
| `handleMarkThreadRead` | `routes/threads.ts` | 7.3 Threads & conversation |
| `handleMyWorkspaceInvitations` | `routes/workspace-invitations.ts` | 7.2 Spaces & people |
| `handleNote` | `routes/notes.ts` | 7.2 Spaces & people |
| `handleOpenPersonalSpace` | `routes/people.ts` | 7.2 Spaces & people |
| `handlePatchAdminIssueReport` | `routes/issue-reports.ts` | 7.6 Catalog, releases & admin |
| `handlePeopleWithAccess` | `routes/workspace-people-with-access.ts` | 7.2 Spaces & people |
| `handlePersonGrantQuota` | `routes/workspace-invitations.ts` | 7.2 Spaces & people |
| `handlePluginLibrary` | `routes/worker-plugins.ts` | 7.4 Execution & workflows |
| `handleProfileLabAccess` | `routes/profile-admin.ts` | 7.6 Catalog, releases & admin |
| `handlePublishV9WorkerProfile` | `routes/profile-admin.ts` | 7.6 Catalog, releases & admin |
| `handlePublishWorkspaceRelease` | `routes/releases.ts` | 7.6 Catalog, releases & admin |
| `handleReadReceiptPrivacy` | `routes/profile.ts` | 7.1 Identity & accounts |
| `handleReconcileWorkspaceOwnership` | `routes/workspaces-registration.ts` | 7.4 Execution & workflows |
| `handleRegisterWorkspaceFromDesktop` | `routes/workspaces-registration.ts` | 7.4 Execution & workflows |
| `handleReleaseDesktopWorkspace` | `routes/workspaces-registration.ts` | 7.4 Execution & workflows |
| `handleRemoveSpaceMember` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleReportRuntimeInputAttempt` | `routes/work-request-inputs.ts` | 7.3 Threads & conversation |
| `handleRestoreV9WorkerProfile` | `routes/profile-admin.ts` | 7.6 Catalog, releases & admin |
| `handleRetryWorkRequest` | `routes/work-lifecycle.ts` | 7.4 Execution & workflows |
| `handleRevokeDesktopHumanSession` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleRevokePersonGrant` | `routes/workspace-invitations.ts` | 7.2 Spaces & people |
| `handleRevokeReleaseSigningKey` | `routes/releases.ts` | 7.6 Catalog, releases & admin |
| `handleRevokeWorkspace` | `routes/workspaces-management.ts` | 7.4 Execution & workflows |
| `handleRevokeWorkspaceRelease` | `routes/releases.ts` | 7.6 Catalog, releases & admin |
| `handleRotateDesktopHumanSession` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleSession` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleSessionLogout` | `routes/auth.ts` | 7.1 Identity & accounts |
| `handleSetPin` | `routes/pins.ts` | 7.2 Spaces & people |
| `handleSetPinOrder` | `routes/pins.ts` | 7.2 Spaces & people |
| `handleSpaceAdditionalFolders` | `routes/space-additional-folders.ts` | 7.2 Spaces & people |
| `handleSyncUserFiles` | `routes/user-files.ts` | 7.2 Spaces & people |
| `handleThreadNote` | `routes/notes.ts` | 7.2 Spaces & people |
| `handleThreadRequestQueue` | `routes/thread-request-queue.ts` | 7.3 Threads & conversation |
| `handleUnblockPerson` | `routes/people.ts` | 7.2 Spaces & people |
| `handleUpdateSpace` | `routes/spaces.ts` | 7.2 Spaces & people |
| `handleUpdateThread` | `routes/threads.ts` | 7.3 Threads & conversation |
| `handleUpdateWorkspace` | `routes/workspaces-management.ts` | 7.4 Execution & workflows |
| `handleUploadArtifact` | `routes/workspaces-artifacts.ts` | 7.4 Execution & workflows |
| `handleUploadAvatar` | `routes/profile.ts` | 7.1 Identity & accounts |
| `handleUploadWorkRequestFile` | `routes/work-request-files.ts` | 7.4 Execution & workflows |
| `handleUploadWorkRequestInput` | `routes/work-request-inputs.ts` | 7.3 Threads & conversation |
| `handleUploadWorkerOutputImage` | `routes/worker-output-images.ts` | 7.4 Execution & workflows |
| `handleUserBackendToken` | `backend-token.ts` | 8 Stays on Cloudflare |
| `handleValidateV9WorkerProfile` | `routes/profile-admin.ts` | 7.6 Catalog, releases & admin |
| `handleValidateWorkRequest` | `routes/work-creation.ts` | 7.4 Execution & workflows |
| `handleWorkerUsage` | `routes/workspaces-management.ts` | 7.4 Execution & workflows |
| `handleWorkflowConfigurations` | `routes/workflow-configurations.ts` | 7.4 Execution & workflows |
| `handleWorkflowDefault` | `routes/workflow-default.ts` | 7.4 Execution & workflows |
| `handleWorkflowWorkspace` | `routes/workflow-workspace.ts` | 7.4 Execution & workflows |
| `handleWorkspaceBackendToken` | `backend-token.ts` | 8 Stays on Cloudflare |
| `handleWorkspaceDeliveryProbe` | `routes/workspaces-management.ts` | 7.4 Execution & workflows |
| `handleWorkspaceGatewayConnect` | `routes/workspaces-runtime.ts` | 7.4 Execution & workflows |
| `handleWorkspaceInvitations` | `routes/workspace-invitations.ts` | 7.2 Spaces & people |
| `handleWorkspaceMcpAction` | `routes/mcp-action.ts` | 7.4 Execution & workflows |
| `handleWorkspaceMcpInventory` | `routes/mcp-inventory.ts` | 7.4 Execution & workflows |
| `handleWorkspaceMcpToolCallStatus` | `routes/mcp-tool-call.ts` | 7.4 Execution & workflows |
| `handleWorkspaceMemberAccess` | `routes/workspace-member-access.ts` | 7.4 Execution & workflows |
| `handleWorkspacePluginPin` | `routes/worker-plugins.ts` | 7.4 Execution & workflows |
| `handleWorkspaceRuntimeTransport` | `routes/workspaces-runtime.ts` | 7.4 Execution & workflows |
| `handleWorkspaceWorkerPreferences` | `routes/workspace-worker-preferences.ts` | 7.4 Execution & workflows |

## Tables (91)

| Table | Referenced by | Port slice |
| --- | --- | --- |
| `account_execution_waiters` | 3 files | 7.1 Identity & accounts |
| `account_plans` | 2 files | 7.1 Identity & accounts |
| `account_worker_plugin_versions` | 1 files | 7.4 Execution & workflows |
| `account_worker_plugins` | 1 files | 7.4 Execution & workflows |
| `artifacts` | 7 files | 7.4 Execution & workflows |
| `auth_accounts` | 1 files | 7.1 Identity & accounts |
| `auth_audit_events` | 1 files | 7.1 Identity & accounts |
| `auth_sessions` | 2 files | 7.1 Identity & accounts |
| `auth_step_up_events` | 2 files | 7.1 Identity & accounts |
| `auth_step_up_sessions` | 2 files | 7.1 Identity & accounts |
| `auth_verifications` | 1 files | 7.1 Identity & accounts |
| `conversation_history_entries` | 7 files | 7.3 Threads & conversation |
| `conversation_turns` | 6 files | 7.3 Threads & conversation |
| `conversation_user_messages` | 0 files | — unused → drop |
| `conversation_work_requests` | 6 files | 7.3 Threads & conversation |
| `conversation_workflow_runs` | 3 files | 7.3 Threads & conversation |
| `conversation_workflow_step_runs` | 2 files | 7.3 Threads & conversation |
| `conversations` | 8 files | 7.3 Threads & conversation |
| `desktop_auth_intents` | 2 files | 7.1 Identity & accounts |
| `desktop_human_sessions` | 3 files | 7.1 Identity & accounts |
| `direct_space_user_state` | 5 files | 7.2 Spaces & people |
| `direct_spaces` | 7 files | 7.2 Spaces & people |
| `discussion_messages` | 8 files | 7.3 Threads & conversation |
| `execution_workspaces` | 29 files | 7.4 Execution & workflows |
| `issue_report_diagnostics` | 2 files | 7.6 Catalog, releases & admin |
| `issue_report_events` | 1 files | 7.6 Catalog, releases & admin |
| `issue_report_groups` | 1 files | 7.6 Catalog, releases & admin |
| `issue_reports` | 2 files | 7.6 Catalog, releases & admin |
| `mcp_tool_calls` | 1 files | 7.4 Execution & workflows |
| `mutation_receipts` | 1 files | 7.2 Spaces & people |
| `passkeys` | 1 files | 7.1 Identity & accounts |
| `people_relationships` | 4 files | 7.1 Identity & accounts |
| `person_connections` | 5 files | 7.1 Identity & accounts |
| `person_invitations` | 2 files | 7.1 Identity & accounts |
| `realtime_event_cursors` | 1 files | 7.7 Realtime, cron & email |
| `realtime_events` | 4 files | 7.7 Realtime, cron & email |
| `release_signing_key_revocations` | 1 files | 7.6 Catalog, releases & admin |
| `runs` | 27 files | 7.4 Execution & workflows |
| `space_additional_folders` | 4 files | 7.4 Execution & workflows |
| `space_audit_log` | 6 files | 7.4 Execution & workflows |
| `space_invitations` | 4 files | 7.2 Spaces & people |
| `space_memberships` | 23 files | 7.2 Spaces & people |
| `space_workflow_configurations` | 3 files | 7.4 Execution & workflows |
| `space_workflow_defaults` | 4 files | 7.4 Execution & workflows |
| `space_workflow_settings` | 5 files | 7.4 Execution & workflows |
| `spaces` | 34 files | 7.4 Execution & workflows |
| `support_spaces` | 5 files | 7.2 Spaces & people |
| `thread_execution_policies` | 4 files | 7.4 Execution & workflows |
| `thread_read_states` | 2 files | 7.3 Threads & conversation |
| `thread_request_queue` | 2 files | 7.3 Threads & conversation |
| `thread_request_queue_state` | 1 files | 7.3 Threads & conversation |
| `thread_runtime_leases` | 4 files | 7.4 Execution & workflows |
| `thread_work_configs` | 2 files | 7.3 Threads & conversation |
| `threads` | 26 files | 7.4 Execution & workflows |
| `user_blocks` | 4 files | 7.1 Identity & accounts |
| `user_file_reservations` | 2 files | 7.4 Execution & workflows |
| `user_files` | 3 files | 7.4 Execution & workflows |
| `user_notes` | 1 files | 7.2 Spaces & people |
| `user_notification_reads` | 1 files | 7.2 Spaces & people |
| `user_pins` | 4 files | 7.2 Spaces & people |
| `user_workflow_configurations` | 3 files | 7.4 Execution & workflows |
| `user_workflow_defaults` | 3 files | 7.4 Execution & workflows |
| `user_workflow_settings` | 1 files | 7.4 Execution & workflows |
| `users` | 25 files | 7.1 Identity & accounts |
| `work_request_inputs` | 1 files | 7.3 Threads & conversation |
| `work_requests` | 27 files | 7.4 Execution & workflows |
| `worker_activity_history` | 3 files | 7.5 Workspace runtime |
| `worker_assignments` | 28 files | 7.4 Execution & workflows |
| `worker_catalog` | 9 files | 7.4 Execution & workflows |
| `worker_profile_history` | 5 files | 7.6 Catalog, releases & admin |
| `worker_profiles` | 5 files | 7.6 Catalog, releases & admin |
| `worker_scheduling` | 4 files | 7.4 Execution & workflows |
| `worker_scheduling_audit` | 0 files | — unused → drop |
| `workflow_task_dependencies` | 5 files | 7.3 Threads & conversation |
| `workflow_tasks` | 17 files | 7.4 Execution & workflows |
| `workspace_allowed_folders` | 4 files | 7.5 Workspace runtime |
| `workspace_audit_log` | 5 files | 7.4 Execution & workflows |
| `workspace_installations` | 2 files | 7.4 Execution & workflows |
| `workspace_invitations` | 1 files | 7.2 Spaces & people |
| `workspace_member_access` | 1 files | 7.4 Execution & workflows |
| `workspace_member_overrides` | 2 files | 7.4 Execution & workflows |
| `workspace_person_grants` | 6 files | 7.4 Execution & workflows |
| `workspace_releases` | 1 files | 7.6 Catalog, releases & admin |
| `workspace_runtime_facts` | 4 files | 7.4 Execution & workflows |
| `workspace_runtime_identities` | 6 files | 7.4 Execution & workflows |
| `workspace_service_readiness` | 1 files | 7.5 Workspace runtime |
| `workspace_sessions` | 3 files | 7.5 Workspace runtime |
| `workspace_space_grants` | 15 files | 7.4 Execution & workflows |
| `workspace_worker_inventory` | 13 files | 7.4 Execution & workflows |
| `workspace_worker_plugin_enablements` | 5 files | 7.4 Execution & workflows |
| `workspace_worker_preferences` | 1 files | 7.4 Execution & workflows |

## Triggers (49) → PL/pgSQL or application invariants

| Trigger | Table |
| --- | --- |
| `establish_people_on_membership` | `space_memberships` |
| `trg_assignment_context_snapshot_immutable` | `worker_assignments` |
| `trg_assignment_execution_selection_immutable` | `worker_assignments` |
| `trg_conversation_history_immutable` | `conversation_history_entries` |
| `trg_conversation_history_no_delete` | `conversation_history_entries` |
| `trg_conversation_identity_immutable` | `conversations` |
| `trg_conversation_request_immutable` | `conversation_work_requests` |
| `trg_conversation_revisions_monotonic` | `conversations` |
| `trg_conversation_turn_assignment_insert` | `worker_assignments` |
| `trg_conversation_turn_assignment_status` | `worker_assignments` |
| `trg_conversation_turn_context_boundary_insert` | `conversation_turns` |
| `trg_conversation_turn_identity_immutable` | `conversation_turns` |
| `trg_conversation_turn_lifecycle_guard` | `conversation_turns` |
| `trg_conversation_turn_step_run_immutable` | `conversation_turns` |
| `trg_conversation_turn_step_run_insert` | `conversation_turns` |
| `trg_conversation_turn_workflow_run_immutable` | `conversation_turns` |
| `trg_conversation_turn_workflow_run_insert` | `conversation_turns` |
| `trg_conversation_user_message_immutable` | `conversation_user_messages` |
| `trg_conversation_user_message_insert` | `conversation_work_requests` |
| `trg_conversation_workflow_run_immutable` | `conversation_workflow_runs` |
| `trg_conversation_workflow_run_message_insert` | `conversation_user_messages` |
| `trg_conversation_workflow_run_scope_insert` | `conversation_workflow_runs` |
| `trg_history_artifact_created` | `artifacts` |
| `trg_history_artifact_removed` | `artifacts` |
| `trg_history_context_revision` | `conversations` |
| `trg_history_execution_created` | `conversation_turns` |
| `trg_history_execution_status` | `conversation_turns` |
| `trg_history_request_accepted` | `conversation_work_requests` |
| `trg_history_request_status` | `work_requests` |
| `trg_history_run_created` | `runs` |
| `trg_history_run_status` | `runs` |
| `trg_history_step_created` | `workflow_tasks` |
| `trg_history_step_status` | `workflow_tasks` |
| `trg_history_user_message` | `conversation_user_messages` |
| `trg_history_worker_response` | `conversation_turns` |
| `trg_request_ai_generation` | `work_requests` |
| `trg_thread_discussion_contributor` | `discussion_messages` |
| `trg_thread_request_contributor` | `work_requests` |
| `trg_workflow_run_first_start_immutable` | `conversation_workflow_runs` |
| `trg_workflow_run_initial_lifecycle` | `conversation_workflow_runs` |
| `trg_workflow_run_request_lifecycle` | `work_requests` |
| `trg_workflow_step_run_immutable` | `conversation_workflow_step_runs` |
| `trg_workflow_step_run_run_insert` | `conversation_workflow_runs` |
| `trg_workflow_step_run_scope_insert` | `conversation_workflow_step_runs` |
| `trg_workflow_step_run_task_insert` | `workflow_tasks` |
| `validate_direct_space_general_thread` | `direct_spaces` |
| `validate_direct_space_general_thread_update` | `direct_spaces` |
| `worker_catalog_origin_invariants_insert` | `worker_catalog` |
| `workspace_space_grant_status_transition_valid` | `workspace_space_grants` |

## SQLite-specific SQL to rewrite

| File | Sites |
| --- | --- |
| `routes/conversation-workflow-step-runs.ts` | 11 |
| `routes/work-lifecycle.ts` | 10 |
| `routes/work-request-files.ts` | 9 |
| `routes/conversation-turns.ts` | 9 |
| `routes/user-files.ts` | 5 |
| `routes/notifications.ts` | 4 |
| `routes/implement-plan.ts` | 4 |
| `routes/people.ts` | 4 |
| `worker-profile-registry.ts` | 3 |
| `routes/conversation-workflow-runs.ts` | 3 |
| `routes/conversation-bootstrap.ts` | 3 |
| `routes/spaces.ts` | 3 |
| `routes/workspaces-registration.ts` | 3 |
| `routes/thread-request-queue.ts` | 2 |
| `routes/threads.ts` | 2 |
| `routes/thread-activity.ts` | 2 |
| `routes/home.ts` | 2 |
| `mcp-tool-dispatch-claim.ts` | 1 |
| `workflow.ts` | 1 |
| `people.ts` | 1 |
| `event-publisher.ts` | 1 |
| `realtime-gateway.ts` | 1 |
| `workspace-gateway.ts` | 1 |
| `workspace-gateway/inventory.ts` | 1 |
| `routes/releases.ts` | 1 |
| `routes/notes.ts` | 1 |
| `routes/pins.ts` | 1 |
| `routes/reply-references.ts` | 1 |
| `routes/workspace-access.ts` | 1 |

## Cloudflare bindings → replacements

| Binding | Used in files | Replacement |
| --- | --- | --- |
| `SYNTILA_DB` | 69 | PostgreSQL via pg-d1 adapter |
| `SYNTILA_THREAD_COORDINATOR` | 7 | in-process coordinator + PostgreSQL locks |
| `SYNTILA_RUN_WORKFLOW` | 6 | PostgreSQL durable workflow runner |
| `SYNTILA_EMAIL` | 4 | Cloudflare email relay |
| `SYNTILA_WORKSPACE_GATEWAY` | 12 | in-process WorkspaceGateway service |
| `SYNTILA_REALTIME_GATEWAY` | 6 | in-process realtime gateway on Bun pub/sub |
| `SYNTILA_ARTIFACTS` | 10 | Bun.S3Client → R2 |
| `waitUntil` | 1 | tracked background promise queue |

## Scheduled jobs

| Schedule | Jobs |
| --- | --- |
| every 5 min | recoverStaleAssignments, sweepUnsignaledTerminals, sweepStaleExecutionWaiters, sweepExpiredUploadReservations, sweepThreadRequestQueues |
| daily 03:17 UTC | + pruneExpiredRealtimeEvents, pruneWorkerActivityHistory, pruneExpiredIssueReports (and the rest of `index.ts` scheduled) |

