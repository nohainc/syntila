# Durable event streams, outbox and command inbox

Implements ADR-033 (Worker-first P2). Related: `REALTIME_SYNCHRONIZATION.md` (client protocol), `docs/decisions/ADR-033-durable-events-outbox-and-command-inbox.md`.

Migration `0050_remove_workspace_columns.sql` removes the retired
`execution_workspace` streams and their outbox rows, and retains the current
user, Space, Thread, Worker inbox and assignment streams. Deploy the matching
backend and Connect protocol changes together; older peers using the retired
envelope fields are incompatible. The sections below that describe the retired
stream need the documentation sweep tracked in F6.

## The rule: commit first, notify second

A durable event is written in **one PostgreSQL transaction** together with the domain change it describes:

1. the caller's writes (`DomainEventInput.mutate`),
2. the stream's next sequence (`UPDATE realtime_event_cursors … RETURNING`, no PostgreSQL `SEQUENCE`),
3. the `realtime_events` row,
4. the `outbox` row (`outbox_event_uq`: exactly one per event).

If anything fails, all four roll back, and no sequence number is consumed. Socket delivery is an optimization after the commit:

```
publish ─ tx(mutate, sequence, event, outbox) ─ commit ─ claim outbox row ─ wake gateway ─ mark delivered
                                                              │ (process dies / gateway fails / no gateway)
                                                              ▼
                              OutboxDispatcher (1 s poll): claim due rows, FOR UPDATE SKIP LOCKED, retry with backoff
```

- The committing process delivers inline. A fresh outbox row starts with `attempts = 0` and `next_attempt_at = now() + 10 s`, so the dispatcher leaves it to the inline path during that grace period. A claim sets a 30 s lease (`next_attempt_at`) and counts an attempt.
- A failed delivery is retried with backoff (2 s doubling, capped at 5 min). After 12 attempts the row is `dead`; clients still recover through replay or `sync.required`.
- `OutboxDispatcher` (`apps/backend/src/domain/outbox-dispatcher.ts`) runs from `createRuntime().start()`. Every 5 minutes it also sweeps: repairs events without an outbox row (a writer that bypassed the publisher), reports sequence gaps in the last 15 minutes (`outbox.sequence_gap` in the log) and expires Worker commands past `expires_at`.
- The audience trusted at commit time (`recipientUserIds`, `additionalRecipientUserIds`) is stored in `outbox.audience_json` and used at delivery, so a destructive change cannot widen or lose the audience.
- **Delivery is at-least-once**, deduplicated by `event_id`, per-stream `sequence` and idempotent domain transitions. It is not exactly-once.
- On one server the dispatcher wakes the local gateway. A second server does not receive wakeups yet (ADR-039); its clients recover by replay. `scripts/test-two-node.sh` reports this as the known realtime gap.

## Exactly one stream per event

Every event row has one `(stream_kind, stream_id)`. Fanning one event out to several streams is not allowed (it would make the hot cursor rows a lock bottleneck). Where an audience cannot subscribe to the natural stream, the publisher writes **a second, separate event** to that audience's own stream (for example the invitee's `user` stream).

| `stream_kind` | `stream_id` | Subscribers | Status |
| --- | --- | --- | --- |
| `user` | user id | that user | in use |
| `space` | Space id | Space members | in use |
| `execution_workspace` | Workspace id | the Workspace owner | legacy; retired in P10 |
| `thread` | Thread id | Thread participants | allowed since 0027; first emitter: P7 (timeline) |
| `worker_inbox` | Worker Instance id | that Worker's Agent | allowed since 0027; first emitter: P3/P4 |
| `assignment` | assignment id | the assignment's participants | allowed since 0027; first emitter: P5 |

## Which events go to which stream (today)

| Event types | Stream | Emitted by |
| --- | --- | --- |
| `space.created/updated/archived/deleted`, `thread.created/updated/deleted`, `thread.work_cleared`, `thread.chat_cleared`, `thread.queue_updated`, `thread.read`, `discussion.created/updated/deleted`, `workspace_space_grant.updated` | `space` (Space id) | `publishCollaborationEvent`, `routes/threads.ts` |
| the same collaboration types, for people who cannot subscribe to the Space (invitees, removed members) | `user` (their id), as a separate event | `publishCollaborationEvent` (`additionalRecipientUserIds`) |
| `people.updated`, `workspace_invitation.updated` | `user` (each affected user) | `people.ts`, `routes/people.ts`, `routes/workspace-invitations.ts` |
| `work_request.*`, `step.*`, `run.*`, `assignment.accepted/completed/failed/cancelled`, `artifact.created` | `execution_workspace` (Workspace id) | `workflow.ts`, `thread-coordinator.ts`, `assignment-phase-events.ts`, `routes/work-request-inputs.ts` |
| `assignment.activity`, `stream.delta`, `tool.invocation.status`, `heartbeat`, `worker.inventory.updated`, `workspace.readiness.updated` | none: **ephemeral**, never persisted, never in the outbox | `workspace-gateway.ts` |

Replayable `assignment.activity` types are the exception: they are durable and follow the table of `isReplayableRealtimeEvent`. Moving execution events to the `assignment` stream happens in P5 (targeted dispatch) and to the `thread` stream in P7 (canonical timeline); the legacy `execution_workspace` stream goes away in P10.

For Workspace-backed assignments, the gateway and dispatcher commit a
`step.phase` event and its outbox row in the same transaction as their
dispatch, admission, start permit, startup, result, failure, or cancellation
mutation. If event persistence fails, the mutation rolls back; socket delivery
is still post-commit and retried by the outbox. Events use an idempotency key
per assignment and phase. Some other recovery and bulk-queue writers do not yet
publish a phase in their transaction. Worker-targeted requests have no primary
Workspace and the existing `step.phase` wire contract requires one, so they do
not yet emit these phase events; their stream contract remains open in P5/P7.

## Delivery classes

| Class | Persisted | Behavior |
| --- | --- | --- |
| Durable message | `realtime_events` + `outbox` | replay and HTTP rebase |
| Durable command | `agent_commands` | addressed to one Worker; status follows the assignment |
| Durable lifecycle | `realtime_events`, bounded retention | replay; never overrides execution state |
| Ephemeral | no | coalesced or dropped under backpressure |

## Cursor semantics

- `lastEnqueuedSequences` (per connection, in memory only): the newest durable event handed to the connection's queue or socket. It only suppresses duplicates and detects gaps on that connection. It is **not an acknowledgement**, is never stored, and is cleared when the queue overflows (frames that were cleared were never sent).
- `appliedSequences` (per connection, in memory only): what the client reported as applied: the cursors in `realtime.hello` and later `{"type":"ack","stream":{"kind","id"},"sequence":n}` messages. Only a client acknowledgement moves it. An acknowledgement needs no database query.
- The gateway no longer writes cursors to `durable_object_storage` on every event. Only the subscription list is stored, and only when it changes. After a restore, a connection follows live events until the client's next hello or ack.

## Bounded queues

Each socket queue is bounded by items (128) and bytes (1 MiB, UTF-8 of the frames). Bun's `send()` status is honored: `-1` marks the socket backpressured until Bun's `drain` handler runs (the queue then flushes at once, with a 250 ms timer only as a fallback), `0` (dropped) closes the socket.

On overflow of a durable frame the gateway clears the queue, sends **one** `sync.required` (`reason: "connection_queue_limit"`) and takes no more frames for that connection until the client's next `realtime.hello`, so a client that stays slow costs a constant amount of memory. Ephemeral frames are coalesced by key, dropped when they do not fit, and displaced by durable ones.

`sync.required` is the wire name of the signal in ADR-033 (renamed from `sync.required` as part of ADR-038; the app, backend and their tests use the new name).

## Worker command inbox

`agent_commands(command_id, worker_instance_id, assignment_id, attempt_id, type, payload_ref, status, created_at, updated_at, sent_at, acked_at, expires_at)`.

- Written in the same transaction as `worker_assignments.command_payload_json`, before any wakeup; notifications carry IDs only. `payload_ref` is `worker_assignments:<id>`.
- One command per `(assignment_id, type)`, so creation is idempotent. `worker_instance_id` is filled from the P1 mapping and stays nullable until Agents address Workers directly (P3).
- Status follows the assignment through a trigger on `worker_assignments`: `dispatched` → `sent`; `acknowledged`, `running`, `completed` → `acked`; `cancelled` → `cancelled`; `failed` → `failed`; `timed_out`, `lost` → `expired`. Moves are forward only; `acked` and the closed states never change. The sweep expires open commands past `expires_at`.
- The existing Workspace delivery (`/dispatch-assignment`) is unchanged: it runs after the command row exists.

## Invariants (`apps/backend/scripts/check-invariants.sql`)

- every event written since the outbox exists has its outbox row;
- no outbox row stays pending for an hour;
- no open Worker command belongs to an ended assignment;
- every stream counter is ahead of the events it numbered (existing).
