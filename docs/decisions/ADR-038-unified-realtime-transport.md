# ADR-038: Unified Realtime Transport for Human and Worker Actors

- **Status:** Proposed
- **Date:** 2026-11-19
- **Split from:** ADR-031 (D4 transport parts)
- **Order:** 7 of 8. Depends on ADR-033 and ADR-034. Can run in parallel with ADR-035–037.
- **Related:** `UNIFIED_MESSAGING_PROTOCOL_V1.md`

## Context

There are two transport stacks: the per-user realtime gateway and the Workspace runtime gateway. They have separate contracts, queues and authentication. Maintaining both doubles the backpressure, replay and security work.

## Decision

1. **One gateway implementation and one versioned envelope** (`syntila.messaging/1`), shared by human clients and Worker Agents.
2. **The shared wire format doesn't mean shared rights.** Principals (`human`, `worker`, `system`) authenticate with different credentials, scopes and rate limits. The server derives identity from credentials and never trusts a client-supplied `actorId`.
3. Browser clients use a short-lived, origin-bound, single-use realtime ticket. Agents use the key-based authentication from ADR-034.
4. **Layering:** `TransportConnection` (socket, queue, auth, metrics) → `SubscriptionRegistry` → `DurableReplay` and `EventPublisher` (ADR-033) → `WorkerCommandInbox` → domain handlers. No Durable Object concepts in the core.
5. **Subscription scopes:** humans subscribe to user, Space and Thread scopes, checked against permissions when they subscribe. When access is revoked, the subscription is invalidated immediately. A Worker subscribes only to its own `worker_inbox` and `assignment` control scopes, and fetches assignment context through a server endpoint limited to that assignment.
6. **Subscription bootstrap without races:** subscribe and get a watermark, take an HTTP snapshot, apply events above the snapshot, acknowledge the last contiguous event that was applied.
7. Old Workspace runtime frames are parsed only through a **compatibility bridge** that is deleted after cutover. There are no permanent parallel stacks.

## Consequences

- `realtime-gateway.ts` and `workspace-gateway.ts` merge. `packages/workspace-runtime-protocol` becomes the compatibility bridge.
- This ADR isn't required for the Worker-first product (ADR-035). It is required before ADR-039, so that there is only one stack to scale.
