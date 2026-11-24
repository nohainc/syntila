# Syntila Protocol Boundaries

**Status:** Current product boundary contract. Local Worker Protocol 4.1 is the Workspace-to-Engine contract; 4.0 remains a negotiated compatibility version.
**Applies to:** Syntila, Syntila Cloud, Syntila Workspace, and the CLI Worker Engine.

Syntila has three protocol boundaries. They share domain vocabulary, but each
boundary has its own endpoints, authentication, transport, versioning, and wire
schemas.

```text
Syntila  <->  Syntila Cloud
                 Human Product Protocol

Syntila Workspace  <->  Syntila Cloud
                       Workspace Runtime Protocol

Syntila Workspace  <->  CLI Worker Engine process
                       Local Worker Protocol 4.1
```

The arrows show the three product/runtime boundaries. The Human Product
Protocol is primarily the AX-to-Cloud surface and includes only the
owner-authenticated Workspace management routes explicitly defined by
ADR-013/ADR-014. Cloud may implement both human-facing endpoints and the
Workspace Gateway, but those are separate surfaces with separate
authentication and contracts.

## 1. AX ↔ Cloud — Human Product Protocol

**Endpoints:** Syntila and Syntila Cloud's human-facing API/realtime
endpoints.  
**Authentication:** a human user session.  
**Transport:** HTTPS APIs and browser realtime connections.  
**Contract ownership:** Cloud publishes the API/read-model contracts consumed
by AX; AX owns human-facing product behavior.

This protocol carries Spaces, Threads, collaboration, Thread
execution policy, Workspace grants, human-readable Workspace/Worker inventory,
results, artifacts, and audit/read models. AX uses it to request product
actions and display Cloud-authoritative state.

Critical creation routes support the [v1 mutation idempotency contract](../specifications/MUTATION_IDEMPOTENCY.md)
through an optional `Idempotency-Key` header. AX retains keys for explicit retries;
connectivity restoration never replays Work execution automatically.

AX MUST NOT open a Workspace Runtime Protocol connection, construct runtime
messages, or authenticate as a Workspace machine. AX cannot dispatch an
assignment directly to a Workspace or provider CLI. Cloud authorizes and
schedules work, then dispatches it through the Workspace Runtime Protocol.
Workspace executes it with the generic CLI Worker Engine.

The Workspace CLI's owner-authenticated account and registration requests
remain explicitly scoped management routes on Cloud's human-authenticated HTTP
surface, as defined by ADR-013/ADR-014. They use the Human Product Protocol's
HTTPS management surface, not the Workspace Runtime Protocol. Those requests
do not carry runtime assignments and do not make the Workspace CLI an AX
client. The separate runtime credential and Workspace Runtime Protocol remain
required for machine participation.

## 2. Workspace ↔ Cloud — Workspace Runtime Protocol

**Endpoints:** the Syntila Workspace runtime and Cloud's Workspace Gateway.  
**Authentication:** a machine runtime credential bound to one Workspace
runtime, sent as a Bearer credential in the `Authorization` header. Runtime
credentials MUST NOT be accepted from WebSocket URL query parameters.
**Transport:** WSS is primary; HTTPS long-poll is the functional fallback.
Workspace retries WSS after 5 minutes, doubling the interval after failures
to a maximum of one hour. Wake/app resume resets the delay and requests a
fresh WSS attempt while HTTPS is Ready. Each WSS attempt uses a fresh network
client; timed-out or superseded attempts close late sockets. HTTPS stays active
during the upgrade attempt. Cloud accepts only one active runtime session, so
an accepted upgrade fences the HTTPS session; Workspace then tears down its
old timers, subscription, transport and session state before authenticating and
synchronizing WSS. WSS is Ready only after synchronization, inventory and
assignment reconciliation complete; failure restores HTTPS through reconnect.
Automatic recovery does not invoke the human owner disconnect workflow.
**Contract ownership:** the versioned Workspace Runtime Protocol schema and
Cloud Gateway implementation.

This protocol carries runtime hello/heartbeat, safe Worker inventory and
status, assignment delivery/acknowledgement/progress/results/errors, and
cancellation. Cloud scheduling and Workspace execution use this boundary;
transport choice does not change assignment semantics.

Cloud-facing Worker Type IDs are product concepts. Space and Thread
policy, Workspace inventory, and assignment snapshots use IDs such as
`chatgpt` and `gemini`; internal Worker release identifiers are not accepted
in this protocol.
Cloud forwards the selected product Worker Type ID unchanged. Workspace
validates it against the selected local Worker slot, then resolves the admitted
Engine and compatible official Tool Profile Release for that logical Worker.
AX therefore does not need to know which Engine build or Profile implements a
product Worker.

Only Syntila Workspace speaks this protocol as a client. Cloud's Workspace
Gateway is its server. Syntila is not a runtime client. CLI Worker Engine
processes are not runtime clients and MUST NOT connect to Cloud, invoke
Workspace Gateway routes, or receive the Workspace runtime credential.
Workspace translates between runtime messages and Local Worker Protocol 4.1
frames.

The current implementation is named
`syntila.workspace-runtime-protocol` and is defined in
`packages/workspace-runtime-protocol/src/workspace-runtime.ts`. Keep its runtime identity,
authentication, transport negotiation, and assignment envelopes inside this
boundary.

## 3. Workspace ↔ CLI Worker Engine — Local Worker Protocol 4.1

**Endpoints:** Syntila Workspace process supervisor and one generic CLI Worker Engine child process.  
**Authentication:** local admission only; no Cloud/human credential is present.  
**Transport:** versioned NDJSON over stdin/stdout.  
**Contract ownership:** Workspace + shared protocol package; Engine implements it.

Protocol 4.1 carries:
- initialize;
- passive/live probe;
- execute;
- progress;
- result;
- error.

Initialize requests bind `workerTypeId`, `expectedEngineVersion`,
`profileDefinitionId`, `profileReleaseVersion`, the lowercase SHA-256
`profileDigest`, and `protocolVersion`. Initialize results confirm the logical
Worker Type, Engine version, Tool Profile definition/release/schema version,
and capabilities. Probe results may report only the bounded provider tool name
and version; executable paths are not part of the wire contract.
Probe requests carry an Engine-enforced `timeoutMs` ceiling of at most 30
seconds. For live probes, the Engine supplies the fixed Syntila test prompt
and requires exact final text `OK`; Profiles can define only provider transport
and output parsing.

Workspace owns Engine/Profile admission, process lifetime, local permissions, CWD, cancellation and safe Cloud synchronization. Workspace does not discover or invoke provider CLIs directly.

Cloud-to-Workspace assignments carry only the canonical execution permission
IDs `repository:read`, `repository:write`, `shell:execute`, and `network:use`.
Cloud derives its assignment set from Space role and Workspace Grant policy;
Workspace independently enforces that set against local Worker permissions.
Local permission identifiers are not aliases or Cloud-side boundaries.

The Engine owns provider execution through one Workspace-admitted Worker Profile. It may launch only the resolved provider CLI using structured arguments with shell execution disabled. It never receives Workspace runtime credentials and never connects directly to Cloud.

Tool Profiles are not protocol peers. They are immutable behavior configuration consumed locally by the Engine after Workspace digest/schema/compatibility admission. Profiles cannot disable Engine security invariants or add arbitrary process execution.

Provider credentials and provider session IDs are not intentionally sent as
Local Worker Protocol fields; arbitrary Cloud executable paths and shell commands
are not protocol fields. Protocol 4.4 permits bounded provider failure details
and failed-run responses as a separately identified terminal error field when
both local peers support it. Arbitrary provider text can contain sensitive data
that pattern-based credential detection does not recognize.

The [provider failure details contract](../roadmaps/PROVIDER_FAILURE_DETAILS_PLAN.md)
specifies its negotiation, credential boundary, limits and rollout. Arbitrary
raw provider streams are not protocol fields.

Durable execute requests may carry version 1 `workerSession` metadata: Syntila
session, Conversation, and Worker IDs plus a frozen context target revision.
Workspace validates ownership before forwarding it; the Engine retains native
handles in Workspace-local state only. Model and effort changes do not partition
sessions. See [Conversation Continuity Phase 6](../specifications/CONVERSATION_CONTINUITY_V1.md#phase-6--workspace-owned-worker-sessions)
for local file upgrades, context synchronization limits, and coordinated rollout.

Local Worker Protocol 4.1 is the sole Workspace-to-Engine protocol contract;
4.0 remains supported only through version negotiation during migration.
Provider identity, release state, and executable paths do not cross this
boundary as caller-controlled values.

## Shared canonical domain vocabulary

These names describe Syntila domain values used across boundaries:

| Canonical name | Meaning |
| --- | --- |
| `SpaceId` | Stable identity of a collaboration Space |
| `ThreadId` | Stable identity of a persistent unit of work |
| `WorkspaceId` | Cloud identity of a registered machine Workspace |
| `WorkspaceRuntimeId` | Identity of the connected machine runtime |
| `WorkerId` | Identity of one Workspace-owned local Worker slot/configuration |
| `WorkerTypeId` | Stable product integration type, such as `chatgpt` or `gemini` |
| `AssignmentId` | Identity of one immutable unit of scheduled execution |
| `RunId` | Identity of the orchestration Run containing work |
| `TaskId` | Identity of one task within a Run |
| `WorkerReadiness` | Domain readiness state used for scheduling and display |
| `AssignmentStatus` | Domain lifecycle state for scheduled execution |
| `ErrorCode` | Stable machine-readable failure category |

These are canonical domain concepts, not a shared message envelope. At the
wire boundary, each protocol owns its own versioned schemas, required fields,
field names, validation, and authentication context. A value such as
`AssignmentId` may appear in multiple protocol payloads, but a Human Product
Protocol request, Workspace Runtime Protocol frame, and Local Worker Protocol
frame are never interchangeable. Do not import one protocol's envelope or
transport into another boundary to reuse these names.

The TypeScript/Dart or service-specific representations may remain distinct
while carrying the same canonical meaning. Changes to a canonical concept must
be reviewed across each affected boundary; this does not authorize merging the
wire contracts.

## Boundary ownership matrix

| Flow | Client | Server/process peer | Protocol | Credentials allowed |
| --- | --- | --- | --- | --- |
| Product and collaboration actions/read models | Syntila | Cloud human API/realtime | Human Product Protocol | Human session |
| Owner/account management | Workspace management CLI | Cloud management routes | Human Product Protocol, HTTPS management surface | Human session |
| Inventory, assignments, progress, cancellation | Workspace runtime | Cloud Workspace Gateway | Workspace Runtime Protocol | Workspace runtime credential |
| Local setup, readiness, execution, progress, result | Workspace supervisor | CLI Worker Engine process | Local Worker Protocol 4.1 | Bounded non-secret settings; no provider tokens or account secrets |

Cloud may translate and persist domain state between its product API and
Workspace Gateway. Workspace may translate between its Cloud runtime client
and CLI Worker Engine process. Neither translation forwards a wire envelope
unchanged across a boundary.

## Current schema locations

- Human Product Protocol: AX `apps/app/lib/src/ax/ax_data.dart` and
  `apps/app/lib/src/realtime/realtime_client.dart`; Cloud
  `apps/cloud/src/routes/handlers.ts` and `apps/cloud/src/realtime-gateway.ts`.
- Workspace Runtime Protocol: Workspace
  `apps/workspace/lib/cloud_connection.dart`; schema
  `packages/workspace-runtime-protocol/src/workspace-runtime.ts`; Cloud
  `apps/cloud/src/workspace-gateway.ts`.
- Local Worker Protocol 4.1: implemented by the Workspace supervisor
  `apps/workspace/lib/cli_worker_engine_supervisor.dart`, assignment handler
  `apps/workspace/lib/worker_executor.dart`, generic Engine
  `engines/cli_worker/lib/src/cli_worker_engine.dart`, and shared schema
  `packages/syntila_worker_protocol`.
- Canonical domain model: domain entities in `packages/core/src` and the
  canonical vocabulary in this document; wire validators remain protocol-owned.

Protocol binding generation covers the product envelope, Cloud Workspace
message metadata, and realtime event metadata. It does not generate Local
Worker Protocol bindings: `packages/syntila_worker_protocol` is the single
source for Worker Protocol 4.1 models and validation.

Discussion reads use the [versioned paging contract](../specifications/DISCUSSION_PAGING.md). AX retains shared cached history across page disposal,
synchronizes on reopening, and reconciles optimistic sends and edits per message.

Human Product realtime collaboration signals and independent durable Space/user
stream sequencing are specified in [Realtime synchronization 1.1](../specifications/REALTIME_SYNCHRONIZATION.md).
Existing execution Workspace envelopes remain compatible; this does not change
Workspace Runtime or Local Worker Protocol transport.

Workspace Space grant collections and the additive aggregate count in
`GET /api/workspaces` are Human Product HTTP read models. Their versioned
read model contract 1.1 preserves
existing mutation endpoints and authorization. Runtime inventory and grant
admission still belong to their existing Cloud/Workspace boundaries.


For model replacement, version 1 `workerSession` may also contain optional version
1 `bootstrap`: Syntila Conversation/context IDs, a frozen canonical history
sequence, and bounded canonical history text. Cloud route modules build this
snapshot from Syntila history; Workspace validates its scope and forwards it to
the generic Engine. The Engine consumes it only for a new native session. Provider
handles remain local. Strict older readers reject the additive field, requiring
Workspace/Engine rollout before Cloud emits it. See
[Conversation Continuity Phase 14](../specifications/CONVERSATION_CONTINUITY_V1.md#phase-14--same-worker-different-model).


Phase 15 supplies bootstrap context for every manual durable Conversation Worker.
An optional version 1 bootstrap `turnRevision` freezes the accepted request; each
history entry carries `contextRevision`, and `throughSequence` freezes dispatch-time
facts. Updated Workspace/Engine readers must precede Cloud rollout. The generic
Engine forwards full context for new sessions or missed context alongside a resumed
turn, and records synchronization only after success. Worker switching remains a
next-turn product selection. See
[Phase 15](../specifications/CONVERSATION_CONTINUITY_V1.md#phase-15--different-worker-continuity).


Phase 16 adds version 1 structured Bootstrap/Delta/Stateless context documents
inside bounded canonical context text. Stateless assignments and ExecuteRequest
may include optional `statelessContext`, rejected for durable execution. Workflow
state is explicit and provider independent. Workspace/Engine updates must precede
Cloud emission. See [Context Engine](../specifications/CONVERSATION_CONTINUITY_V1.md#phase-16--provider-independent-context-engine).


Phase 17 Context Engine documents distinguish persistent `conversationContext`
from request/receiving-step `workflowExecutionContext` (version 1). Work and
multi-step execution context is preserved in resumed deltas independently of
Conversation history changes. Provider CLI transport remains Profile-defined.
See [workflow-aware context](../specifications/CONVERSATION_CONTINUITY_V1.md#phase-17--workflow-aware-context).


Phase 18 Human Product Work history/request detail adds version 1 `workflowRun`,
separate from the existing `turns` list. Worker turns expose `workflowRunId` and
optional runtime-attempt association `runtimeRunId` (null without an attempt).
Workflow execution context includes the stable logical WorkflowRun identity.
Native sessions remain local and Local Worker Protocol framing is unchanged.
Deploy Cloud only after the ownership schema update. See
[Phase 18](../specifications/CONVERSATION_CONTINUITY_V1.md#phase-18--workflowrun-and-workerturn-ownership).


Phase 19 version 1 WorkflowRun read models add trigger-message identity, persisted
start/completion evidence and nested version 1 `stepRuns`. Turns add immutable
`workflowStepRunId`; context steps include StepRun identity and role. Step results
use the existing bounded Human Product text projection. Native Session handles
remain local; Local Worker Protocol framing is unchanged. Apply schema migration
0016 before Cloud deployment. See
[Phase 19](../specifications/CONVERSATION_CONTINUITY_V1.md#phase-19--workflowrun-and-workflowsteprun-data-model).
