# ADR-033: Durable Events, Transactional Outbox and Worker Command Inbox

- **Status:** Accepted and implemented
- **Date:** 2026-11-19
- **Related:** `REALTIME_SYNCHRONIZATION.md`, `COMMAND_DELIVERY_AND_REVOCATION_V9.md`, `EXECUTION_LIFECYCLE_V9.md`

## Context

Syntila needs one durability model for realtime events (`realtime_events`, `realtime_event_cursors`), transactional outbox delivery (`outbox`), and Worker command delivery (`agent_commands`) that is correct on one server and safe to run on multiple servers later without a redesign. Client cursors must advance only when the client applies an event, never when a frame is merely enqueued.

## Decision

1. **Commit first, notify second.** The domain change, the stream sequence, the event row and the outbox row are written in **one transaction**. Socket delivery is only an optimization.
2. **Per-stream sequence.** Each event takes the next number with `UPDATE realtime_event_cursors … RETURNING` inside the same transaction. Numbers have no gaps within a stream. We don't use a PostgreSQL `SEQUENCE` for durable stream positions.
3. **Stream kinds:** `user`, `space`, `thread`, `worker_inbox`, `assignment`. Each event goes to **exactly one** durable stream. Fanning one event out to several streams is not allowed, to avoid lock contention on hot counter rows.
4. **Delivery classes:**

   | Class | Persisted | Behavior |
   | --- | --- | --- |
   | Durable message | Yes | Replay and HTTP rebase |
   | Durable command | Yes, `agent_commands` | Addressed to one Worker inbox; idempotent acknowledgements |
   | Durable lifecycle | Yes, bounded retention | Replay; never overrides execution state |
   | Ephemeral | No | Coalesced or dropped under backpressure |

5. **Worker command inbox.** `agent_commands(command_id, worker_instance_id, assignment_id, attempt_id, type, payload_ref, status, created_at, expires_at)`. A command row exists **before** any wakeup is sent. Notifications carry only IDs.
6. **Cursor semantics.** A client acknowledgement means the event was *applied* (or covered by an authoritative rebase). Send-side positions are named `lastEnqueuedSequence` and never count as acknowledgements. Per-connection cursors are not saved to the database on every event.
7. **Delivery guarantee:** at-least-once delivery, deduplicated by `event_id` and by idempotent domain transitions. We do not claim exactly-once.
8. **Outbox dispatcher:** claims rows with `FOR UPDATE SKIP LOCKED`, retries, and runs a periodic gap sweep. On a single server it wakes the local gateway directly. ADR-039 adds wakeups between servers without changing this contract.
9. **Bounded queues.** Each socket queue has a limit in both bytes and items. Bun `send()`/`drain` backpressure is honored. On overflow the client gets `sync.required`.

## Consequences

- Fixes the current issue where a cursor advances on send.
- Multi-server work (ADR-039) becomes wiring, not a redesign.
- Migration: widen the `stream_kind` CHECK, add `outbox` and `agent_commands`, and add an index on `(stream_kind, stream_id, sequence)`.

## Non-goals

Cross-server notification (ADR-039) and the wire envelope shape (ADR-038).

## Implementation notes (P2)

- Migration `0027_durable_events_outbox.sql`; stream and delivery rules in `docs/specifications/EVENT_STREAMS.md`.
- The committing process delivers inline from its outbox row; `OutboxDispatcher` is the safety net (claim with `SKIP LOCKED`, backoff, sweep). Fresh rows carry a 10 s grace so the inline path wins.
- The wire name of `sync.required` was `reconnect.required` until ADR-038; it is now `sync.required` everywhere.
- `agent_commands.worker_instance_id` is nullable until Agents address Workers by Instance (P3).
