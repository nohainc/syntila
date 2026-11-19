# Worker-first P0 inventory: Workspace Service features the Agent must inherit

- **Status:** P0 deliverable, input to P3/P4 (ADR-034). Date: 2026-11-19.
- **Method:** module list read from `apps/workspace/lib` and `bin` (33,060 lines in 102 files), test names from `apps/workspace/test`, behavior from `docs/architecture/WORKSPACE_ARCHITECTURE.md` and `docs/specifications/WORKER_AGENT_RUNTIME_V1.md`. Module names and sizes were read from disk; "Agent must" statements restate the contracts in those documents and ADR-034. Nothing here was run.
- **Companion:** `WORKER_FIRST_P0_INVENTORY.md` (backend tables, foreign keys, routes).

## Correction to the extraction map

`WORKER_AGENT_RUNTIME_V1.md` section 11 names modules that do not exist under those names. Use this mapping when planning P3/P4:

| Named in the spec | What exists today |
| --- | --- |
| `workspace_runtime.dart` | `workspace.dart` (class `WorkspaceRuntime`, 461 lines) and `workspace_runtime.dart` (1,236 lines) |
| `workspace_cloud_connection.dart` | `cloud_connection.dart` (class `WorkspaceCloudConnection`, 2,838 lines), `cloud_connection/assignment_handlers.dart` (902), `websocket_workspace_transport.dart`, `workspace_transport.dart` |
| `assignment_journal.dart` | exists (420 lines) |
| `cli_worker_engine_supervisor.dart` | exists but is a 9-line re-export; supervision lives in `worker_executor.dart` (868), `worker_launch_plan.dart`, `process_tree.dart` |
| `local_worker_registry.dart` | exists (813 lines) |
| `workspace_cli.dart` | exists (1,661 lines) with `workspace_cli_spec.dart` (1,017) |

Entry points: `bin/syntila_workspace.dart`, `bin/syntila_workspace_cli.dart`, `bin/syntila_workspace_service.dart`.

## Feature inventory

"Per Worker" means the Agent must hold it once per Worker Instance. "Per host" means it can stay shared by the optional local Manager.

| # | Feature | Where it lives today | Existing tests | Agent must | Scope |
| --- | --- | --- | --- | --- | --- |
| 1 | **Registration and identity** | `workspace_registration.dart`, `workspace_registration_models.dart`, `desktop_auth.dart`, `workspace_headless_auth.dart`, `workspace_settings.dart`, `friendly_computer_name.dart` | `installation_identity_test.dart` | Replace Workspace registration with pairing that yields a Worker identity and credential (ADR-032/034). Keep the per-installation identity rule from `AGENTS.md`: never create a replacement identity as a migration shortcut. Drop the machine name as a product field (ADR-035 D3). | Per Worker (credential), per host (installation id) |
| 2 | **Cloud connection and transport** | `cloud_connection.dart`, `websocket_workspace_transport.dart`, `workspace_transport.dart`, `workspace_connection_stage.dart`, `durable_sync.dart` | `cloud_connection_test.dart`, `cloud_connection_assignment_test.dart`, `cloud_connection_permits_test.dart` | One WSS connection per Worker with resume cursor and epoch fencing (ADR-034). Keep idle-socket keepalive behavior (commit `99517215` kept idle WebSocket Workspaces online). | Per Worker |
| 3 | **Readiness and verification** | `worker_readiness.dart`, `runtime_capabilities.dart`, `worker_check_progress.dart`, `workspace_worker_view.dart`, `worker_inventory_projection.dart` | `cli_worker_engine_readiness_test.dart`, `capability_lifecycle_test.dart`, `runtime_capabilities_test.dart`, `headless_capability_publication_test.dart` | Report `enabled`, `online`, `ready` separately. Preserve the rule that Cloud registration never implies local readiness and that a downloaded Profile can stay blocked with a retained issue. | Per Worker |
| 4 | **Worker Engine supervision** | `worker_executor.dart`, `worker_launch_plan.dart`, `process_tree.dart`, `bundled_cli_worker_engine_loader.dart`, `assignment_execution_failure.dart` | `cli_worker_engine_supervisor_test.dart`, `process_tree_test.dart`, `bundled_cli_worker_engine_loader_test.dart` | Keep the Engine a separately supervised child started on demand, one process supervisor, orphan recovery on start, bounded slots per Agent. Engine must keep importing no Cloud, Space, Thread, Workflow or UI code (`AGENTS.md`). | Per Worker |
| 5 | **Profiles and catalog** | `tool_profile_catalog.dart`, `tool_profile_resolver.dart`, `tool_profile_release_verifier.dart`, `worker_profile_store.dart`, `worker_catalog_coordinator.dart`, `worker_trust_policy.dart`, `release_trust_roots.dart`, `development_tool_profiles.dart` | `tool_profile_release_verifier_test.dart`, `tool_profile_v9_workspace_test.dart`, `tool_profile_assignment_acceptance_test.dart`, `development_tool_profiles_test.dart`, `trust_policy_test.dart` | Verify signed Tool Profiles with the same trust roots; keep per-Worker refresh (`workers.refreshWorker` with `workerTypeId`) and model discovery. Profile content is shared per host, activation is per Worker. | Per host (store), per Worker (activation) |
| 6 | **Assignment journal and recovery** | `assignment_journal.dart`, `assignment_startup.dart`, `assignment_trace.dart`, `durable_sync.dart` | `assignment_journal_test.dart`, `assignment_trace_test.dart`, `thread_end_to_end_acceptance_test.dart` | Scope the journal to the Worker Instance, keep attempt recovery and durable terminal acknowledgement, and add the fence (assignment, run, attempt, session epoch) from ADR-034. Crash/reconnect matrix in `WORKER_AGENT_RUNTIME_V1.md` section 5. | Per Worker |
| 7 | **MCP host and tool calls** | `mcp_service.dart`, `mcp_registry.dart`, `mcp_subsystem.dart`, `mcp_engine_probe.dart`, `mcp_action_handler.dart`, `mcp_inventory_publisher.dart`, `mcp_tool_call_*.dart`, `workspace_cli_mcp.dart`, `workspace_manager_mcp.dart` | `mcp_*_test.dart` (11 files) | Keep inventory publication, the tool-call fence and the management IPC (`MCP_MANAGEMENT_IPC_V1.md`). Backend routes `/api/workspaces/:id/mcp-inventory` and `mcp-action` are keyed by Workspace and must be re-keyed by Worker (P5). | Per host (servers), per Worker (enablement, fence) |
| 8 | **Custom Worker plugins** | `external_worker_*.dart` (9 files), `workspace_cli_external_workers.dart`, `workspace_manager_external_workers.dart` | `local_worker_registry_test.dart`, `local_worker_setup_test.dart`; plugin acceptance in `scripts/plugin-isolation-acceptance.mjs` | Keep the plugin host and isolation (ADR-027). Backend tables `workspace_worker_plugin_enablements` and routes `/api/workspaces/:id/worker-plugins/:ref` move to Worker scope. | Per host (plugin store), per Worker (enablement) |
| 9 | **Allowed folders and Work Root** | `allowed_folders.dart`, `local_worker_permissions.dart`, `work_root.dart`, `workspace_paths.dart`, `space_directory.dart`, `thread_directory.dart`, `thread_filesystem.dart`, `thread_path.dart`, `thread_marker.dart`, `thread_cleanup.dart`, `thread_repository_observability.dart` | `allowed_folders_test.dart`, `thread_*_test.dart` (9 files), `full_local_access_host_acceptance_test.dart` | Keep host authority over folders; the backend only stores display names and status (`workspace_allowed_folders`, `space_additional_folders`). ADR-037 changes cross-Worker file handoff, not local folder rules. | Per host |
| 10 | **Input delivery and outputs** | `input_delivery.dart`, `work_request_input_staging.dart`, `worker_output_images.dart` | `provider_failure_engine_delivery_test.dart` | Keep staged inputs with delivered/attempt acknowledgements (`INPUT_DELIVERY_V1.md`). Routes `/api/workspace-runtime/inputs*` and `/outputs` are Workspace-keyed today. | Per Worker |
| 11 | **Diagnostics and provider-failure records** | `diagnostics.dart`, `worker_diagnostic_store.dart`, `provider_failure_cipher.dart` | `diagnostics_test.dart`, `provider_failure_platform_store_test.dart` | Keep the privacy rules in `DIAGNOSTIC_EVENTS_V1.md` (no prompts, output, credentials or local paths in exports). | Per host |
| 12 | **Service on macOS** | `macos_service_manager.dart`, `workspace_background_service.dart` (`WorkspaceServiceManager`), `workspace_service_lifecycle.dart`, `workspace_lifecycle*.dart` | `capability_lifecycle_test.dart` | Keep service registration behind `WorkspaceServiceManager`; launchd specifics stay in the platform adapter. | Per host |
| 13 | **Service on Linux** | `linux_service_manager.dart`, `linux_credentials.dart` | `linux_runtime_test.dart` | systemd user service per ADR-021. | Per host |
| 14 | **Service on Windows** | `windows_service_manager.dart`, `windows_credentials.dart`, `windows_native.dart` | `windows_runtime_test.dart`, `windows_service_lifecycle_test.dart`, `windows_service_manager_test.dart` | Service Control Manager per ADR-021. Windows is a runtime candidate (`WORKSPACE_ARCHITECTURE.md`). | Per host |
| 15 | **Credentials** | `secure_credentials.dart`, `credential_backend.dart`, `linux_credentials.dart`, `windows_credentials.dart` | `provider_failure_platform_store_test.dart` | Store the Worker credential in the platform secret store; never in plaintext tables or files (`AGENTS.md` rule 8). | Per Worker |
| 16 | **Sleep and power** | `sleep_inhibitor.dart`, `platform_runtime.dart` | `sleep_inhibitor_test.dart` | Keep sleep inhibition while an assignment runs. | Per host |
| 17 | **Self-update** | `self_update.dart`, `release_trust_roots.dart` | `self_update_test.dart`; release workflows in `.github/workflows/release-*.yml`, `promote-workspace-release.yml` | Keep signed update verification and the release channel; backend tables `workspace_releases` and routes `/api/workspace-releases/*` are host-level, not Worker-level, and may stay. | Per host |
| 18 | **Local management IPC and CLI** | `local_management_transport.dart`, `workspace_manager_ipc.dart`, `workspace_manager_service.dart`, `workspace_cli.dart`, `workspace_cli_spec.dart`, `workspace_configuration.dart` (`workspace.nano`) | `mcp_cli_ipc_test.dart` | Extract `syntila-worker` commands; keep the CLI a pure client that never spawns an Engine or opens a Cloud connection. Configuration is restart-applied. | Per host, with per-Worker commands |

## Backend objects the Agent contract touches

These are not Workspace Service features but they bind to them, and each is a Phase-P1/P5 decision:

- `workspace_runtime_identities`, `workspace_sessions`, `workspace_installations`, `workspace_runtime_facts`: replaced by Worker credential and session epoch (ADR-034). `workspace_runtime_facts` holds `hostname`, `platform`, `architecture`; ADR-035 D3 removes host fields from the product model, keeping only agent version and session diagnostics.
- `worker_assignments.execution_workspace_id` and `runtime_identity_id`: both NOT NULL today (P1 adds `worker_instance_id` nullable, P5 relaxes these).
- `workspace_worker_inventory`: source for backfilling Worker Instances (P1).

## Gaps found

1. The extraction map in `WORKER_AGENT_RUNTIME_V1.md` is stale (table above); fix it when P3 starts.
2. No parity test list exists that says which of the 18 features a standalone Agent must demonstrate. Proposed gate for P4: features 1 to 6 and 15 on a host with no Workspace Service installed; features 7 to 10 and 17 before Worker-first GA.
3. Windows features (14) have tests but `WORKSPACE_ARCHITECTURE.md` calls Windows a runtime candidate; decide in P4 whether the Agent ships on Windows at GA.
