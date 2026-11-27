# Realtime synchronization contract

Realtime events belong to the Human Product Protocol (`syntila.messaging/1`).
Cloud owns persistent collaboration state; events are small change signals for
authenticated HTTP reconciliation, not copies of entity histories. Worker
transport (`syntila.worker-agent-protocol`) and provider execution are separate.

## Durable stream identity

Every durable event belongs to an explicit `stream: { kind, id }`, where `kind`
is `space`, `user`, `thread`, or `worker`. A stream owns its monotonic sequence
and idempotency namespace independently of subscription scope. Stream identity,
not the currently selected Space, governs sequencing and synchronization.

Work Request lifecycle payloads may include optional `requestedByUserId`, the
Cloud-read requester identity used to suppress redundant completion notices for
the requester. It does not change stream authorization.

## Collaboration signals

| Event | Envelope IDs | Payload IDs |
| --- | --- | --- |
| `space.created`, `space.updated`, `space.archived`, `space.deleted` | `spaceId` | `entityId` (Space) |
| `thread.created`, `thread.updated`, `thread.deleted` | `spaceId`, `threadId` | `entityId` (Thread), `threadId` |
| `discussion.created`, `discussion.updated` | `spaceId`, `threadId` | `entityId` (message), `threadId` |

These durable payloads accept identifiers only. Authored text, settings, histories,
credentials and complete entities are excluded. Archiving emits
`space.archived`; unarchiving emits `space.updated`.

Space, Thread, and Discussion mutations and their durable signal are committed
atomically in PostgreSQL. Validation precedes sequence allocation. Fanout runs
after persistence; a disconnected gateway cannot undo the committed write.

Space membership selects recipients. Deletion captures the authorized member
audience before transactional cleanup, then sends the ID-only tombstone after
commit. Current users are rechecked before WebSocket delivery. Deletion drops
invalid focused subscriptions while retaining the user scope. User streams route
only to their named user's gateway.

## Browser reconciliation and reconnect

One authenticated browser socket subscribes to user scope and sends its
per-stream cursors on reconnect. Sequence gaps and queue overflow include
explicit stream identity. Replay filters acknowledged events by the client's
per-stream cursor before applying the 256-row limit. Streams without a cursor
start at their first retained event. A full 256-row page conservatively sends
`sync.required` with reason `replay_limit` and the requested scope, even if
exactly 256 events remain. Sequence gaps use `durable_event_gap` with stream
identity. Retention and bounded replay mean there is no complete historical
replay promise.

Ready/user recovery refreshes observed current-state queries and the Space
catalog, including creations/deletions missed while disconnected. Narrow Space
gaps recover the Space entity and its Thread list; Thread gaps recover forward
Discussion cursors and active Work Requests. Worker gaps recover the affected
Worker state. Cached data remains visible, immutable older pages are not
refetched, and no reconnect frame loads a bootstrap snapshot. See
[AX server state](../architecture/AX_SERVER_STATE.md#realtime).

The web app routes Space/Thread signals to keyed caches. `discussion.created`
follows the newest known creation cursor without refetching older pages.
`discussion.updated` fetches only the changed message when it is already cached,
including messages in older pages. `GET /api/discussion-messages/:id` returns
`{ message }` after current Thread view authorization. Optimistic overlays
remain above the authoritative collection. Late responses cannot repopulate a
cleared session. Space deletion removes cached Space queries and fences
pending reads.

## Durable streams, outbox and cursors (ADR-033)

Event durability, the outbox, stream kinds, cursor semantics (`lastEnqueuedSequence` versus the client's applied acknowledgement, `ack` message) and queue bounds are specified in [EVENT_STREAMS.md](EVENT_STREAMS.md) and [UNIFIED_MESSAGING_PROTOCOL_V1.md](UNIFIED_MESSAGING_PROTOCOL_V1.md).
