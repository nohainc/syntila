# ADR-039: Horizontal Scaling Across Multiple Bun Nodes

- **Status:** Proposed. The decision is accepted, but **activation is gated on measured load**.
- **Date:** 2026-11-19
- **Split from:** ADR-031 (D7 cluster parts)
- **Order:** 8 of 8. Depends on ADR-033, ADR-034 and ADR-038.
- **Related:** `VPS_BACKEND_MIGRATION_PLAN.md`

## Context

The Bun port runs an in-process Durable Object adapter limited to one node. The ADR-033 rules make the system *safe* to run on several servers. This ADR covers actually running more than one.

## Decision

1. **Topology:** one writable PostgreSQL region (EU), 1 to N stateless Bun HTTP/gateway nodes behind Caddy/TLS, with no sticky routing. Active-active writes across regions are out of scope.
2. **Wakeups between servers:** `LISTEN/NOTIFY` on a dedicated connection per node, carrying event or command IDs only, as a **wakeup and never as durable storage**. The outbox dispatcher and gap sweeper from ADR-033 recover lost notifications. Valkey/Redis is added only if profiling shows NOTIFY is a bottleneck.
3. **Node-local subscription index** keyed by stream. A node fetches an event only when it has local subscribers.
4. **Worker session directory:** `(worker_id, session_epoch, node_id, connection_id, lease_expires_at)`. When a session is locked out, a control notification tells the old node to close the socket. The epoch checks from ADR-034 stay authoritative.
5. **Distributed ownership:** every coordinator, timer and cron job that lives in process memory moves to PostgreSQL leases with fencing (conditional updates, `SKIP LOCKED`). Recovery jobs are claimed, not run on every node.
6. **Activation gate:** we run with more than one node in production only when load tests on the target VPS show that one node misses targets (p99 API under 150ms, fan-out under 250ms at 2,000 sockets, plus the Worker activity mix), **or** when rolling zero-downtime deploys become a requirement. Until then, two-node tests run in CI so the rules can't silently break.
7. Operations: separate liveness and readiness checks, graceful drain, Agent reconnect with jitter, a Postgres connection budget per node.

## Consequences

- Phase 10 (distributed workflow ownership) is the highest-risk work. It is scheduled last and only when needed.
- The scaling claims must come from measuring 1, 2 and 3 nodes, not from counting connections.
