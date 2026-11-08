# Local D1 history actor alignment

A database restored from a pre-rename checkout can have the conversation-history
actor constraint `('user', 'worker', 'conclave')`, even after all previously
available migrations have been recorded. New step-history triggers emit
`syntila`, causing work-request writes to fail with a CHECK constraint error.

Migration `0113_history_actor_alignment.sql` rebuilds the canonical history table,
converts only the legacy system actor to `syntila`, and reinstalls the canonical
history indexes and triggers, including step events. IDs, sequences, content,
metadata, timestamps, and deduplication keys remain intact. It also applies to
fresh databases already using `syntila`. No runtime compatibility API is added.

Before applying locally, stop the local Cloud development server and preserve a
backup of the D1 state. Run `./scripts/migrate-local-d1.sh`, then restart the server.
Do not copy SQLite state files over a running Cloud process. Do not reset the
database or replay the fresh-start baseline to resolve this error.

Verification: focused tests cover both actor schemas, data preservation, new
history writes, context-event trigger execution, legacy actor rejection,
append-only enforcement, integrity, and foreign keys. A rehearsal against a
SQLite backup of the affected local database preserved all 3,158 history rows
and passed full integrity and foreign-key checks. The live database was not
changed during that rehearsal.

## Reconcile Thread fences after a database restore

Restoring Cloud state can also move `threads.lease_fence_counter` behind the
Workspace's durable per-Thread fence. Execution then fails before provider
startup with `SpaceMutationViolation: stale or conflicting Space fencing token`.
This is a coordination-state failure, not a provider authentication failure.

Back up the database using SQLite's backup API. Match each local
`space-fences/<spaceId>/<threadId>.json` record against both Cloud identities.
Within a transaction, and only for Threads with no unreleased leases, raise the
Cloud counter to `MAX(current counter, recorded Workspace fencingToken)`. The
next lease will increment it. Never lower counters, delete local fences, clear
sessions, or bypass the fence check. Audit all restored Threads rather than
repairing only the first reported failure. The repair must not retry a failed
request automatically; the user can retry it after alignment. Verify database
integrity and foreign keys after committing.

## Same-owner session reference drift

A restored installation can pass fencing and then fail at `session_lookup` with
`session_resume_failed`. Compare attribution before resetting anything. A local
logical session reference may differ while its Conversation and Worker match.
The Engine reports that case separately, quarantines the old mapping, and starts
a new native session from canonical bootstrap context (or revision zero). It
never resumes the mismatched native session. Different Conversation or Worker
ownership remains a hard failure and is not eligible for this recovery.

For an already installed Engine, a fresh Implement retry or incrementing the
Thread's `work_session_generation` while it has no active requests/unreleased
leases isolates the new native session without deleting history or local
session records. Back up first. Do not change Conversation/Worker ownership or
manually relabel native session records. The Engine source recovery change
requires the next normal Engine build/install; rotating the Cloud session scope
takes effect without rebuilding the installed Engine.
