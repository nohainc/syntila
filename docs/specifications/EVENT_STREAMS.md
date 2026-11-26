# Durable event streams, outbox and command inbox

[ADR-033](../decisions/ADR-033-durable-events-outbox-and-command-inbox.md) defines the durability rules. Human clients and Worker Agents use [unified messaging](../decisions/ADR-038-unified-realtime-transport.md); their credentials and stream permissions remain separate.

## Commit before delivery

A domain mutation, its per-stream sequence, durable `realtime_events` row and `outbox` row commit in one PostgreSQL transaction. A rollback consumes no committed sequence. Delivery happens after commit and is at least once: the outbox dispatcher claims pending rows, retries failed delivery and recovers work left by a failed process. Consumers deduplicate events and apply state transitions idempotently. A WebSocket is a delivery optimization, not the source of truth.

## Stream identity and replay

Each event belongs to one `(stream_kind, stream_id)`: `user`, `space`, `thread`, `worker_inbox` or `assignment`. Separate event rows are used when distinct audiences need separate streams. Authorization is checked for subscriptions and reads. Clients advance their applied cursor only after applying an event; on a gap or expired replay window they refresh the affected authoritative state. Durable events are retained for seven days; ephemeral messages are not retained. See [Persistence](PERSISTENCE.md#durable-realtime-event-retention).

## Worker command inbox

An `agent_commands` row for a Worker assignment is durable before a wakeup is sent. The current Worker session fence is checked at the relevant writes. Connect journals an assignment before acknowledging it and does not start a second Engine for the same attempt. See [ADR-034](../decisions/ADR-034-connect-pairing-and-session-fencing.md) for recovery and fencing.

## Backpressure and recovery

Connections have bounded queues. A client that cannot consume durable events is told to synchronize rather than receiving an unbounded backlog. Clients must recover from the authoritative APIs when replay is unavailable. One server is the current deployment; cross-node realtime fan-out remains a reported gap in `scripts/test-two-node.sh` and scaling is gated by [ADR-039](../decisions/ADR-039-horizontal-scaling.md).

## Invariants

`apps/backend/scripts/check-invariants.sql` checks the event, outbox, command and cursor relationships. The two-node check exercises shared-database writes and recovery of committed outbox work after a node is killed. It does not establish cross-node realtime delivery when it reports that gap.
