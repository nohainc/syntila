# ADR-038: Unified Realtime Transport for Human and Worker Actors

- **Status:** Accepted and implemented
- **Date:** 2026-11-19
- **Related:** `UNIFIED_MESSAGING_PROTOCOL_V1.md`

## Context

Human clients and Worker Agents share one realtime transport architecture (`syntila.messaging/1`) with unified framing, backpressure, replay, and subscription management, while keeping principal authentication, scopes, and rate limits strictly separated.

## Decision

1. **One gateway implementation and one versioned envelope** (`syntila.messaging/1`), shared by human clients and Worker Agents.
2. **The shared wire format doesn't mean shared rights.** Principals (`human`, `worker`, `system`) authenticate with different credentials, scopes and rate limits. The server derives identity from credentials and never trusts a client-supplied `actorId`.
3. Browser clients use a short-lived, origin-bound, single-use realtime ticket. Agents use the key-based authentication from ADR-034.
4. **Layering:** `TransportConnection` (socket, queue, auth, metrics) → `SubscriptionRegistry` → `DurableReplay` and `EventPublisher` (ADR-033) → `WorkerCommandInbox` → domain handlers. No Durable Object concepts in the core.
5. **Subscription scopes:** humans subscribe to user, Space and Thread scopes, checked against permissions when they subscribe. When access is revoked, the subscription is invalidated immediately. A Worker subscribes only to its own `worker_inbox` and `assignment` control scopes, and fetches assignment context through a server endpoint limited to that assignment.
6. **Subscription bootstrap without races:** subscribe and get a watermark, take an HTTP snapshot, apply events above the snapshot, acknowledge the last contiguous event that was applied.
7. The Worker gateway translates between unified commands and its Worker Agent message handlers through `domain/messaging/bridge.ts`. Connect and Cloud use the versioned Worker Agent protocol for these messages.

## Consequences

- Human clients use `syntila.messaging/1` and subscribe to authorized user, Space and Thread streams. They resume with per-stream cursors and acknowledge applied durable events.
- Worker connections authenticate independently and use the Worker gateway. The bridge translates commands to existing Worker message handlers; it does not restore the retired human realtime frames.
- Cross-node wakeups remain subject to ADR-039.
