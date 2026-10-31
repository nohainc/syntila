# Syntila Architecture

**Current architecture contract:** v9 — one centrally published Profile per logical Worker, interpreted by one generic CLI Worker Engine.

**Implementation baseline:** v8 remains the historical implementation baseline while the V9 contract is implemented phase by phase.

**V8 implementation status:** The historical v8 release declaration remains gated by the acceptance evidence in the [implementation roadmap](docs/roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md).

~~~text
Syntila
-> Syntila Cloud
-> Syntila Workspace
-> CLI Worker Engine
-> centrally published Worker Profile
-> provider CLI
~~~

## V9 Profile contract

The canonical V9 Profile identity, publication, verification, activation, and
execution-snapshot contract is defined in
[WORKER_PROFILE_V9.md](docs/specifications/WORKER_PROFILE_V9.md). It supersedes
the V8 release/channel lifecycle while retaining the provider-independent
generic Engine boundary.

## v8 architecture contract (historical implementation baseline)

Architecture v8 has one execution path: Syntila → Cloud → Workspace → CLI Worker Engine → current Worker Profile → provider CLI. The explicit exclusions in the
[v8 architecture contract](docs/architecture/ARCHITECTURE_V8.md#architecture-contract)
are normative and checked by `scripts/verify-v8-architecture.mjs`.

## Product model

- **Syntila** is the human application for Spaces, Threads, team Chat, AI execution through Work Requests, Workspace grants, user Workflow configuration, results, and audit.
- **Syntila Cloud** owns collaboration and scheduling state, the logical Worker catalog, the single current Profile and bounded Profile history for each logical Worker, and authorization. Provider credentials stay local.
- **Syntila Workspace** is the machine execution environment. It owns
  application-managed state below
  `~/Library/Application Support/Syntila/Workspace/` and resolves one
  user-owned Work Root, which defaults to `~/Documents/Syntila` on macOS.
- **Logical Workers** such as ChatGPT and Gemini are stable product identities. The Engine and Profile resolve each identity to a supported provider CLI.

## Work v1

Syntila owns the built-in Steps and Workflows defined by the [Work v1 Contract](docs/specifications/WORK_V1_CONTRACT.md). Users configure logical Workers for Work (`direct:v2`) and individual Steps globally, with shared overrides in each Space’s Workflows tab. Historical `direct:v1` snapshots retain the name Direct. A Work Request snapshots its Workflow, bindings, models, instructions, attachment references, and prompt-profile versions.

| Workflow | Filesystem authority | Provider session | Mutation coordination |
| --- | --- | --- | --- |
| Chat (`chat:v1`) | Read-only conversation | Durable, scoped to Thread Chat | Stateless request; no mutation lease |
| Work (`direct:v2`) | Writable within authorized Thread policy | Durable, scoped to Thread Work | Stateful request; mutation lease and fencing |

Work is the user-facing current version of the stable internal Workflow ID
`direct`; persisted IDs and historical snapshots are never renamed for display.
Chat and Work have separate provider sessions even when their Worker/model match.
Research and Plan retain read-only analysis semantics. Implement remains writable;
Test and Verify retain their existing read-only validation/review semantics and
coordination. Their sessions remain request/Step-scoped. Tool Profiles implement
permission policies without provider branches in Cloud, Workspace or AX.
See the [operator workflow guide](docs/operations/THREAD_EXECUTION.md) and
[regression coverage](docs/acceptance/CHAT_WORKFLOW.md).

The runtime implementation stays below the logical Worker boundary:

~~~text
User Workflow Configuration -> execution resolution -> logical Worker -> current Profile -> CLI Worker Engine -> provider CLI
~~~

### Filesystem ownership

The application-family data root is resolved automatically at
`~/Library/Application Support/Syntila/`. Workspace state, registry,
Profiles, Engines, sessions, caches, runtime metadata, and other internal
files remain application-managed below its `Workspace/` subtree. Profile Lab
uses a separate `Profile Lab/` subtree under the same root.

The Work Root is user-owned working data that Workers may operate on. A Space
Work Directory is resolved beneath it. A Workspace is an execution environment
with a Work Root; it is not itself a directory.
Each Space directory is selected through a private `spaceId` registry and an
identity marker, so duplicate names and Space renames do not move user files.
Threads share their Space directory and do not receive directories by default;
Thread sessions, logs, execution state, and temporary runtime metadata remain
under the application-managed Workspace subtree.

The filesystem contract is:

```text
USER-OWNED
~/Documents/Syntila/
└── <Space>/
    └── projects/files

SYNTILA-OWNED
~/Library/Application Support/Syntila/
├── Workspace/
│   ├── profiles
│   ├── engines
│   ├── sessions
│   ├── logs
│   └── runtime
└── Profile Lab/
    └── internal state
```

Resetting or removing a Workspace clears only Syntila-owned state. It never
deletes the Work Root or a Space directory; deleting user-owned files requires
an explicit destructive action.

## Conversation Workflow ownership

Current manual Chat and Work requests belong to persistent, Workflow-owned
Conversations within their Thread. Conversation revisions count accepted
requests; context revisions track accepted-request context boundaries.
User messages link to stable logical WorkflowRuns; each run owns multiple Worker
turns grouped by stable WorkflowStepRuns, plus existing scheduler Run attempts,
including retries. Run timestamps record first-start and terminal evidence. Work Request remains
the single lifecycle/configuration owner. Run/step orchestration remains internal;
ordinary Chat and Work retain conversation presentation and request-based controls.
A future step-list presentation adapter requires explicit enablement and a matching
versioned multi-step workflow; backend record counts alone never enable it.
Per-assignment turns preserve immutable
execution attribution, and lifecycle evidence; retries retain separate records.
The CLI Worker Engine reconstructs unavailable native sessions at the Worker-step
boundary using frozen canonical context, within the same assignment and workflow
run. Rejected handles remain invalidated locally until replacement succeeds;
Profile error mappings authorize one bounded reconstruction attempt.
Dispatch and StepRun evidence retain the frozen request context boundary. Local
session synchronization advances only on successful consumption and cannot move
backwards; revision and history-watermark evidence is recorded in local diagnostics.
Concurrent steps retain independent context evidence, including a frozen snapshot
fingerprint. Native session execution is exclusive across local Engine processes;
different Workers and stateless steps remain independent.
Versioned product Workflow definitions pin existing execution graphs, with
Work (`work:v1`) mapped to `direct:v2`. Native provider continuity remains local to Workspace/Engine. Syntila owns an append-only canonical history of messages,
responses, workflow/execution events, artifact events, and context events; provider
sessions remain execution state. The provider-independent Context Engine assembles canonical bootstrap, delta and
stateless context. Persistent conversation facts are distinct from receiving-step
workflow execution context, including scoped environment, artifacts and completed
prerequisite results. Worker Profiles also space versioned, generic Worker execution
options for model selection, session model switching, and model-specific effort;
provider argument mapping stays local to the Engine. See [Conversation Continuity v1](docs/specifications/CONVERSATION_CONTINUITY_V1.md).

## Workflow and execution boundaries

Workflow planning determines the Steps and their dependencies. Cloud's Workflow
runner owns scheduling and lifecycle, and delegates selected Worker/model/effort,
execution policy and generic result attribution to `execution-engine.ts`.
The assignment dispatcher owns authorization, Profile admission and D1 access.
It supplies canonical context through the provider-independent Core Context Engine.

Core's Conversation Router defines continuity policy. The local Engine's
`ConversationExecutionRouter` prepares continuation, delta synchronization,
bootstrap, reconstruction or stateless prompts from validated local session state
and the frozen canonical envelope. The generic CLI Worker Engine owns native
session validation, locking and persistence, Profile interpretation and
provider process execution. Reconstruction stays inside the Worker step; the
Workflow receives a generic result and does not manage native provider handles.
These are responsibilities within the existing v8 path, not additional services.
AX uses canonical `workerId`, `model` and `reasoningEffort` binding fields as
execution defaults. They do not identify the Conversation or rewrite historical
turns. Worker branding is a shared presentation concern; the Work view has no
provider execution branches. Architecture checks enforce the Workflow execution
delegation and keep native session state out of composer code.
See [Conversation Continuity v1](docs/specifications/CONVERSATION_CONTINUITY_V1.md#phase-28--workflow-and-execution-boundaries).

## Runtime and protocol boundaries

~~~text
AX <-> Cloud                 Human Product Protocol
Cloud <-> Workspace          Workspace Runtime Protocol
Workspace <-> Engine          Local Worker Protocol 4.0
Engine <-> provider CLI       Profile-defined structured invocation
~~~

Each boundary has its own identity, authorization, transport, versioning, and wire schema. Provider credentials and raw provider session data do not enter Cloud APIs or the Workspace Runtime Protocol.

See [Protocol Boundaries](docs/architecture/PROTOCOL_BOUNDARIES.md) and the [Tool Profile v1 specification](docs/specifications/TOOL_PROFILE_V1.md).

Workspace is a persistent, headless Dart service (the unified
`syntila` binary) that retains the separate CLI Worker Engine
process. The `syntila` CLI is an IPC management client and does
not compose or start an in-process runtime; there is no Workspace GUI. The canonical ownership, lifecycle,
filesystem, security, build, and validation contract is
[Workspace architecture](docs/architecture/WORKSPACE_ARCHITECTURE.md).

## Security and release trust

Cloud owns human identity, Space roles, Workspace ownership, Space-to-Workspace grants, Thread authorization, step-up authentication, and Profile administration. Workspace validates current Profile schema, identity, digest, and compatibility, then supervises Engine and provider CLI processes. Workspace application-release keys remain in protected release infrastructure; provider credentials remain with the locally installed provider CLI.

See [Release Trust and Rotation](docs/security/RELEASE_TRUST_AND_ROTATION.md), [Workspace release operations](docs/deployment/WORKSPACE_RELEASES.md), and the historical [Workspace desktop lifecycle validation](docs/operations/WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md).

## Current implementation status

The repository has converged on the v8 assignment path and clean v8 schema. The v8 release declaration remains withheld until the roadmap’s real-provider, release lifecycle, Work v1, and failure/security acceptance gates have retained evidence. See the [current implementation roadmap](docs/roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md).

## Current references

- [V9 communication/execution acceptance](docs/acceptance/EXECUTION_RELIABILITY_V9.md)
- [V9 communication/execution rollout and recovery](docs/rollouts/EXECUTION_RELIABILITY_V9.md)

- [Space/Thread rename completion and rollout requirements](docs/architecture/SPACE_THREAD_RENAME.md)

- [Worker Profile V9](docs/specifications/WORKER_PROFILE_V9.md)
- [Architecture v8](docs/architecture/ARCHITECTURE_V8.md)
- [ADR-018: Generic CLI Worker Engine and Tool Profiles](docs/decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md)
- [ADR-019: Syntila Profile Lab Architecture Contract](docs/decisions/ADR-019-syntila-profile-lab.md)
- [Conversation Continuity Phase 0 audit](docs/architecture/CONVERSATION_CONTINUITY_PHASE_0_AUDIT.md)
- [Work v1 Contract](docs/specifications/WORK_V1_CONTRACT.md)
- [First-Party Worker Catalog v1](docs/specifications/FIRST_PARTY_WORKER_CATALOG_V1.md)
- [Tool Profile v1](docs/specifications/TOOL_PROFILE_V1.md)
- [Tool Profile Lifecycle](docs/specifications/TOOL_PROFILE_LIFECYCLE.md)
- [Tool Profile Evidence Contract](docs/specifications/TOOL_PROFILE_EVIDENCE_CONTRACT.md)
- [Protocol Boundaries](docs/architecture/PROTOCOL_BOUNDARIES.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Workspace UX and data contract](docs/architecture/WORKSPACES_UX_CONTRACT.md)

## AX client server-state foundation

The isolated in-memory [AX server-state layer](docs/architecture/AX_SERVER_STATE.md)
provides typed query caching, scoped listeners, race protection, and optimistic
mutations over existing HTTP loaders. Space/sidebar navigation now consumes
independent cached Space details and Thread collections, retaining
expanded Spaces across navigation. Navigation synchronously changes route
state and ensures those resources in the background; `loadBootstrapState` remains
a bootstrap/recovery API. Work history uses a shared infinite query with a
bounded recent page, on-demand older pages, and targeted realtime reconciliation.
Healthy sockets disable Work polling; a fifteen-second fallback runs during
outages and stops after scoped recovery. The shell has no five-second snapshot
polling: Run/execution signals reconcile identified Work Requests and never
reload bootstrap, Spaces, Workspaces, or session data.
An optional, user-scoped IndexedDB read cache restores allowlisted server data
after Cloud authentication, renders it as stale, and revalidates in the background.
Logout clears memory and that user's persisted data; credentials and pending
mutations are never persisted. In memory, AX keeps 20 recent Thread histories
and up to 200 rows per inactive collection, protecting visible histories and
pending operations. Eviction releases cache data only; Spaces and the Workflow
catalog remain cached for the authenticated session. Collaboration state lives
in shared queries; the shell exposes only a legacy execution projection. Browser foreground return and network restoration
revalidate active stale queries in the background while cached content stays
visible; temporary failures show a narrow connectivity/staleness notice. Stable
Space and Workflow reads use optional [content revisions](docs/specifications/AX_CONDITIONAL_READS.md)
to avoid retransmitting unchanged representations after authorization.

AX Discussion history uses shared, paginated in-memory state with per-message
optimistic writes; see [server-state ownership](docs/architecture/AX_SERVER_STATE.md)
and the [v1 paging contract](docs/specifications/DISCUSSION_PAGING.md).

## Global Workflow configuration

Global per-user Workflow preferences are separate from Syntila-owned definitions
and Space/Thread state. Workflows is the sole global execution editor. Thread
configuration retains authored context, and the existing composer displays its Space’s
choices without submitting an execution override. Each Space inherits its owner’s
global defaults until that workflow is customized; a Space override applies to
every Thread and requester. Each scope selects one owned Workspace; only its
Workers can be selected or resolved automatically. A confirmed Workspace switch
resets the scope's workflows. Explicit Space Workspace selection forks its
configuration from global defaults; otherwise the Space inherits the owner’s
Workspace. New Spaces receive its execution grant. The Space Workspaces tab and
Space-wide allowWork setting are retired in migration 0022. Reset restores
workflow inheritance within the scope's selected Workspace.

```text
Workflow Definition
       ↓
User Workflow Configuration (Space owner)
       ↓
Space Workflow Configuration
       ↓
Execution Resolution
       ↓
WorkflowRun
       ↓
StepRun
```

Cloud freezes Worker/Profile release/model/effort per accepted step. Scheduler
retries consume this immutable snapshot; current preferences and catalog changes
cannot rewrite historical WorkflowRun/StepRun configuration. Auto model and effort
remain null, preserving the current Profile/CLI default without provider assumptions.

```text
User Workflow Configuration
       ↓
Space Workflow Configuration
       ↓
Thread preference       [future]
       ↓
Composer override       [future]
```

Those future overlays can use the existing sparse selection type; neither exists
in the current runtime. See [ADR-019](docs/decisions/ADR-019-per-user-workflow-execution-configuration.md)
and [User Workflow Configuration v1](docs/specifications/USER_WORKFLOW_CONFIGURATION_V1.md)
for persistence, migration, resolution, security, cache, and validation boundaries.

People is a private, automatic directory of established collaborators, separate from Space membership. Cloud persists one user-ID pair after membership establishment and joins current profiles; AX shares one reactive session cache between People and invitations. See [People v1](docs/specifications/PEOPLE_V1.md).

The user owns a private People directory of known collaborators and participates in Spaces through Members, Invitations, and Permissions. First collaboration follows email invitation → acceptance → People relationship; future collaboration follows People selection → Space invitation → acceptance. Both invitation entry points share one permission-aware subsystem, with known recipients persisted by user ID.

Workspace lifecycle: `syntila service install|start|stop|restart|status`
manages the per-user background service through the host manager (systemd user
unit, macOS LaunchAgent, Windows scheduled task), while runtime commands and
Worker tests use authenticated local IPC. The service process (`workspace`)
owns Cloud WebSocket/HTTP fallback; `syntila-agent` is its separate generic CLI
Worker Engine. Service process health and Cloud connectivity are distinct.
Stopping drains work before exiting; closing a terminal or the CLI preserves
execution. Clients may cache Worker display snapshots, but configuration and
execution state remain service-owned.

Non-secret configuration (Cloud origin, connect-on-start, name, parallel slots,
Work Root and named folders) lives in `<state>/workspace.nano`, which the
service reads once at startup; changes apply on restart and manual changes do
not move user files. The installation lock protects configuration writes, and
service IPC readiness is independent of Cloud handshake completion.

Profile-declared CLI model discovery and its Service/Cloud inventory boundary are
documented in [Gemini/AGY Profile](docs/architecture/GEMINI_AGY_PROFILE.md). The
Engine remains provider-independent; unsigned authoring templates never grant
production execution capabilities.
