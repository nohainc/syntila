# ADR-033: Durable Events, Transactional Outbox and Worker Command Inbox

- **Status:** Proposed
- **Date:** 2026-11-19
- **Split from:** ADR-031 (D7 durability rules, D8, invariants 6–8)
- **Order:** 2 of 8. Depends on ADR-032.
- **Related:** `REALTIME_SYNCHRONIZATION.md`, `COMMAND_DELIVERY_AND_REVOCATION_V9.md`, `EXECUTION_LIFECYCLE_V9.md`

## Context

Durable events exist today (`realtime_events`, `realtime_event_cursors`), but streams are tied to Workspaces (`stream_kind` CHECK allows only `execution_workspace`, `space` and `user`). Delivery assumes a single-process Durable Object host, and cursors can advance when a frame is sent rather than when the client applies it. Every later ADR needs one durability model that is correct on one server and **safe to run on several servers** later, without a redesign.

## Decision

1. **Commit first, notify second.** The domain change, the stream sequence, the event row and the outbox row are written in **one transaction**. Socket delivery is only an optimization.
2. **Per-stream sequence.** Each event takes the next number with `UPDATE realtime_event_cursors … RETURNING` inside the same transaction. Numbers have no gaps within a stream. We don't use a PostgreSQL `SEQUENCE` for durable stream positions.
3. **Stream kinds:** `user`, `space`, `thread`, `worker_inbox`, `assignment` (plus legacy `execution_workspace` until it is retired). Each event goes to **exactly one** durable stream. Fanning one event out to several streams is not allowed, to avoid lock contention on hot counter rows.
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
- The wire name of `sync.required` stays `reconnect.required` until ADR-038 (the app depends on it).
- `agent_commands.worker_instance_id` is nullable until Agents address Workers by Instance (P3).
