# Authoritative execution lifecycle

Cloud owns the persisted state of assignments, attempts, tasks, runs and Work Requests. Connect owns each Worker's local journal and supervises the generic Engine. Activity is diagnostic and does not determine a terminal outcome. The transition rules live in [`execution-lifecycle.ts`](../../packages/core/src/execution-lifecycle.ts).

## Assignment state machine

An assignment starts as `created`, then can progress through `dispatched`, `acknowledged` and `running`. Delivery is not admission, and admission does not prove that a provider process started. Local queueing and startup can project as `acknowledged` until explicit start evidence arrives. Terminal outcomes include `completed`, `failed`, `cancelled`, `timed_out` and `lost`; later messages cannot reopen a terminal assignment.

A cancellation, deadline or lost Worker may move an active assignment to `revocation_pending` and then `reconciling` while stop evidence is missing. An uncertain outcome is not proof that a process stopped. See [Command delivery and revocation](COMMAND_DELIVERY_AND_REVOCATION_V9.md).

## Identities

An assignment is admitted with a unique `assignmentId`, `attemptId` and
`idempotencyKey`; each outbound command also has a transport `messageId`.
`assignmentId` identifies the immutable Cloud work unit, `attemptId` fences retries
and stale observations, `idempotencyKey` deduplicates admission and terminal
redelivery, and `messageId` identifies one delivery attempt. `created` and
`dispatched` assignments may be sent again; `acknowledged` and `running` are not
reopened; terminal assignments are never redispatched. Dispatch means only that Cloud
persisted and announced the command; the evidence chain is command queued →
acknowledged → provider started → terminal outcome. A terminal result may arrive before
the final activity event, and activity arriving after a terminal outcome never changes
it. Cosmetic activity (model status, partial messages) is ephemeral and may be
coalesced or dropped for a slow client, which then resynchronizes and reads
authoritative state; it never infers a terminal status from a missing activity event
([Execution activity](EXECUTION_ACTIVITY_V9.md)).

## Evidence and ordering

Later evidence can establish earlier milestones, but state transitions never move backwards. Cloud validates the Worker, assignment, attempt and session fence on relevant writes. A newer session prevents a stale session from committing a late acknowledgement or result. The accepted request snapshot fixes the Worker and execution configuration; updates to live settings do not rewrite it.

## Reconnection and terminal behavior

Connect journals the attempt before acknowledging it and records terminal evidence before sending it. It retries an unacknowledged terminal result after reconciliation. When a crash may have interrupted a started attempt, Connect does not launch another Engine for that attempt; it reports a retryable failure and Cloud may schedule a new attempt. Cloud applies terminal outcomes idempotently. See [ADR-034](../decisions/ADR-034-connect-pairing-and-session-fencing.md).

## Deadlines and recovery

Cloud uses admission, startup and execution deadlines to decide when to request cancellation or recovery. A deadline alone does not prove that a process stopped. A confirmed stop or terminal result allows reconciliation; otherwise an assignment can remain unresolved while holding its capacity. Consult the transition and revocation implementations for the currently configured timing values.

A provider failure can include a bounded, sanitized diagnostic message. Authorized failure details are encrypted at rest; credentials and local paths are not exposed. See [ADR-036](../decisions/ADR-036-canonical-thread-timeline-and-attribution.md).

## Test evidence

Backend lifecycle, revocation and gateway tests protect Cloud transitions. Connect's Agent matrix covers replay and crash points; the live Agent integration test covers reconnection after a backend restart and checks that the session epoch advances. Real-provider, installed-device and in-flight production restart acceptance are separate evidence.

## Execution trace

Diagnostic records ([Diagnostic events](DIAGNOSTIC_EVENTS_V1.md)) carry bounded
metadata and the assignment correlation tuple, so one assignment and attempt can be
followed through these stages: `dispatch` (Cloud), `accepted`, `slot_reservation`
(local capacity reserved or queue/deadline diagnostic), `engine_startup`,
`provider_execution` (only then is the assignment running), `activity_forwarding`,
`terminal_recorded` (durable local journal) and `terminal_acknowledgement` (Cloud
persisted the outcome and acknowledged). Records exclude prompts, credentials,
provider content and unrestricted tool input and output.

## Acceptance scenarios

Provider-independent coverage must show: a complete lifecycle and exactly one terminal
result for each supported provider fixture; no indefinite Running state when a
provider produces no activity; a nonzero exit as a failed outcome with released
capacity; an Engine killed mid-work as failure or explicit reconciliation with no
phantom slot; Connect restart reconciling its journal without duplicate execution; web
reconnect and browser reload restoring status and retained activity from Cloud;
Cloud disconnect mid-execution with the terminal outcome retried after reconnect;
duplicate terminal delivery producing one outcome; independent concurrent requests
using separate Engine processes; a queue timeout with correct capacity accounting;
cancel of an active assignment terminating only its process and of a queued one
launching none; and a rapid submission burst with no duplicate, missing or
permanently queued assignments.
