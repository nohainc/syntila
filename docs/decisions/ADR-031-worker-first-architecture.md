# ADR-031: Worker-first Actors, Unified Messaging and Multi-node Realtime

- **Status:** Split, superseded by ADR-032 to ADR-039 (kept for context)
- **Split into (in order):** [ADR-032 Identity](./ADR-032-worker-instance-and-actor-identity.md), [ADR-033 Durable events/inbox](./ADR-033-durable-events-outbox-and-command-inbox.md), [ADR-034 Agent/fencing](./ADR-034-standalone-worker-agent-and-session-fencing.md), [ADR-035 Worker-targeted execution](./ADR-035-worker-targeted-execution-and-workspace-removal.md), [ADR-036 Timeline](./ADR-036-canonical-thread-timeline-and-attribution.md), [ADR-037 Files/artifacts](./ADR-037-local-files-and-cross-worker-artifacts.md), [ADR-038 Unified transport](./ADR-038-unified-realtime-transport.md), [ADR-039 Horizontal scaling](./ADR-039-horizontal-scaling.md). Phases: [`WORKER_FIRST_IMPLEMENTATION_PHASES.md`](../roadmaps/WORKER_FIRST_IMPLEMENTATION_PHASES.md)
- **Date:** 2026-11-19
- **Scope:** Syntila Flutter app; Bun backend; PostgreSQL; Worker Agent; generic CLI Worker Engine; realtime infrastructure; existing Spaces, Threads and Workflows
- **Decision owners:** Syntila product/engineering

## Context

Today human Discussion and AI Work Requests are distinct backend/UI paths. Local Workers are owned by a Workspace, Workspace has a single authenticated runtime connection, assignments route to Workspace then Worker, and Spaces/Workflows select a Workspace and require grants. This creates significant configuration overhead for the user and two connection/delivery stacks to evolve. The code port from Cloudflare to Bun/PostgreSQL already has an in-process Durable Object adapter explicitly scoped to one node, while per-user realtime gateways and Workspace runtime gateways use separate transport contracts.

The product goal is a messaging-first Syntila in which people and AI Workers participate in Threads, any eligible Worker can be selected directly, and messaging can scale across multiple Bun instances. Most users are expected to register one Worker; some will own several, possibly on different computers. Workers must be deployable without a Workspace application.

## Decision

### D1 — First-class Worker Instance and Actor identity

- Introduce **Worker Instance** as a unique, durable, user-owned product object (`worker_id`), separate from **Worker Type** (`worker_type_id`) and its signed Profile.
- Each Worker Instance owns exactly one Worker Actor identity. A human has a Human Actor identity. Automated platform-originated events use a constrained System Actor identity.
- Worker display `name` is user-editable and **not unique**; use immutable IDs for binding, routing and authorization. Allow optional descriptive alias for disambiguation. Capture a name/type snapshot where historical presentation requires it.
- Do **not** model Workers as ordinary human accounts in the `users` table. A Worker has no implicit email, billing identity, People approval flow, or unrestricted human permissions.

### D2 — One independent authenticated connection per Worker

- Each online Worker Agent maintains its own direct WSS connection and its own session, resume cursor, identity and durable local assignment journal.
- Backend routes to Worker identity, not to Workspace identity. Multiple Workers on one host are independent connections.
- At most one **current active session** per Worker Instance; a newer valid session fences previous sessions using monotonically increasing session epoch. Commands and terminal writes validate current assignment/run/attempt fences; an obsolete connection must not forge current state.
- One Worker may have zero or one live Agent connection; its persisted identity survives restarts/disconnections. Offline Workers remain selectable for historical reference; invocation policy may queue with bounded TTL or fail explicitly, never silently reroute to another Worker.

### D3 — Workspace removed from product and scheduling

- Replace user-facing **Workspaces** navigation with **Workers**.
- Remove Space-to-Workspace and Workflow-to-Workspace selection as a requirement for executing a Worker.
- Worker eligibility is resolved from ownership or explicit sharing grant, Space/Thread execution rights, Worker status, Worker capabilities and local permission constraints.
- Workspace *may* exist only as an optional **local, client-side Worker Manager** for multi-Agent installation/supervision; it does not own a Syntila Cloud execution identity or proxy Worker traffic.
- No required machine name, platform, host identifier, host routing or location field in the product data model. Retain minimal server-side agent version/session diagnostics for security and support.

### D4 — Common messaging infrastructure; separate domain semantics

- Human clients and Worker Agents use one versioned connection protocol, one realtime gateway implementation, one durable event publication/replay mechanism and one authorization framework.
- Human and Worker principals authenticate with separate credentials, scopes and rate limits. The shared wire envelope does not imply shared privileges.
- Distinguish durable **conversation messages** from **execution commands**, **execution evidence** and **transient activity**. They share transport; their persistence, authorization, retries and consequences differ.
- A normal human message must not automatically execute a Worker. An authorized explicit Ask AI/mention/automation intent creates a Work Request; Work execution remains server-controlled.

### D5 — Canonical message timeline

- Canonical Thread history supports Human and Worker authors with immutable `actor_id`, optional Work Request linkage, and deterministic deduplication of Worker final answers.
- Keep Work Requests, Runs, Tasks, Assignments, Workflow state, snapshots, lease fencing and provider session policy as distinct execution records.
- AI final answer is committed once as a conversation projection, linked to the authoritative execution result. Multi-step internal Worker responses need not each become user-visible messages unless the Workflow explicitly exposes them.
- Existing Work history and human Discussion messages require migration/compatibility, not unsafe reinterpretation. User-facing timeline retains actionable Work cards and execution detail views.

### D6 — Worker's local environment and file boundaries

- Each Worker Agent owns a private local data directory, profile cache, credential store, process/journal state, allowed folders and per-Space working directory mapping.
- Workers on distinct machines do not share local paths, provider native sessions, file trees or uncommitted results by implication of being in the same Thread.
- Cross-Worker handoffs pass explicit artifacts, Git references or user-authorized external resources with bounded permissions; backend checks grants for each transfer.
- Existing allowed-folder protections, signed Profile validation, process-tree termination, local CLI permissions and no-provider-credential-upload invariants remain.

### D7 — Horizontal scaling is part of v1 target

- Run one or more stateless Bun API/realtime gateway replicas behind TLS termination and a load balancer, initially in one write region with PostgreSQL close to compute.
- A durable event is persisted atomically with the mutation, its per-stream sequence and an outbox delivery signal. Local sockets receive notifications; gaps recover via ordered durable replay or authoritative HTTP reads.
- Cross-node notification is **not** the durability layer. Start with PostgreSQL LISTEN/NOTIFY as a post-commit wakeup for durable events (subject to benchmark); use a persistent outbox sweeper and reconnect reconciliation. Introduce Valkey/Redis for high-frequency cross-node ephemeral fan-out only if profiling justifies it.
- Worker session directory, distributed job/workflow leases and fencing prevent duplicate logical ownership across nodes. Postgres locks/conditional writes are authoritative; in-memory routing is an optimization.
- A future US/EU read or execution footprint must not accidentally create multiple writers for the same actor/stream. Active-active multi-region is outside this ADR.

### D8 — Delivery classification

| Class | Examples | Persist | Delivery behavior |
| --- | --- | --- | --- |
| Durable message | Human message, final Worker reply | Yes | Mutation commits before notification; replay/read-model recovery |
| Durable command | Assignment start/cancel, control intent | Yes | Addressed to Worker inbox; admission/terminal acknowledgements, idempotent retries |
| Durable lifecycle | Work Request created/completed, critical tool/lifecycle facts | Yes | Bounded event log, replay; event must not replace assignment state authority |
| Ephemeral | Presence, replaceable status, progress snapshot | No | Coalesce/drop on congestion; full snapshot/reconciliation when needed |

Never promise exactly-once transport delivery. Promise idempotent logical effects and eventual reconciliation under documented retention/availability assumptions.

## Product UX consequences

- **Workers** page: register, rename, see type/icon, capabilities/models, online/offline/disabled, version, optional alias, install/transfer/revoke/remove, local connection and safe error state.
- Thread composer: Message / Ask AI, Worker picker from eligible visible Workers, model/effort for the selected Worker, optional Workflow/Step-specific binding and explicit fallback. No Workspace selector, no Space Workspace grant workflow.
- Duplicate names permitted; picker disambiguates with type + optional alias + status and, if necessary, suffix of immutable ID.
- Group Space members can use their own Workers when they have execution rights; another person's Worker requires an explicit sharing grant. Direct Spaces retain symmetric messaging and independent own-Worker execution rights.
- Shared history exposes who requested work and which Worker authored its answer. Worker online/offline never rewrites historical messages.

## Security / reliability invariants

1. Server derives Human and Worker principal identity from verified credentials, not client-supplied `actorId`.
2. A Worker may only fetch commands addressed to itself; messages and artifacts are checked against Thread/Space visibility and execution grants.
3. Authorization of a Worker to respond to one assignment does not grant it permission to join unrelated Threads, browse a user's other messages or initiate arbitrary commands.
4. Worker sharing cannot silently grant physical filesystem access; local Agent confirms and enforces permissions.
5. Assignment admission, start and terminal evidence remain separate; stale attempts, session epochs and lease tokens are fenced.
6. Terminal result and conversation reply are idempotent; no duplicate answer on replay/retry.
7. Durable writes survive socket or node failure, and missing notifications are repaired from PostgreSQL.
8. Queues are bounded in both bytes and events; backpressure cannot cause unbounded memory growth.
9. Worker display names and optional location descriptions are never routing keys or permission sources.
10. Provider secrets/native session handles remain local; Cloud stores only non-sensitive projections and opaque references.

## Non-goals

- A separate compiled provider-specific application for each Worker Type.
- Always-on provider CLI subprocesses just to maintain the Worker WebSocket.
- A generic permission grant for all Space participants to execute another person's Worker.
- Shared filesystem semantics between independently hosted Workers.
- Multi-region active-active PostgreSQL writes or global linearizable presence.
- Turning execution assignment retries into ordinary chat-message redelivery.
- A mandatory Docker/Kubernetes/Redis deployment on day one.

## Alternatives considered

1. **One connection per Workspace (current):** efficient socket count but forces multiplexing and makes Workspace a user-facing selection resource. Rejected for the target product.
2. **One Worker connection but retain Workspace-as-Cloud-resource:** partial simplification; leaves Space grants and hosting concepts in the selection path. Rejected as mandatory, may preserve local Manager functionality.
3. **One binary per Worker provider:** duplicates transport, auth and Engine supervision. Rejected in favor of generic Agent plus signed Profiles/plugins.
4. **Redis/Valkey or Kafka as primary authority:** adds operational dependency and weakens simple transactional consistency with messages. Rejected; PostgreSQL remains authoritative. A separate bus may be a future optimization.
5. **Pure ephemeral NOTIFY routing:** cannot recover missed notifications and is unsafe for offline agents. Rejected; event log and agent command inbox required.

## Relation to existing decisions

Upon ratification and full migration, this ADR supersedes Workspace-as-Cloud-execution-owner portions of ADR-012, machine connection boundaries in ADR-013/014, Workspace selection/grants in Work v1 and Workspaces UX contracts, and Workspace-specific parts of ADR-029. Preserve the parts defining local execution security, provider Engine/Profile, Person/Space/Thread authorization and durable execution lifecycle. Until migration gates pass, existing contracts govern the production path. Do not rewrite historical ADR text as if this was always the design; mark replaced portions with explicit links.

## Acceptance for ADR implementation

- Two Worker Instances of the same type and name connected from different hosts; independent routing, authorization, configuration and results.
- Human and Worker connections pass through one gateway implementation and schema package.
- User can issue Work from a permitted Thread using any eligible Worker without attaching a Workspace to a Space.
- A two-node deployment delivers human and Worker events across different gateway nodes, survives a single-node crash, fences old Worker sessions and replays durable data without duplicate logical effects.
- A worker on another host cannot read a different worker's local filesystem or unreleased artifacts.
- Old Workspace paths removed after formal parity, migration and rollback tests.

## Decisions still requiring explicit policy (not implementation blockers)

- Offline Worker submission: **recommended default** queue with configurable short TTL for explicitly requested Workers; UI must show queued/offline, allow cancel, no silent fallback.
- Sharing a Worker with another human: **recommended default** private to owner, opt-in per-Space/Thread grant with restricted tools; can launch later.
- Multiple Worker instances using the same provider CLI auth: independent Worker identity even if local provider credentials happen to be shared; user remains responsible for provider-side concurrency limits.
