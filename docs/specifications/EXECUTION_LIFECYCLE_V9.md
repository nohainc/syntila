# Authoritative execution lifecycle — V9

**Status:** Implemented lifecycle contract; release acceptance is tracked in
[execution acceptance](../acceptance/EXECUTION_RELIABILITY_V9.md).

## Authority

Cloud owns the persisted lifecycle of an assignment, attempt projection, task,
run and Work Request. Workspace owns observed local process/journal state.
The CLI Worker Engine owns provider-process observations. Activity never owns a
terminal transition.

`Recovering` is an operational condition represented by diagnostics and
reconciliation work; it is not a persisted assignment outcome. Cloud retains
the last authoritative state while it waits for Workspace sync or a deadline.

## Assignment state machine

The persisted `worker_assignments.status` column (free text, no CHECK
constraint, so no migration) maps to the lifecycle vocabulary as follows:

| Lifecycle state | Cloud assignment status | Meaning |
| --- | --- | --- |
| Created | `created` | Assignment persisted; no delivery accepted |
| Dispatched | `dispatched` | Gateway queued `assignment.start` on the WebSocket or long-poll queue |
| Acknowledged | `acknowledged` | Service durably accepted it (`assignment.ack`, `accepted: true`) |
| Queued | `acknowledged` (projection) | Service is waiting for local capacity or coordination |
| Starting | `acknowledged` (projection) | Service authorized the launch and is preparing Engine/provider |
| Running | `running` | Explicit `assignment.start.ack` confirmed Engine and provider startup |
| Completed | `completed` | Durable successful terminal result |
| Failed | `failed` | Durable failure terminal result |
| Cancelled | `cancelled` | Durable cancellation outcome |
| Timed out | `timed_out` | Durable deadline outcome, with the canonical `timeout` error code |
| Lost | `lost` | Reserved final outcome for a confirmed unrecoverable execution loss |

Queued and Starting occur inside the Service between admission and the
provider-start acknowledgement. Both retain `acknowledged` as their assignment
status. Capability-gated `assignment.startup` milestones and the start-permit
timestamp distinguish them in Cloud's derived execution phase without a second
lifecycle database. See [Service startup](SERVICE_STARTUP_V9.md) and
[Work tab execution states](WORK_TAB_EXECUTION_STATES_V9.md).

Assignment and attempt transitions are implemented in
[`packages/core/src/execution-lifecycle.ts`](../../packages/core/src/execution-lifecycle.ts).
The current schema projects an attempt through its assignment row, but both
identities use the same fenced transition contract. Terminal states are
monotonic: no activity, acknowledgement, retry or late
terminal message can return them to `running`.

Task, Run and Work Request records retain their existing product status
vocabularies. A task becomes `running` only after startup acknowledgement. A
timed-out assignment converges its task to `failed` with a timeout error; Run
and Work Request projections are finalized by the durable Workflow after the
task result is observed.

## Evidence and ordering

Three kinds of acknowledgement reach Cloud and are never interchangeable
(`assignmentStatusForEvidence`):

| Evidence | Message | Moves toward | Never implies |
| --- | --- | --- | --- |
| Delivery | transport accepted the command | `dispatched` | that the Service saw it |
| Admission | `assignment.ack` (`accepted: true`) | `acknowledged` | that the provider started |
| Provider start | `assignment.start.ack` | `running` | nothing earlier is missing |

Transitions only move forward and may skip milestones, because later evidence
proves earlier milestones: a provider-start acknowledgement proves admission
(a Service cannot start what it did not accept), and a result proves the
provider ran. The allowed edges are exactly the table in
`packages/core/src/execution-lifecycle.ts`; the graph is acyclic and terminal
statuses have no outgoing edges.

Every writer derives its source-status set from that table
(`assignmentSourceStatuses`) and applies the change as one conditional
`UPDATE ... WHERE status IN (...) AND <identity fence> ... RETURNING id`.
The database decides which concurrent handler wins; nothing relies on an
earlier `SELECT`. Consequences:

- A late admission acknowledgement after `assignment.start.ack` (or after any
  terminal state) matches no row. It cannot downgrade `running`, and because
  it writes nothing it cannot refresh `updated_at`, which the startup and
  execution deadlines read.
- A duplicate acknowledgement of any kind is a no-op for the same reason.
- `assignment.start.ack` arriving before admission is honoured from
  `created`/`dispatched`/`acknowledged`, so the start evidence is not lost on
  the HTTP fallback or after a replay.
- An admission **rejection** only fails an assignment that was never accepted
  (`created`/`dispatched`); a stale or replayed rejection cannot fail an
  accepted or running one.
- Only the call whose `RETURNING` row came back reports `applied`. D1
  `meta.changes` counts trigger writes and is never used for this decision.
  Trace events and Workflow task projections key off `applied`.
- Timeout recovery and the Workflow delivery timeout decide from a status they
  read earlier, so their write is conditional on that same status. An
  assignment that advanced since (for example a start acknowledgement arrived
  after the scan) is left alone.
- The identity fence (`attempt_id`, execution Workspace, runtime identity) is
  part of the same statement. Messages from a previous attempt, a previous or
  revoked runtime identity, or another Workspace match no row.

## Message rules

1. `assignment.start` creates no running state.
2. Admission `assignment.ack` moves Cloud only to `acknowledged` and never
   marks the task running.
3. `assignment.start.ack` is emitted only after the generic Engine and provider
   process have launched. It is correlation-checked by Workspace, runtime,
   Worker, run, task, attempt, assignment and idempotency key before Cloud
   moves the assignment to `running`; the task becomes `running` in the same
   handler only if the assignment is Running.
4. `assignment.result`, `assignment.error` and `assignment.cancelled` are
   durable terminal deliveries. Cloud checks the attempt identity before
   applying them and ignores duplicates or stale attempts.
5. Activity and progress are accepted only while the assignment is active.
   A delayed activity event after failure or completion is ignored.
6. A terminal result received before the final activity is valid. The result
   closes the assignment; the late activity cannot reopen it.
7. Terminal statuses are immutable. No reconciliation mechanism rewrites a
   terminal row today; `lost` has no writer yet.

## Service convergence

The Service re-asserts evidence it already owns instead of rejecting replays:

- A duplicate `assignment.start` for an assignment that is live in this process
  (journal `received`, `accepted` or `running`) is answered with an admission
  acknowledgement and, if the provider started, a start acknowledgement.
  Rejecting it (`accepted: false`) would make Cloud fail work in progress.
- On `workspace.sync.result` the Service compares Cloud's status with its live
  assignments. If Cloud is `created`/`dispatched` it re-sends admission; if
  Cloud is behind the local `running` state it re-sends the start
  acknowledgement. Nothing is sent when Cloud is already at or past it.
- After a Service restart the journal marks unfinished work `interrupted`;
  those are not live, are not re-asserted, and are reported as outcome-unknown.

## Durable terminal behavior

Cloud terminal writes are idempotent by `assignmentId` and `attemptId`:

- a duplicate terminal delivery for the current attempt is a no-op after the
  first terminal row is committed;
- a terminal delivery for an earlier attempt cannot modify the newer attempt;
- a terminal assignment cannot have its output, error or status rewritten by a
  later outcome;
- task finalization is conditional on the matching assignment terminal row;
- terminal delivery acknowledgement reflects the persisted Cloud result,
  including mapping Cloud `timed_out` to the compatible local failed-ack shape.

Workspace commits its local terminal journal record before attempting delivery
and retains it until Cloud acknowledgement. A reconnect sends the bounded
active/recent-terminal synchronization window. If a local non-terminal record
was interrupted by restart, Workspace reports outcome-unknown evidence; Cloud
does not infer success.

## Deadlines and recovery

| Phase | Deadline | Owner and action |
| --- | --- | --- |
| Readiness wait (`created`) | Queue-wait limit from `created_at` | Assignment waits durably for the Service to report `readyForAssignments`; nothing is sent. On expiry it is finalized directly (see [Service readiness](SERVICE_READINESS_V9.md)) |
| Research v2 Cloud capacity wait (`created`, `cloud_queue_reason = workspace_capacity`) | No application capacity deadline | Gateway leaves the branch queued without a Workspace execution slot and retries it when capacity is free. Synthesis waits for all reports. If readiness is lost, the bounded readiness clock starts at `cloud_queue_since`; repeated polls do not reset it. Other workflows keep their queue deadline. |
| Command delivery / admission | 30 seconds from the Gateway queueing the command (`dispatched_at`) | Workflow/Cloud revokes the assignment (see [command delivery and revocation](COMMAND_DELIVERY_AND_REVOCATION_V9.md)); the retryable failure is written only when the Service confirms |
| Queue wait, then startup | Queue wait from admission (`acknowledged_at`); 30 seconds startup from the start permit | Workflow/Cloud revokes the assignment if `assignment.start.ack` is absent; outcome written on Service confirmation |
| Provider execution | Assignment/task configured timeout | Workspace stops the process tree; Cloud revokes the assignment and records `timed_out` once the Service confirms the stop |
| Terminal delivery | 10 seconds per local send attempt | Workspace keeps the journal terminal record and retries after reconnect |
| Disconnected runtime reconciliation | 30 seconds after the latest assignment/runtime evidence | Cloud requests revocation and gives sync a chance; uncertain execution remains `reconciling` until stop or terminal evidence arrives |

The configured assignment timeout remains the execution deadline; dispatch and
startup windows do not prove provider execution and do not consume the provider
result authority. Cloud recovery is safe to run repeatedly because terminal
transitions are idempotent.

## Process disappearance without provider terminal output

If the Engine process exits without a mapped provider result or error, the
Workspace supervisor cleans the process tree and emits a normalized failure.
The local journal stores the failure before transport delivery. The failure
includes only bounded safe diagnostic evidence such as a process exit code or
`missing_terminal_event`; provider output and credentials never cross the
boundary. If Workspace itself restarts before that evidence is written, the
assignment is outcome-unknown during reconciliation. A deadline alone cannot
prove the provider stopped or authorize an automatic retry. Cloud retains
revocation/reconciliation ownership until sufficient evidence arrives; `lost`
remains reserved without a writer.

## Acceptance matrix

| Scenario | Required result |
| --- | --- |
| Duplicate completion | One completed assignment; later delivery is a no-op |
| Failure followed by delayed progress | Failure remains final; delayed progress is ignored |
| Result before last activity | Result remains authoritative; activity may be dropped |
| Service reconnect with unfinished assignment | Sync reconciles the journal; no success is guessed |
| Process exit without provider terminal | Durable normalized failure or outcome-unknown recovery, never indefinite running |
| Cloud receives stale previous-attempt event | Identity check rejects it; current attempt is unchanged |
| Acceptance acknowledgement after provider start | Assignment stays `running`; `updated_at` unchanged |
| Two handlers race on one assignment | One conditional update wins; the other reports a non-applied outcome |
| Provider start before admission | Honoured; assignment becomes `running` |
| Late start acknowledgement after cancellation | Ignored; assignment stays `cancelled` |
| Service replays an acknowledged assignment | Evidence is re-asserted; no rejection, no state change in Cloud |


## Phase 5 addendum

Before provider start an accepted assignment reports startup stages via `assignment.startup` (capability `assignment.startup.v1`). Pre-start stages never change assignment status. See SERVICE_STARTUP_V9.md.
