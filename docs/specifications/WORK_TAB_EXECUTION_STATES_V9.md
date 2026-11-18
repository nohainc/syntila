# Work tab execution states (V9 Phase 7)

The Work tab now shows where a request really is: delivered, waiting for a Worker slot, starting the provider, or running. Cloud derives the state from the assignment's recorded evidence and the app only renders it.

## Execution phase

Cloud computes `executionPhase` per step from the latest `worker_assignments` row and returns it in the Work Request read model (single request and thread list), plus a request-level `executionPhase`. `work_requests.status` is unchanged: it still turns `running` when the Workflow starts, which is why it must not drive the Worker status.

| Phase | Evidence | Label | Sub-line |
| --- | --- | --- | --- |
| submitted | no assignment | Submitted | Request received by Syntila |
| waiting_for_service | status `created` | Queued | Waiting for the Workspace Service to be ready |
| delivering | `dispatched` | Queued | Request delivered to Syntila Service |
| delivered | `acknowledged`, no queue/permit evidence | Queued | Command received · Worker accepted request |
| queued | `acknowledged` + permit required or startup stage waiting/queued | Queued | All parallel slots are busy; starting when one is free |
| starting | start permit issued, or stage slot_reserved/engine_spawned/engine_initialized | Starting | Starting provider CLI |
| running | assignment status `running` only | Running | – |
| completed / failed / cancelled | terminal assignment status | Completed / Failed / Cancelled | – |
| uncertain | `revocation_pending` / `reconciling` | Checking | Checking whether execution is still active |

Running is shown only when the provider start was observed (`running_at`). A terminal Work Request status always wins at request level.

## Failure categories

`failureCategory` and `failureCategoryMessage` are a separate, derived field. The 11 existing public error codes are untouched. Categories come from the assignment timeline (which phase it never left) and the canonical error code, never from elapsed time or message text, and only Cloud-authored diagnostics are read.

| Category | Message |
| --- | --- |
| service_unavailable | Workspace Service is offline |
| sync_incomplete | Workspace is reconnecting |
| worker_unavailable | Worker is not ready |
| capacity_exceeded | No Worker slot became free in time. Retry when another request finishes |
| profile_incompatible | Worker Profile is incompatible |
| space_folder_confirmation_required | A folder with this Space's name already exists and is not empty |
| provider_start_failed | AI provider could not start |
| startup_timeout | Worker startup timed out |
| execution_failed | Worker execution failed |
| state_uncertain | Checking whether execution is still active |

Local diagnostics (`localDiagnostic`, Service diagnostic text) never appear in these fields; they stay in the authorized diagnostic tools.

## Retry

Each failed step carries `retry: {allowed, requiresConfirmation}`.

- Safe (no confirmation): the provider provably never started, meaning no start permit, no engine spawned and no `running_at`.
- Needs confirmation: a start permit was issued, the engine was spawned, the step ran, or a revocation began while it was running.
- Not allowed: the stop is unconfirmed (`revocation_pending` / `reconciling`).

The retry endpoint enforces this server-side. An unconfirmed stop returns 409. A step that needs confirmation returns 409 `retry_confirmation_required` unless the body has `confirmSideEffects: true`. The app shows Retry, or Retry anyway with a confirmation dialog.

## Realtime and reconnect

A new durable `step.phase` event (payload `status` carries the phase, `assignmentId` is on the envelope) is published at dispatch, admission, start-permit grant, startup progress and provider start. Terminal outcomes continue to use `step.completed/failed/cancelled`.

The app applies a pushed phase only when it moves strictly forward on the same assignment. Delayed older phases are dropped. Terminal, uncertain, unknown-assignment events and events for a terminal request trigger an authoritative re-read. The existing reconnect resync already re-reads active requests, so state after a reconnect comes from Cloud and not from the last activity event. State is per request, so concurrent requests keep independent status.

## Deploy order

Deploy Cloud first (additive fields and the new event type; older apps ignore them), then the app. Regenerate protocol bindings after the schema change.

## Verification

- Cloud: `execution-phase.test.ts` (phase mapping, categories, retry advice, request-level terminal-wins, no diagnostic leakage).
- App: `ax_execution_phase_test.dart` (forward-only advance, terminal wins, parsing, never Running before provider start).

## Waiting for the Service to be ready

When the Service is offline or still synchronizing, the Workflow parks the request ("Waiting for the Workspace Service to be ready"; no assignment exists yet) and re-dispatches every 15 s. A Service that reports ready also wakes these requests immediately (`wakeWorkspaceReadyWaiters`, called from the Gateway when readiness becomes ready), so the wait ends when the Service is ready instead of at the next poll. The poll stays as the durable fallback.
