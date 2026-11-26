# Persistence Contracts

Cloud owns shared state in PostgreSQL. Backend route and domain modules own database access; the ordered, forward-only migrations and schema lock are in [backend migrations](../../apps/backend/migrations/README.md). Never edit an applied migration. Connect owns local credentials, journals, Profiles and sessions; Cloud does not store provider credentials or local paths.

## Conversation persistence

The canonical Thread timeline is stored in `discussion_messages`, including human messages, AI requests and AI answers. Work Requests and assignment records retain execution state and attribution. See [ADR-036](../decisions/ADR-036-canonical-thread-timeline-and-attribution.md) and [Conversation Continuity](CONVERSATION_CONTINUITY_V1.md).

## Schema lifecycle

Apply new migrations in order and verify the schema lock. Migration 0050 removes retired execution stream rows and old correlation columns; it preserves active streams. Backups and restore validation remain deployment responsibilities.

## Work state and files

Work Requests, runs, tasks, assignments, immutable execution snapshots and Thread leases are stored in PostgreSQL. A lease fences stateful work to its authorized Worker. Request files and handoffs use R2 references; local folder paths remain on the computer. See [ADR-037](../decisions/ADR-037-files-and-artifacts.md) and [ADR-044](../decisions/ADR-044-device-folders-and-space-folders.md).

## Durable realtime event retention

Durable event rows are retained for seven days. Cleanup removes up to 10,000 expired rows per run in batches; stream cursors remain separate. Clients whose cursor is older than retained history must resynchronize. See [Event Streams](EVENT_STREAMS.md) and `apps/backend/src/domain/realtime-retention.ts`.

## Human mutation receipts

`mutation_receipts` records client idempotency keys, request hashes and responses. Route-level claims prevent concurrent duplicate requests; a reused key with a different body is rejected. Some handlers commit their receipts with the underlying mutation. See [Mutation idempotency](MUTATION_IDEMPOTENCY.md).
