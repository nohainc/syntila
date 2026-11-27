# Syntila Protocol Boundaries

**Status:** Current product boundary contract. Local Worker Protocol 4.1 is the Worker-to-Engine contract; 4.0 remains a negotiated compatibility version.
**Applies to:** Syntila, Syntila Cloud, Syntila Worker, and the CLI Worker Engine.

Syntila has three protocol boundaries. They share domain vocabulary, but each
boundary has its own endpoints, authentication, transport, versioning, and wire
schemas.

```text
Syntila  <->  Syntila Cloud
                 Human Product Protocol

Syntila Worker  <->  Syntila Cloud
                       Worker Runtime Protocol

Syntila Worker  <->  CLI Worker Engine process
                       Local Worker Protocol 4.1
```

The arrows show the three product/runtime boundaries. The Human Product
Protocol is primarily the AX-to-Cloud surface and includes only the
owner-authenticated Worker management routes explicitly defined by
ADR-013/ADR-014. Cloud may implement both human-facing endpoints and the
Worker Gateway, but those are separate surfaces with separate
authentication and contracts.

## 1. AX ↔ Cloud — Human Product Protocol

**Endpoints:** Syntila and Syntila Cloud's human-facing API/realtime
endpoints.  
**Authentication:** a human user session.  
**Transport:** HTTPS APIs and browser realtime connections.  
**Contract ownership:** Cloud publishes the API/read-model contracts consumed
by AX; AX owns human-facing product behavior.

This protocol carries Spaces, Threads, collaboration, Thread
execution policy, Worker grants, human-readable Worker/Worker inventory,
results, artifacts, and audit/read models. AX uses it to request product
actions and display Cloud-authoritative state.

Critical creation routes support the [v1 mutation idempotency contract](../specifications/MUTATION_IDEMPOTENCY.md)
through an optional `Idempotency-Key` header. AX retains keys for explicit retries;
connectivity restoration never replays Work execution automatically.

AX MUST NOT open a Worker Runtime Protocol connection, construct runtime
messages, or authenticate as a Worker machine. AX cannot dispatch an
assignment directly to a Worker or provider CLI. Cloud authorizes and
schedules work, then dispatches it through the Worker Runtime Protocol.
Worker executes it with the generic CLI Worker Engine.

The Worker CLI's owner-authenticated account and registration requests
remain explicitly scoped management routes on Cloud's human-authenticated HTTP
surface, as defined by ADR-013/ADR-014. They use the Human Product Protocol's
HTTPS management surface, not the Worker Runtime Protocol. Those requests
do not carry runtime assignments and do not make the Worker CLI an AX
client. The separate runtime credential and Worker Runtime Protocol remain
required for machine participation.

## 2. Connect ↔ Cloud — Worker Agent Protocol

Connect obtains a Worker session using the Worker's local key and a signed
challenge, then connects to `/api/worker-agent/gateway` with the Worker and
session identifiers and a bearer session token. Each Worker has its own
credential, session, journal and lock. Connect reconciles its journal before
reporting readiness; a newer session epoch fences an older session.

The versioned `syntila.worker-agent-protocol` contract is defined in
`packages/worker-agent-protocol/src/worker-agent.ts` and consumed by the
Worker gateway and Connect. It carries Worker readiness, assignment delivery,
acknowledgements, activity, results, and cancellation. Cloud owns admission,
authorization and durable state; Connect supervises the local Engine and
checks local execution permissions. Cloud never receives local folder paths.
Request files and handoffs travel through the artifact service.

The human client and the Engine do not use a Worker credential or directly
open this gateway. The Engine runs as a separate child process of Connect.

## 3. Worker ↔ CLI Worker Engine — Local Worker Protocol 4.1

**Endpoints:** Syntila Worker process supervisor and one generic CLI Worker Engine child process.  
**Authentication:** local admission only; no Cloud/human credential is present.  
**Transport:** versioned NDJSON over stdin/stdout.  
**Contract ownership:** Worker + shared protocol package; Engine implements it.

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

Worker owns Engine/Profile admission, process lifetime, local permissions, CWD, cancellation and safe Cloud synchronization. Worker does not discover or invoke provider CLIs directly.

Cloud-to-Worker assignments carry only the canonical execution permission
IDs `repository:read`, `repository:write`, `shell:execute`, and `network:use`.
Cloud derives its assignment set from Space role and Worker Grant policy;
Worker independently enforces that set against local Worker permissions.
Local permission identifiers are not aliases or Cloud-side boundaries.

The Engine owns provider execution through one Worker-admitted Worker Profile. It may launch only the resolved provider CLI using structured arguments with shell execution disabled. It never receives Worker runtime credentials and never connects directly to Cloud.

Tool Profiles are not protocol peers. They are immutable behavior configuration consumed locally by the Engine after Worker digest/schema/compatibility admission. Profiles cannot disable Engine security invariants or add arbitrary process execution.

Provider credentials and provider session IDs are not intentionally sent as
Local Worker Protocol fields; arbitrary Cloud executable paths and shell commands
are not protocol fields. Protocol 4.4 permits bounded provider failure details
and failed-run responses as a separately identified terminal error field when
both local peers support it. Arbitrary provider text can contain sensitive data
that pattern-based credential detection does not recognize.

The provider failure details contract
specifies its negotiation, credential boundary, limits and rollout. Arbitrary
raw provider streams are not protocol fields.

Durable execute requests may carry version 1 `workerSession` metadata: Syntila
session, Conversation, and Worker IDs plus a frozen context target revision.
Worker validates ownership before forwarding it; the Engine retains native
handles in Worker-local state only. Model and effort changes do not partition
sessions. See [Conversation continuity](../specifications/CONVERSATION_CONTINUITY_V1.md)
for local file upgrades, context synchronization limits, and coordinated rollout.

Local Worker Protocol 4.1 is the sole Worker-to-Engine protocol contract;
4.0 remains supported only through version negotiation during migration.
Provider identity, release state, and executable paths do not cross this
boundary as caller-controlled values.

## Shared canonical domain vocabulary

These names describe Syntila domain values used across boundaries:

| Canonical name | Meaning |
| --- | --- |
| `SpaceId` | Stable identity of a collaboration Space |
| `ThreadId` | Stable identity of a persistent unit of work |
| `WorkerId` | Cloud identity of a registered machine Worker |
| `WorkerSessionId` | Identity of one authenticated Worker session |
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
Protocol request, Worker Runtime Protocol frame, and Local Worker Protocol
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
| Owner/account management | Worker management CLI | Cloud management routes | Human Product Protocol, HTTPS management surface | Human session |
| Inventory, assignments, progress, cancellation | Worker runtime | Cloud Worker Gateway | Worker Runtime Protocol | Worker runtime credential |
| Local setup, readiness, execution, progress, result | Worker supervisor | CLI Worker Engine process | Local Worker Protocol 4.1 | Bounded non-secret settings; no provider tokens or account secrets |

Cloud may translate and persist domain state between its product API and
Worker Gateway. Worker may translate between its Cloud runtime client
and CLI Worker Engine process. Neither translation forwards a wire envelope
unchanged across a boundary.

## Current schema locations

- Human API and realtime: `apps/backend/src/domain/routes`,
  `apps/backend/src/domain/realtime-gateway.ts`, and `apps/app/lib/src/realtime`.
- Worker Agent: `packages/worker-agent-protocol`,
  `apps/backend/src/domain/worker-gateway.ts`, and `apps/connect/lib/src/wire.dart`.
- Local Worker Protocol: `packages/syntila_worker_protocol`, Connect's Engine
  supervisor in `apps/connect/lib/src/cli_engine.dart`, and
  `engines/cli_worker/lib/src/cli_worker_engine.dart`.
- Canonical domain types: `packages/core/src`.

Discussion reads use the [versioned paging contract](../specifications/DISCUSSION_PAGING.md). AX retains shared cached history across page disposal,
synchronizes on reopening, and reconciles optimistic sends and edits per message.

Human Product realtime collaboration signals and independent durable Space/user
stream sequencing are specified in [Realtime synchronization 1.1](../specifications/REALTIME_SYNCHRONIZATION.md).
Existing Worker envelopes remain compatible; this does not change
Worker Runtime or Local Worker Protocol transport.

Durable assignments carry a version 1 `workerSession` (session, Conversation and Worker
IDs, `baseContextRevision`) and, when a Worker needs history, an optional `bootstrap`:
Syntila Conversation and context IDs, a frozen canonical history sequence,
`turnRevision` and bounded canonical history text, where each history entry carries its
`contextRevision` and `throughSequence` freezes dispatch-time facts. Cloud route modules
build this from Syntila history, Connect validates its scope and forwards it to the
generic Engine, and the Engine consumes it only to start or catch up a native session;
provider handles stay local. Stateless assignments may carry `statelessContext`
(rejected for durable execution). Context documents (Bootstrap, Delta, Stateless) are
version 1, with `conversationContext` separate from request-scoped
`workflowExecutionContext`, all provider independent. Work history and request detail
add `workflowRun` (with `stepRuns`) beside `turns`; turns expose `workflowRunId`,
`workflowStepRunId` and an optional `runtimeRunId`. These fields are additive: strict
older readers reject them, so Connect and Engine readers must be updated before Cloud
emits them. Local Worker Protocol framing is otherwise unchanged. Details:
[Conversation continuity](../specifications/CONVERSATION_CONTINUITY_V1.md).
