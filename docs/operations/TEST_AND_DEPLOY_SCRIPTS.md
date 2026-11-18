# Test and production deploy scripts

All scripts live in `scripts/` and run from any directory on the Mac (they find the repo root themselves). They need `bun`, `node`/`pnpm`, `psql` and a local PostgreSQL (see below). The deploy scripts also need `ssh`/`rsync` access to the VPS, and `flutter` for the web app.

## Tests (`test-*.sh`)

| Command | Purpose |
| --- | --- |
| `scripts/test-all.sh` | Everything that gates a commit: typecheck, backend suite, `WRITE_PATHS.md` unchanged, concurrency tests x3, package `tsc`, root vitest. About 4 minutes. Ends with `ALL GREEN` or `FAILED`; exit code 1 on failure. |
| `scripts/test-all.sh --quick` | Typecheck and backend suite only (about 2 minutes). Used before deploys. |
| `scripts/test-backend.sh [filter...]` | Backend suite (one `bun test` process per file). With filters, only files whose path contains one, e.g. `scripts/test-backend.sh conversations api-structure`. |
| `scripts/test-concurrency.sh [rounds]` | Concurrency and transaction tests, repeated (default 3) to expose races. |

Environment:

- `TEST_JOBS`: files run in parallel (default 4).
- `TEST_LOG`: file that receives the output of failing files (backend suite).
- `TEST_VERBOSE=1`: also list passing files.
- `TEST_LOG_DIR`: where `test-all.sh` keeps one log per step (default `/tmp/syntila-tests`).
- `TEST_DATABASE_URL`: PostgreSQL role with CREATEDB (default `postgres://syntila_app:devpass@127.0.0.1:5432/postgres`). Every test file gets its own database cloned from a template built from `apps/backend/migrations`; leftovers are dropped at the end.

A file that fails under parallel load is re-run once alone; if it then passes it is reported as `flaky` and counted as passing. A flaky name that keeps appearing is a real race: investigate it.

## Local performance (`perf-*.sh`)

| Command | Purpose |
| --- | --- |
| `scripts/perf-local.sh` | Runs the local performance suite against `pnpm start:local` (`:8788`) and checks p95 latency limits in `scripts/perf-thresholds.json`. Exits 1 when a threshold is exceeded. |
| `scripts/perf-local.sh --no-thresholds --json out.json` | Prints latency numbers and writes the full JSON report (commit, date, CPU/OS info, and available timing percentiles) without failing on threshold limits. |
| `scripts/test-perf.sh` | Short perf run with history in `_perf/` and a comparison with the previous run. `scripts/test-all.sh --perf` adds it as the last step (opt-in). See [PERFORMANCE_TESTS.md](PERFORMANCE_TESTS.md). |

Options (`--probes N`, `--users N`, `--messages N`, `--chats N`, `--json out.json`, `--thresholds file.json`, `--no-thresholds`) control the three scenarios:

1. **Transport (`Scenario A`)**: Calls `POST /api/workspaces/:workspaceId/delivery-probe` on the developer account's live Workspace (`0`, `1024`, and `32768` payload bytes) and reports `p50`/`p95`/`p99`/`max` of `roundTripMs` and timeout counts (warns and skips if the Workspace is offline or unresponsive).
2. **Messages (`Scenario B`)**: Creates synthetic `perf-<runid>` users and Spaces with live realtime WebSockets, posts messages concurrently, and reports REST post latency, post-to-socket fan-out latency, and throughput.
3. **Workflows (`Scenario C`)**: Runs concurrent Chat requests and a single-Free-account serial queue run through an in-process `FakeWorkspace` (no AI), reporting request totals, Service receive-to-accept time, and estimated per-request overhead. Synthetic data from the current run is deleted on exit.

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
