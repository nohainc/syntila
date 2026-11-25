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
7. Old Workspace runtime frames are parsed only through a **compatibility bridge** that is deleted after cutover. There are no permanent parallel stacks.

## Consequences

- `realtime-gateway.ts` and `workspace-gateway.ts` merge. `packages/workspace-runtime-protocol` becomes the compatibility bridge.
- This ADR isn't required for the Worker-first product (ADR-035). It is required before ADR-039, so that there is only one stack to scale.

## Flutter client on `syntila.messaging/1` (2026-11-20, in code, not compiled or run)
The web app now speaks only the unified protocol (`apps/app/lib/src/realtime/realtime_messaging.dart`, a socket-free adapter with Dart tests, and a thin `realtime_client_web.dart`). It subscribes to the `user`, `space` and `thread` streams (`me` names the caller's own user stream), resumes from per-stream cursors, acknowledges durable events, and turns envelopes into the event maps the app's routers already read, so nothing downstream changed. Envelopes gained `context` (entity ids: spaceId, threadId, runId, taskId, attemptId, assignmentId, workspaceRuntimeId) so routing needs no second lookup. A Space event copied to its Thread is delivered once (by `eventId`). Not carried over: the `run` and `execution_workspace` scopes (run events arrive on the Space and Thread streams; legacy Workspace events no longer reach the app, which P10 retires). The server's legacy human frames stay until every deployed app build is the new one; then delete them with the bridge. Requires flag `unified_gateway` on.
