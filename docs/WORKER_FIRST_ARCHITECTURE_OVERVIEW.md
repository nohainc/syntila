# Syntila — Worker-first Architecture Package

**Status:** PROPOSED FOR REVIEW, not implemented.  
**Prepared:** 2026-11-19.  
**Target repository:** `nohainc/syntila` (`main`).  
**Purpose:** Replace Workspace-first execution with individually connected Worker actors and a horizontally scalable shared messaging infrastructure.

## Files and reading order

1. [`docs/decisions/ADR-031-worker-first-architecture.md`](./decisions/ADR-031-worker-first-architecture.md) — product/architecture decision, boundaries, trade-offs, non-goals and supersessions.
2. [`docs/architecture/WORKER_FIRST_SYSTEM_ARCHITECTURE.md`](./architecture/WORKER_FIRST_SYSTEM_ARCHITECTURE.md) — architecture, identities, data ownership, authorization, file handling, conversation model, runtime and UI.
3. [`docs/specifications/UNIFIED_MESSAGING_PROTOCOL_V1.md`](./specifications/UNIFIED_MESSAGING_PROTOCOL_V1.md) — API/wire contracts, delivery states, backpressure, outbox, replay, cluster topology, session fencing, operational SLOs.
4. [`docs/specifications/WORKER_AGENT_RUNTIME_V1.md`](./specifications/WORKER_AGENT_RUNTIME_V1.md) — installation, credentials, execution/acknowledgement, per-agent security, profile/Engine reuse, local data and recovery.
5. [`docs/roadmaps/WORKER_FIRST_MIGRATION_AND_SCALING_PLAN.md`](./roadmaps/WORKER_FIRST_MIGRATION_AND_SCALING_PLAN.md) — dependency-ordered, implementation-ready phases, affected code, migrations, acceptance gates, staging and rollback.

## Decisions made in the proposal

- **Remove Workspace from user-facing product and execution selection**. Top-level `Workers` replaces `Workspaces`.
- **A Worker Instance is the schedulable identity** (`worker_id`); it has a stable actor identity and its **own authenticated WebSocket connection**. No shared Workspace runtime WebSocket.
- **Worker names are not unique**. Bind on immutable Worker IDs, never names, and retain helpful display snapshots for history.
- **Worker Type is distinct from Worker Instance**. Type/profile drives provider integration, icon, models, capabilities and Profile revision; instances are independently named/registered/configured.
- **A Worker may run without a Workspace**. A common standalone Worker Agent uses the existing generic CLI Worker Engine and signed profiles. An optional local manager may supervise several independent agents; it does not proxy their traffic.
- **Any eligible owned Worker can be selected in a Thread** regardless of its computer. A Space-to-Workspace grant is not required. Shared use of another user's Worker requires an explicit, revocable grant; permission to read a Thread does not grant tool execution.
- **Human and Worker connections share one messaging infrastructure and versioned envelope**, but domain commands, execution admission, machine credentials, and provider permissions stay differentiated.
- **Messaging and multi-node readiness are one migration**: add a transactional outbox/event log, cross-node wakeups, local subscription indices, Actor session fencing, recovery, and bounded backpressure before old paths are removed.
- **Single writable PostgreSQL region initially**, with multiple Bun gateway replicas in the same region. Cross-region active-active writes are out of scope.

## Design principles

1. One actor identity per registered Worker Instance, one active connection per Worker Instance, one authoritative assignment lifecycle.
2. PostgreSQL is authoritative for messages, Work Requests, assignment state, durable events and outstanding Worker commands; WebSocket delivery is an optimization, not a source of truth.
3. Durable effects are idempotent. Transport delivery is **at least once**, with application-level deduplication and monotonic state transitions. Do not claim exactly-once transport delivery.
4. A Worker is not a human account. Sharing chat history does not grant filesystem access or execution privileges.
5. A server does not infer Worker physical location. User-supplied display description is optional; internal non-sensitive installation/session diagnostics are permitted.
6. One connection per Worker does **not** imply a permanently running provider CLI: launch it on demand.
7. An AI response is both an execution outcome and a conversation projection, linked atomically to one authoritative Work Request; no duplicated visible messages on retries.
8. Shared files are explicit artifacts or declared external references. A Thread does not imply a shared local filesystem across Workers.

## How to use

These documents are located in their matching paths in the repository. Review and ratify ADR-031 **before** modifying existing accepted ADRs. The roadmap deliberately includes dual-path migration gates and tests. These docs do not claim the proposal is already implemented.

## References verified in current repository

- `apps/backend/src/runtime.ts`, `apps/backend/src/platform/durable-objects.ts`, `apps/backend/src/domain/event-publisher.ts`, `apps/backend/src/domain/realtime-gateway.ts`.
- `apps/backend/src/domain/assignment-dispatcher.ts`, `apps/backend/src/domain/workspace-gateway.ts`, `apps/backend/src/domain/routes/work-creation.ts`.
- `apps/workspace/lib/workspace_runtime.dart`, `apps/workspace/README.md`.
- `docs/decisions/ADR-012-workspace-owned-local-workers.md`, `ADR-029-direct-spaces-and-personal-connections.md`.
- `docs/specifications/REALTIME_SYNCHRONIZATION.md`, `WORK_V1_CONTRACT.md`, `WORKER_PROFILE_V9.md`, `CONVERSATION_CONTINUITY_V1.md`.
- `docs/roadmaps/VPS_BACKEND_MIGRATION_PLAN.md`.

External implementation references:
- Bun WebSockets/backpressure: https://bun.com/docs/runtime/http/websockets
- PostgreSQL NOTIFY: https://www.postgresql.org/docs/current/sql-notify.html
- PostgreSQL LISTEN: https://www.postgresql.org/docs/current/sql-listen.html
