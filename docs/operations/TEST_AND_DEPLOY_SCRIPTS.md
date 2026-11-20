# Test and production deploy scripts

All scripts live in `scripts/` and run from any directory on the Mac (they find the repo root themselves). They need `bun`, `node`/`pnpm`, `psql` and a local PostgreSQL (see below). The deploy scripts also need `ssh`/`rsync` access to the VPS, and `flutter` for the web app.

## Tests (`test-*.sh`)

| Command | Purpose |
| --- | --- |
| `scripts/test-all.sh` | Everything that gates a commit: typecheck, backend suite, `WRITE_PATHS.md` unchanged, concurrency tests x3, package `tsc`, root vitest. About 4 minutes. Ends with `ALL GREEN` or `FAILED`; exit code 1 on failure. |
| `scripts/test-all.sh --quick` | Typecheck and backend suite only (about 2 minutes). Used before deploys. |
| `scripts/test-all.sh --dart` / `--two-node` | Add every Dart/Flutter package check (`check-dart-packages.sh`) / the two-backend multi-server check. Both are opt-in. |

The full run also checks `schema.lock` (against a scratch database), `docs/api/ROUTES.md`, the generated protocol bindings, and the Worker Agent (`apps/worker_agent`) when `dart` is installed.
| `scripts/test-backend.sh [filter...]` | Backend suite (one `bun test` process per file). With filters, only files whose path contains one, e.g. `scripts/test-backend.sh conversations api-structure`. |
| `scripts/test-worker-agent.sh [dart test args...]` | Worker Agent: `dart pub get`, format check, `dart analyze`, `dart test`. |
| `scripts/test-two-node.sh [--strict]` | Two backend processes on one database (ADR-033 rules); `--strict` also fails the gaps known until ADR-038/039. |
| `scripts/test-concurrency.sh [rounds]` | Concurrency and transaction tests, repeated (default 3) to expose races. |

Environment:

- `TEST_JOBS`: files run in parallel (default 4).
- `TEST_LOG`: file that receives the output of failing files (backend suite).
- `TEST_VERBOSE=1`: also list passing files.
- `TEST_LOG_DIR`: where `test-all.sh` keeps one log per step (default `/tmp/syntila-tests`).
- `TEST_DATABASE_URL`: PostgreSQL role with CREATEDB (default `postgres://syntila_app:devpass@127.0.0.1:5432/postgres`). Every test file gets its own database cloned from a template built from `apps/backend/migrations`; leftovers are dropped at the end.

A file that fails under parallel load is re-run once alone; if it then passes it is reported as `flaky` and counted as passing. A flaky name that keeps appearing is a real race: investigate it.

## Local development (Worker-first)

| Command | Purpose |
| --- | --- |
| `scripts/start-local-backend.sh` | Local backend on `:8788` with local PostgreSQL. `SYNTILA_FEATURE_FLAGS` defaults to every Worker-first flag except `cluster_mode`; set it to an empty string for all flags off, or to your own list. |
| `scripts/regenerate-schema-lock.sh [--check]` | Rebuilds `apps/backend/migrations/schema.lock` from the migrations in a scratch database (`--check` only compares; exit 1 when out of date). Uses the local credentials (`syntila_app` / `devpass`). Never leaves an empty lock file. |
| `scripts/run-worker-agent.sh <command>` | Runs the Worker Agent CLI from source with its data in `.development/worker-agent` (`install --pairing-code CODE --no-service`, `run`, `status`, `permissions add-folder PATH --write`, ...). |
| `scripts/cleanup-local-stale-execution.sh` | Clears orphaned leases, never-sent assignments and Agent commands, and stuck queued Work Requests in the local PostgreSQL database. Refuses non-local hosts. |

pnpm aliases: `db:schema-lock`, `db:schema-lock:check`, `worker-agent:run`, `worker-agent:test`, `test:all`, `test:two-node`.

## Local performance (`perf-*.sh`)

| Command | Purpose |
| --- | --- |
| `scripts/perf-local.sh` | Runs the local performance suite against `pnpm start:local` (`:8788`) and checks p95 latency limits in `scripts/perf-thresholds.json`. Exits 1 when a threshold is exceeded. |
| `scripts/perf-local.sh --no-thresholds --json out.json` | Prints latency numbers and writes the full JSON report (commit, date, CPU/OS info, and available timing percentiles) without failing on threshold limits. |
| `scripts/test-perf.sh` | Short perf run with history in `_perf/` and comparison against configured limits. `scripts/test-all.sh --perf` adds it as the last step (opt-in). See [PERFORMANCE_TESTS.md](PERFORMANCE_TESTS.md). |

Options (`--probes N`, `--chats N`, `--workflow chat|work`, `--json out.json`, `--thresholds file.json`, `--no-thresholds`) control the three scenarios:

1. **Transport (`Scenario A`)**: Calls `POST /api/workspaces/:workspaceId/delivery-probe` on the developer account's live Workspace (`0`, `1024`, and `32768` payload bytes) and reports `p50`/`p95`/`p99`/`max` of `roundTripMs` and timeout counts (warns and skips if the Workspace is offline or unresponsive).
2. **Workflows (`Scenario C`)**: Sends real sequential Chat requests through the developer account's connected Workspace and ready Worker, reporting completion and persisted startup intervals. This invokes a provider and may consume quota. The temporary Space is removed after completion and preserved if a request times out.

## Production deploys (`prod-*.sh`)

Common to every deploy script:

- Asks `Continue? [y/N]` before touching production. `--yes` skips the question; `--skip-tests` skips the pre-deploy tests.
- Prints the commit and warns when the working tree has uncommitted changes (the build still includes them).
- Settings can be overridden with the environment: `PROD_VPS` (default `syntila@46.225.103.109`), `PROD_STAGE` (`phase3-stage`), `PROD_API_URL` (`https://api.syntila.app`), `PROD_APP_URL` (`https://syntila.app`).

| Command | What it does |
| --- | --- |
| `scripts/prod-deploy-backend.sh` | Quick tests, build (`apps/backend/scripts/build.sh`), rsync of `dist/`, `migrations/` and `infra/vps/` to `~/phase3-stage/` on the VPS, then `ssh -t ... sudo bash ~/phase3-stage/vps/deploy-backend.sh` (asks for the sudo password), then a public `/health/ready` check. |
| `scripts/prod-deploy-web-app.sh` | Builds Flutter web (`apps/app`, `SYNTILA_API_URL` default `/api`) and runs `scripts/deploy-api.sh`: deploys the auth Worker and web app (`syntila-app`) and checks `syntila.app/health` and `api.syntila.app/health/ready`. |
| `scripts/prod-deploy-frontend.sh` | Public site (`apps/site`, Astro): `check`, `test`, `build`, `check:release`, then `wrangler deploy --config wrangler.production.jsonc`. |
| `scripts/prod-deploy-all.sh [--site]` | Backend, then web app; with `--site` also the public site. Flags are passed on to each script. |
| `scripts/prod-migrate-db.sh status` | Read-only: the last applied migrations on production and the ones in this checkout that are not applied. |
| `scripts/prod-migrate-db.sh apply` | Builds, shows the pending migrations, asks, uploads, takes a dump (`syntila-dump.sh`) and applies them without a release. |

### What the backend deploy does on the VPS

`infra/vps/deploy-backend.sh` (run as root):

1. Refuses PostgreSQL older than 16.
2. If migrations are pending: takes a verified dump first (`/var/backups/syntila`) and stops if the dump fails.
3. Creates `/opt/syntila/releases/<timestamp>`, switches the `current` link, restarts `syntila-backend`. The service applies pending migrations in `ExecStartPre` before it starts.
4. Waits for `/health/ready`; if it never becomes ready, prints the logs and rolls back to the previous release.
5. Runs `migrate.js --verify` (live schema against `migrations/schema.lock`; drift is a warning), checks that an unauthenticated API call gives 401, and keeps the last 5 releases.

### Migrations: with the deploy or separately?

With the backend deploy, normally. Code and schema ship together, the dump and the rollback are part of that deploy, and migrations are forward-only (expand/contract). Use `prod-migrate-db.sh` to look at the state (`status`) or to apply a schema change ahead of the code (`apply`), which is only safe for expand-style changes that the running release ignores. A migration cannot be undone by switching the code back; the restore command is printed by the deploy (`pg_restore --clean --if-exists -d syntila <dump>`).

### Typical sequences

- Backend change with a migration: `scripts/test-all.sh`, then `scripts/prod-migrate-db.sh status`, then `scripts/prod-deploy-backend.sh`.
- App or Worker change only: `scripts/prod-deploy-web-app.sh`.
- Everything: `scripts/prod-deploy-all.sh --site`.
- Something went wrong after a deploy: the backend rolls back by itself when it does not become ready; for a later problem, point `/opt/syntila/current` at a previous release in `/opt/syntila/releases` and restart `syntila-backend`.

## Notes

- The scripts have only been syntax-checked (`bash -n`), not run against production. Start with `scripts/prod-migrate-db.sh status` (read-only) and run the first real deploy while watching it.
- Related: `docs/deployment/VPS_BACKEND.md`, `docs/deployment/VPS_OPERATIONS.md`, `docs/deployment/CLOUDFLARE.md`.
