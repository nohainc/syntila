# History Triggers Migration Plan (Package 4 — Analysis Only)

Status: **Analysis only — no triggers, migrations, or product behavior changed.**

## 1. Active Trigger Inventory

Reconstructed from `apps/backend/migrations/0001_initial.sql` through `0022_plan_approvals.sql`:
- `0015_drop_unused_tables.sql` dropped `trg_history_artifact_created` and `trg_history_artifact_removed` (on `artifacts`).
- `0021_active_access_excludes_invitation.sql` added `workspace_invitations_no_active_grant` and `workspace_person_grants_expire_invitations`.

### 1a. History Writers (`trg_history_*`, active)
| Trigger | Table | Event | Writes / Purpose | Primary Code Writers (per `docs/backend/WRITE_PATHS.md` & `src/domain/`) |
|---|---|---|---|---|
| `trg_history_context_revision` | `conversations` | `AFTER UPDATE OF context_revision` | Appends `context.revision_advanced` to `conversation_history_entries` | `thread-coordinator.ts`, `work-lifecycle.ts`, `spaces.ts` |
| `trg_history_execution_created` | `conversation_turns` | `AFTER INSERT` | Appends `execution.created` | `thread-coordinator.ts`, `assignment-dispatcher.ts` |
| `trg_history_execution_status` | `conversation_turns` | `AFTER UPDATE OF status` | Appends `execution.started` / `execution.completed` / `execution.failed` | `workspace-gateway.ts`, `thread-coordinator.ts`, `realtime-retention.ts` |
| `trg_history_request_accepted` | `work_requests` | `AFTER INSERT` | Appends `workflow.request_accepted` | `work-creation.ts`, `thread-request-queue.ts`, `implement-plan.ts` |
| `trg_history_request_status` | `work_requests` | `AFTER UPDATE OF status` | Appends `workflow.request_status_changed` | `work-lifecycle.ts`, `thread-coordinator.ts`, `workspace-gateway.ts` |
| `trg_history_run_created` | `runs` | `AFTER INSERT` | Appends `workflow.run_created` | `work-creation.ts`, `work-lifecycle.ts` |
| `trg_history_run_status` | `runs` | `AFTER UPDATE OF status` | Appends `workflow.run_status_changed` | `work-lifecycle.ts`, `thread-coordinator.ts` |
| `trg_history_step_created` | `workflow_tasks` | `AFTER INSERT` | Appends `workflow.step_created` | `work-creation.ts`, `workflow.ts` |
| `trg_history_step_status` | `workflow_tasks` | `AFTER UPDATE OF status` | Appends `workflow.step_status_changed` | `work-lifecycle.ts`, `workspace-gateway.ts`, `assignment-dispatcher.ts` |
| `trg_history_user_message` | `conversation_user_messages` | `AFTER INSERT` | Appends `message.user_created` | `trg_conversation_user_message_insert_fn` (cascaded from `conversation_work_requests`) |
| `trg_history_worker_response` | `conversation_turns` | `AFTER UPDATE OF status` | Appends `message.worker_created` on completion | `workspace-gateway.ts`, `thread-coordinator.ts` |

### 1b. Integrity Guards (Stay in Database)
- Immutability & append-only guards: `trg_assignment_context_snapshot_immutable`, `trg_assignment_execution_selection_immutable`, `trg_conversation_history_immutable`, `trg_conversation_history_no_delete`, `trg_conversation_identity_immutable`, `trg_conversation_request_immutable`, `trg_conversation_turn_identity_immutable`, `trg_conversation_turn_step_run_immutable`, `trg_conversation_turn_workflow_run_immutable`, `trg_conversation_user_message_immutable`, `trg_conversation_workflow_run_immutable`, `trg_work_requests_snapshot_immutable`, `trg_workflow_run_first_start_immutable`, `trg_workflow_step_run_immutable`.
- Monotonic & lifecycle guards: `trg_conversation_revisions_monotonic`, `trg_conversation_turn_context_boundary_insert`, `trg_conversation_turn_lifecycle_guard`, `trg_workflow_step_run_scope_insert`, `validate_direct_space_general_thread`, `validate_direct_space_general_thread_update`, `worker_catalog_origin_invariants_insert`, `workspace_space_grant_status_transition_valid`, `workspace_invitations_no_active_grant`.

### 1c. Derived-State / Lifecycle Triggers
- `establish_people_on_membership` (`space_memberships`), `workspace_person_grants_expire_invitations` (`workspace_person_grants`), `trg_request_ai_generation` (`work_requests`), `trg_thread_discussion_contributor` (`discussion_messages`), `trg_thread_request_contributor` (`work_requests`), `trg_conversation_turn_assignment_insert` / `_status` (`worker_assignments`), `trg_conversation_user_message_insert` (`conversation_work_requests`), `trg_conversation_workflow_run_message_insert` (`conversation_user_messages`), `trg_workflow_run_initial_lifecycle` / `_request_lifecycle` (`conversation_workflow_runs`, `work_requests`), `trg_workflow_step_run_run_insert` / `_task_insert` (`conversation_workflow_runs`, `workflow_tasks`).

## 2. Classification & Invariants to Preserve
- **Keep in DB**: All integrity guards (1b). They are cheap, protect against application bugs, and enforce invariants regardless of which writer touches the table.
- **Candidate to move to code**: The 11 active `trg_history_*` writers (1a).
- **Invariants code must preserve if moved**:
  1. **Gap-free, monotonic `sequence` numbering** per conversation under parallel writes (currently serialized by the DB trigger/sequence).
  2. **Atomic history creation**: every state transition (`INSERT`/`UPDATE`) and its history row must commit or roll back together in the same transaction.
  3. **Cascade coverage**: `trg_history_user_message` fires via `trg_conversation_user_message_insert`; moving it to code requires every `conversation_work_requests` writer to also write the history entry.

## 3. Golden History Test Audit
- **Existing coverage**: `apps/backend/test/journey.test.ts` (end-to-end golden conversation history), `apps/backend/test/domain/conversation-history.test.ts`, and `history-cascade.test.ts` verify sequential happy-path history ordering and cascade invariants.
- **Missing scenarios to add BEFORE any move**:
  1. **Parallel writes**: concurrent status transitions / turn completions on the same conversation verifying gap-free `sequence` ordering.
  2. **Retries & rollbacks**: failed `work-lifecycle` retry or rolled-back transaction leaving zero orphan history rows.
  3. **Revocations & retention**: `realtime-retention.ts` / `worker-activity-history.ts` cleanup and grant revocation paths.
  4. **Clear work history**: `work-history/clear` behavior against `trg_conversation_history_no_delete`.

## 4. Migration Order & Rollback
1. **Add missing golden/parallel tests** (separate test-only commit).
2. **Shadow-write phase**: write candidate history rows in code to a separate shadow table/log while triggers remain active; compare shadow output vs `conversation_history_entries` on representative data copies.
3. **One-trigger-at-a-time cutover**: disable/drop one `trg_history_*` trigger per migration only after 100% shadow parity is proven; start with leaf events (`trg_history_worker_response`, `trg_history_run_status`) before cascaded ones (`trg_history_user_message`).
4. **Rollback**: re-enable/recreate the dropped trigger in a forward migration; because `conversation_history_entries` is append-only, no data is lost.

## 5. Recommendation
**Keep all integrity guards and derived-state triggers in PostgreSQL. Move only the 11 `trg_history_*` writers into application code when the work core (`work-creation.ts`, `work-lifecycle.ts`, `thread-coordinator.ts`, `workspace-gateway.ts`) is next reworked**, and only after adding the parallel/retry/clear-history tests and completing a shadow-write parity check.
