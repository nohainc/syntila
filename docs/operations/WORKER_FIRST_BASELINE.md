# Worker-first P0: baseline metrics and backup exercise

- **Status:** tooling in place; **measurements and the restore exercise are not recorded yet** (see "To record" below). Date: 2026-11-19.
- **Why:** later phases (P2 outbox, P9 unified transport, P11 load test) must be compared with numbers taken before they change anything.

## 1. Baseline measurements

### How to take them

On the machine that runs the backend (local stack or a staging copy, never production traffic):

```bash
# backend with rate limits off, as for scripts/load.ts
SYNTILA_RATE_LIMIT_PER_MINUTE=0 SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE=0 pnpm start:local

# in apps/backend, with the signing key the backend trusts
bun scripts/baseline.ts http://127.0.0.1:8788 <privateJwkFile> \
  --sockets=200 --idle-seconds=300 --messages=20 --users=10 --pid=<backend pid>
```

Output: `_perf/baseline-<timestamp>.json` (not committed) with

| Figure | Meaning |
| --- | --- |
| `idleSockets.openAtStart`, `unexpectedCloses`, `reconnects` | How many of the requested browser realtime sockets opened and how many dropped or reconnected during the idle period. A stable system shows 0 and 0. |
| `idleSockets.timeToReadyMs` | Time for the sockets to subscribe (p50/p95/p99). |
| `messages.restPostMs`, `messages.realtimeFanoutMs` | REST post latency and post-to-event latency with the idle sockets still open. |
| `messages.throughputPerSecond`, `messages.errors` | Throughput and failed posts. |
| `memory.startMb`, `withSocketsMb`, `afterMessagesMb` | Backend RSS in MB (needs `--pid`). |

Use an idle period of at least 300 s for the recorded run (the default of 30 s is a smoke check). Commit `99517215` fixed idle WebSocket Workspaces going offline, so idle behavior is worth watching.

Record each accepted run in the table below with the git commit, machine and the command line. Worker-side idle connections (Workspace Service sockets) are not covered by this script; the existing `scripts/perf-local.ts` Scenario A measures one live Workspace.

### Earlier numbers (not a P0 baseline)

From `claude/vps-migration-status.md`, Phase 10, local sandbox, 2026-11-13, before the later SQL refactor: messages 230 to 330 per second, REST p95 72 to 107 ms, 0 errors over 3 runs; one Chat request about 120 ms backend overhead. From `docs/operations/PERFORMANCE_RESULTS.md`, 2026-11-18: `messages.restPostMs` p95 4.6 to 10.8 ms, `messages.realtimeFanoutMs` p95 4.3 to 10.8 ms. These used other scenarios and machines; keep them for context only.

### To record

| Date | Commit | Machine | Sockets open / requested | Unexpected closes | REST post p95 (ms) | Fan-out p95 (ms) | RSS start / sockets / after (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| _pending_ | | | | | | | |

## 2. Backup and restore exercise

### What exists

- `infra/vps/phase5/syntila-dump.sh`: nightly `pg_dump` in custom format to `/var/backups/syntila`, archive checked with `pg_restore --list`, 7 days kept, plus a globals dump. Timer: `syntila-dump.timer` (01:15 UTC).
- `infra/vps/phase5/restore-test.sh`: restores the newest dump into a scratch database and checks it.
- `infra/vps/deploy-backend.sh`: takes a verified dump before applying migrations and stops if it fails.
- `apps/backend/scripts/rehearse.sh`: restores a dump into a local database, migrates, verifies the schema and runs the invariants.

`claude/vps-migration-status.md` records that paid backups were deferred until launch. The nightly dump tooling is in the repository; whether it is installed and running on the VPS has not been checked from here.

### Fixed in P0

`restore-test.sh` counted rows in `messages`, `ai_tasks` and `thread_events`, none of which exist in the current schema (`apps/backend/migrations/schema.lock`), so it could not pass. It now checks the current tables (`users`, `spaces`, `space_memberships`, `threads`, `conversation_history_entries`, `execution_workspaces`, `worker_assignments`), that conversation history is numbered 1..n, and runs `check-invariants.sql` on the restored copy when that file is installed (`install-phase5.sh` now installs it). Not yet run: the script needs the VPS or a PostgreSQL server with the `syntila` database.

### Exercise to run (P0 exit gate: "backups verified")

1. On the VPS: `sudo systemctl start syntila-dump.service`, then confirm a new `/var/backups/syntila/syntila-*.dump` and `globals-*.sql`.
2. `sudo bash /usr/local/lib/syntila/restore-test.sh`. Expect `RESTORE TEST PASSED`; note the restore duration.
3. Optional, off the VPS: copy the dump to a Mac and run `bash apps/backend/scripts/rehearse.sh <dump>`, which also applies pending migrations and runs the smoke test options.
4. Record below. Before P1 (first schema change) confirm the pre-migration dump in `deploy-backend.sh` still works.

| Date | Dump file and size | Restore seconds | Result | Who ran it |
| --- | --- | --- | --- | --- |
| _pending_ | | | | |

Gate: P0 is not closed until row 1 of this table says `RESTORE TEST PASSED` on a dump taken on the date recorded.
