# Execution protocol inventory and ownership — V9 Phase 1

**Status:** Phase 8 cleanup and acceptance baseline

**Scope:** AX, Cloud, Workspace Service, generic CLI Worker Engine, and local
provider CLI execution. This document inventories the current implementation;
it does not migrate or remove a wire message.

## Decision summary

The system has one authoritative execution lifecycle, with different evidence
owners at each boundary:

| Concern | Authority | Evidence accepted from elsewhere |
| --- | --- | --- |
| Persisted assignment, task, run and Work Request lifecycle | Cloud | Validated terminal delivery, synchronization and recovery observations |
| Local process admission, journal, process tree and observed local state | Workspace Service | Engine frames and Cloud commands |
| Provider process observations and normalized activity | CLI Worker Engine | Provider CLI JSONL/stdout through the active Tool Profile |
| Human-visible projection | AX/Web | Cloud HTTP reads and authenticated realtime signals; never local claims |

Cloud is the only component allowed to commit a persisted assignment transition.
The Service may record a local transition, but that record is evidence for
reconciliation and terminal redelivery, not a Cloud lifecycle mutation. Activity
is observational: losing it must not leave an assignment in `running`.

## Current path inventory

### AX/Web → Cloud

| Path | Created by | Transformed/persisted by | Consumed by | Current contract |
| --- | --- | --- | --- | --- |
| Work submission HTTP request | AX composer | Cloud route, mutation receipt, Work Request/Run/Task/Assignment rows | Cloud scheduler/workflow | HTTPS, idempotent `POST /threads/:id/work-requests`, `202` |
| Authoritative Work reads | AX server-state loaders | Cloud route/read model | AX presentation | HTTPS; status/result/history are authoritative |
| Browser realtime event | Cloud publisher | Realtime event/cursor tables when durable; gateway fanout | AX realtime cache router | WebSocket, cursor hello, HTTP re-read on gaps |

The browser does not dispatch assignments and does not connect to the Workspace
Runtime Protocol. `assignment.activity` is the sole execution activity event,
while terminal assignment lifecycle events are durable Cloud events.

### Cloud → Workspace Service

| Message | Created by | Service handling | Current reliability |
| --- | --- | --- | --- |
| `workspace.hello` / `workspace.hello.ack` | Service / Cloud Gateway | Authenticates one runtime session and fences the previous session | Session handshake |
| `workspace.heartbeat` / `.ack` | Both | Liveness and transport state | Ephemeral |
| `{"type":"workspace.ping"}` / `{"type":"workspace.pong"}` | Service / Cloudflare runtime | Idle WebSocket keep-alive after `hello.ack` announces `workspace.idle_ping.v1`; answered by WebSocket auto-response without waking the Gateway. Bare frames, not protocol envelopes | Ephemeral |
| `workspace.sync.request` / `.result` | Service / Cloud Gateway | Reconciles active assignments and recent terminal states | Replay/recovery command; bounded terminal window |
| `assignment.start` | Cloud Gateway dispatch route | Validates full assignment correlation, journals before launch, admits or rejects | Acknowledged command; idempotency key and assignment identity |
| `assignment.cancel` | Cloud cancellation route | Stops queued/active local work and confirms process cancellation | Acknowledged command; Cloud remains lifecycle authority |
| `worker.inventory` / `workspace.status` / `thread.status` | Service | Publishes readiness, capacity and management projections | Snapshot/status; not execution outcome |

The runtime envelope currently carries `messageId`, correlation IDs and the
assignment identity tuple (`executionWorkspaceId`, `workspaceRuntimeId`,
`workerId`, `runId`, `taskId`, `attemptId`, `assignmentId`, `idempotencyKey`).
It does not carry `threadId` or `workRequestId`; Cloud resolves those from the
assignment row before publishing normalized activity/realtime evidence.

### Workspace Service → Cloud

| Message | Created by | Cloud handling | Current reliability |
| --- | --- | --- | --- |
| `assignment.ack` | Service admission or Cloud terminal acknowledgement | Moves an active assignment to `acknowledged`; terminal form tells Service the terminal row was accepted | Overloaded: admission and terminal acknowledgement |
| `assignment.activity` | Service from Engine `activity` frame | Validates assignment/attempt/runtime/Worker, persists replayable activity subset and publishes realtime signal | Ephemeral for status/message; bounded durable history for lifecycle/tool events |
| `assignment.result` | Service after local journal commit, or journal replay | Validates exact assignment attempt and commits Cloud completed transition | Terminal, acknowledged, retained until Cloud acknowledgement |
| `assignment.error` | Service after local journal commit, or journal replay | Validates exact assignment attempt and commits Cloud failed transition | Terminal, acknowledged, retained until Cloud acknowledgement |
| `assignment.cancelled` | Service after local cancellation/journal commit | Validates exact assignment attempt and commits Cloud cancelled transition | Terminal, acknowledged, retained until Cloud acknowledgement |
| `assignment.cancel.ack` | Service after cancellation request | Cloud cancellation route may commit cancellation when `cancelled: true` | Cancellation acknowledgement; not a replacement for terminal result delivery |

Cloud rejects stale or foreign messages by checking the assignment's
Workspace, runtime, Worker, run, task, attempt, assignment and idempotency
identity. An earlier attempt cannot update a newer attempt.

### Workspace Service ↔ CLI Worker Engine

The Service starts one generic Engine process per admitted local execution slot
and speaks version-negotiated Local Worker Protocol 4.1 (4.0 remains a
supported compatibility version in the package). The Engine receives
`initialize.request`, then `execute.request`, and emits:

| Engine frame | Source/owner | Service use |
| --- | --- | --- |
| `progress` | Engine milestone observation | Private startup/milestone relay inside the Service; never a Cloud message |
| `activity` | Engine-normalized provider observation | Normalized activity relay to Cloud |
| `result` | Engine successful provider execution | Local journal terminal result |
| `error` | Engine/provider/process failure | Local journal terminal error |

The Engine frame identity is currently narrower than the Phase 1 normalized
event identity: it has `requestId`/`assignmentId`, and activity frames add
`executionId`, `workerId`, `eventId`, provider sequence and timestamp. The
Service adds Workspace/runtime/run/task/attempt context from the admitted
assignment before forwarding to Cloud.

### CLI Worker Engine ↔ provider CLI

The Tool Profile selects the provider executable, arguments, bounded parsing
and activity mapping. Provider JSONL events are observations only. The generic
Engine owns process supervision, session locks, timeouts, cancellation and
normalization; provider names must not become Cloud or Workspace protocol
message types. Provider output, prompts, commands, stdout/stderr and secrets
are not valid activity details.

## Lifecycle ownership and transitions

| Lifecycle fact | Cloud transition authority | Required local evidence | Recovery owner |
| --- | --- | --- | --- |
| Assignment created/dispatched | Cloud scheduler/dispatcher | Assignment context is admitted | Cloud workflow/dispatcher |
| Assignment accepted | Cloud Gateway on validated `assignment.ack` | Service accepted and journaled the assignment | Cloud |
| Assignment running | Cloud on validated running evidence/terminal path | Service journal + active process/slot | Service observes; Cloud reconciles |
| Completed | Cloud `recordAssignmentResult` | Journal committed before `assignment.result` | Cloud terminal acknowledgement + sync |
| Failed | Cloud `recordAssignmentError` | Journal committed error and process cleanup | Cloud terminal acknowledgement + recovery |
| Cancelled | Cloud `recordAssignmentCancelled` | Cancellation confirmed or terminal journal state | Cloud cancellation path + sync |
| Timed out/lost | Cloud recovery | Service/transport/diagnostic evidence is explanatory | Cloud deadline/lease/disconnect recovery |

The current database has assignment states `created`, `dispatched`,
`acknowledged`, `running`, `completed`, `failed`, and `cancelled`. The normalized
V9 terminal vocabulary (`completed`, `failed`, `cancelled`, `timed_out`,
`lost`) is an outcome vocabulary, not a request to add new database states in
Phase 1.

## Duplicate responsibilities and contract gaps

1. The Engine emits normalized activity for provider observations and Profile
   milestones. The Service forwards only `assignment.activity`; the private
   Engine progress frame is used for local startup observation and never drives
   Cloud lifecycle state. Activity never drives lifecycle state.
2. `assignment.ack` represents both admission acknowledgement and terminal
   acknowledgement. Its `terminal` flag is the discriminator; this is the
   main protocol overload to remove after migration.
3. `assignment.result`, `assignment.error`, and `assignment.cancelled` are
   terminal deliveries, while Cloud `assignment.completed`, `.failed`, and
   `.cancelled` are durable realtime facts. The former are transport evidence;
   the latter are Cloud projections and must not be conflated.
4. Service diagnostic records use names such as `assignment.started` and
   `assignment.completed`, but diagnostics are bounded evidence, not lifecycle
   commands or state transitions.
5. Provider/local activity sequence, Cloud realtime stream sequence, and
   `messageId` are different namespaces. They must never be compared or used
   as interchangeable cursors.
6. Current documentation says Local Worker Protocol 4.0 while the runtime
   package negotiates 4.1. The implementation/package contract is authoritative
   for this audit; the boundary documentation is corrected in the compatibility
   matrix below and should be updated as part of Phase 1 review.

## Phase 1 normalized event contract

The shared TypeScript contract is
[`packages/protocol/src/execution-events.ts`](../../packages/protocol/src/execution-events.ts).
It is intentionally an adapter contract: it does not replace any existing
transport in Phase 1.

Every normalized event requires:

- `protocol: syntila.execution-events`, `protocolVersion: 1.0`, and
  `schemaVersion: 1`;
- `eventId`, event type, category, delivery class, UTC `occurredAt`, and a
  positive source `sequence`;
- the complete correlation tuple: Workspace, runtime, Thread, Work Request,
  Run, Task, Assignment, Attempt, Execution and logical Worker IDs;
- bounded safe payload metadata only.

`sequence` is the provider/Engine source sequence. Cloud assigns its own
monotonic realtime cursor when it publishes a durable event; that cursor is
not copied into or compared with the normalized source sequence.

The contract classifies `model.status` and `message.updated` as ephemeral,
tool/lifecycle-start events as replayable, and `execution.*` as terminal. A
terminal event is evidence of an outcome; the terminal result/error delivery
and Cloud assignment row remain authoritative for the actual persisted result.

## Transport compatibility matrix

| Boundary | Current wire/version | Primary and fallback | Commands | Activity | Terminal/recovery |
| --- | --- | --- | --- | --- | --- |
| AX ↔ Cloud | Human Product Protocol; realtime 1.0/1.1 | HTTPS + browser WebSocket | HTTP submission, cancel and reads | Cloud realtime; HTTP reread on gap | Cloud HTTP read model; durable lifecycle events |
| Cloud ↔ Workspace Service | Workspace Runtime Protocol 5.1 | WSS; HTTPS long-poll | Start, cancel, sync, heartbeat | Runtime relay; bounded Service queue | Terminal messages, local journal, sync, Cloud recovery |
| Workspace Service ↔ Engine | Local Worker Protocol 4.1; 4.0 compatibility | NDJSON stdin/stdout; no network fallback | Initialize, execute, local cancel/supervision | `activity`; private `progress` startup frame | `result`/`error`, process cleanup and journal |
| Engine ↔ provider CLI | Profile-defined provider stream | Local child process; profile/provider-specific | Profile-shaped invocation | Adapter/mapping to normalized activity | Engine result/error and exit-code observation |

Transport availability must not alter command semantics, lifecycle authority,
or identity validation. WebSocket and long-poll are interchangeable delivery
transports for the Service; neither is an execution state.

## Obsolete-path register for Phase 8

These are migration candidates, not removals in Phase 1:

| Candidate | Why obsolete | Replacement/decision |
| --- | --- | --- |
| `assignment.progress` as a user-visible lifecycle signal | Duplicated normalized activity and could imply progress without liveness | Removed from external schema, generated bindings, Cloud gateway, Service relay and AX consumers |
| Admission/terminal overload of `assignment.ack` | One message has two acknowledgement meanings | Split command admission acknowledgement from terminal delivery acknowledgement |
| Independent AX logic that treats `assignment.activity` as terminal | Activity can be missing and never owns lifecycle | Use Cloud Work Request/assignment status for every terminal state |
| Provider-specific event names crossing Service/Cloud | Couples generic boundaries to provider streams | Keep provider names inside Profile adapters and emit normalized events |
| Realtime `assignment.activity` history as result authority | Activity is bounded observation, not output/result | Keep bounded history for timeline recovery; use terminal result/error and Cloud rows |
| Diagnostic `assignment.*` records as lifecycle events | Diagnostic evidence is not a state transition | Rename or namespace diagnostics if ambiguity remains after migration |

## Acceptance evidence

Phase 8 is complete when this inventory, the shared schema, diagnostics trace
and acceptance matrix are reviewed against the source paths, and every
transition in the lifecycle table has one owner and one recovery owner.

