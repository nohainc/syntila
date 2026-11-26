# Backend migrations

Forward-only SQL files applied by `src/migrate.ts` before every backend start
(`ExecStartPre` in `infra/vps/syntila-backend.service`), under an advisory
lock, each in its own transaction, with a checksum per applied file.

## Rules

1. **Never edit an applied migration.** Add a new file. The runner refuses to
   start if an applied file's checksum changed.
2. **Name files `NNNN_snake_case.sql`**, next free number. Any other `.sql`
   file in this folder is an error.
3. **The previous release must keep working on the new schema.** A deploy
   that fails its health check switches the code back, not the schema. So
   change the schema in steps across releases:
   - *expand*: add the new column, table or index (nullable or with a default);
   - *migrate*: ship code that writes both and reads the new shape; backfill;
   - *contract*: in a later release, drop the old column or constraint.

   Never, in one release: rename a column or table, drop something the
   previous release reads or writes, or add `NOT NULL` without a default.
4. **Large tables: build indexes without blocking writes.** Start the file
   with `-- migrate:no-transaction` and use
   `CREATE INDEX CONCURRENTLY IF NOT EXISTS ...`. Such a file runs statement
   by statement, so every statement must be safe to run twice, and it may not
   contain function bodies. An invalid index left by an interrupted build is
   dropped automatically before the retry.
5. **Locks.** Each statement waits at most 10 s for a lock
   (`MIGRATION_LOCK_TIMEOUT`) and may run at most 30 min
   (`MIGRATION_STATEMENT_TIMEOUT`). A migration that times out waiting for a
   lock fails the deploy and the previous release keeps serving; retry at a
   quieter moment rather than raising the timeout.
6. **Update `schema.lock` in the same commit** (below). The test suite fails
   if it is stale.
7. **New foreign keys need an index** that starts with the referencing
   columns; a test enforces this.

8. **Choosing a type for a JSON document.**
   - `jsonb` for attribute bags that are queried or filtered by content and
     whose key order does not matter (metadata, audit details, errors).
   - `text` with `CHECK (col IS JSON)` for documents whose key order or exact
     text matters: snapshots that code walks in order, signed or hashed
     documents, stored responses. **jsonb sorts object keys**, so such a
     document would change silently. Name the column `*_json`; a test fails
     if a text `*_json` column has no check.
   - Through the D1 adapter both arrive as JSON text and are written as JSON
     text; the adapter parses text bound to a jsonb parameter.

## schema.lock

`schema.lock` lists every column, index, constraint, trigger and function
that the migrations produce, one per line. It makes a migration's effect
visible in review and lets production be checked for drift.

Regenerate it against an empty database with all migrations applied:

```sh
createdb syntila_lock && PGDATABASE=syntila_lock bun run migrate \
  && PGDATABASE=syntila_lock bun run schema:lock && dropdb syntila_lock
```

## Writes that run in parallel

The backend runs without a global writer lock (project doc
`claude/concurrency-plan.md`). Rules that keep parallel writes correct:

- **Every invariant is a constraint.** If two rows must never coexist, add a
  unique (or partial unique) index; a race then fails loudly instead of
  leaving bad data. Add the matching check to `scripts/check-invariants.sql`.
- **Number children from a counter on the parent row**, never with
  `MAX(...) + 1`. Conversation history uses
  `syntila_next_history_sequence(conversation_id)`; any new history trigger
  must call it.
- **Positions in a Thread's request queue** are taken only through
  `src/domain/routes/queue-positions.ts` (a per-Thread lock, then SQL).
- **A write whose condition counts or sums other rows** (plan limits,
  quotas) takes a lock on what it counts first, in the same transaction:
  `tx.lock(scope, id)` or `lockStatement(db, scope, id)` as the first
  statement of a batch (`src/platform/tx-env.ts`). Existing scopes:
  `syntila.space_members`, `syntila.spaces_of`, `syntila.execution_slots`,
  `syntila.storage`, `syntila.spaces_of`, `syntila.pins`, `syntila.user`,
  `syntila.queue`.
- Prove a new write path with a scenario in `test/concurrency.test.ts`, run
  it many times, and check it fails without the lock it relies on.

## Commands

| Command | What it does |
| --- | --- |
| `bun run migrate` | Apply pending migrations |
| `bun run migrate:status` | List pending migrations (exit code 3 if any) |
| `bun run schema:verify` | Compare the connected database with `schema.lock` (exit code 4 on drift) |
| `bun run schema:lock` | Print the connected database's schema into `schema.lock` |

## Deploy behaviour

`infra/vps/deploy-backend.sh` takes a verified `pg_dump` before any release
that carries pending migrations and refuses to continue if the dump fails. It
prints the restore command. After the release is healthy it runs
`migrate --verify` and warns on drift.
