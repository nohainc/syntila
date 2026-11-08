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
