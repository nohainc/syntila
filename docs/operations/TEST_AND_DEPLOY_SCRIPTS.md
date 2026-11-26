# Test and production deploy scripts

All scripts live in `scripts/` and run from any directory on the Mac (they find the repo root themselves). They need `bun`, `node`/`pnpm`, `psql` and a local PostgreSQL (see below). The deploy scripts also need `ssh`/`rsync` access to the VPS, and `flutter` for the web app.

## Tests (`test-*.sh`)

| Command | Purpose |
| --- | --- |
| `scripts/test-all.sh` | Everything that gates a commit: typecheck, backend suite, `WRITE_PATHS.md` unchanged, concurrency tests x3, package `tsc`, root vitest. About 4 minutes. Ends with `ALL GREEN` or `FAILED`; exit code 1 on failure. |
| `scripts/test-all.sh --quick` | Typecheck and backend suite only (about 2 minutes). Used before deploys. |
| `scripts/test-all.sh --dart` / `--two-node` | Add every Dart/Flutter package check (`check-dart-packages.sh`) / the two-backend multi-server check. Both are opt-in. |
| `scripts/test-prod-scripts.sh` | The `prod-*.sh` scripts in `--dry-run` against stub tools; step order and stop-on-failure. |
| `scripts/test-backend.sh [filter...]` | Backend suite (one `bun test` process per file). With filters, only files whose path contains one, e.g. `scripts/test-backend.sh conversations api-structure`. |
| `scripts/test-two-node.sh [--strict]` | Two backend processes on one database (ADR-033 rules); `--strict` also fails the gaps known until ADR-038/039. |
| `scripts/test-scale.sh [idle active storm soak] [--sockets N ...]` | P11 scale scenarios against a running backend; exit 1 when the ADR-039 targets are missed. See [SCALING_DECISION.md](SCALING_DECISION.md). |
| `scripts/test-concurrency.sh [rounds]` | Concurrency and transaction tests, repeated (default 3) to expose races. |

The full run also checks `schema.lock` (against a scratch database), `docs/api/ROUTES.md`, the generated protocol bindings, and Syntila Connect (`apps/connect`: format, analyze, tests) when `dart` is installed.

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
| `scripts/start-local-backend.sh` | Local backend on `:8788` with local PostgreSQL. |
| `scripts/regenerate-schema-lock.sh [--check]` | Rebuilds `apps/backend/migrations/schema.lock` from the migrations in a scratch database (`--check` only compares; exit 1 when out of date). Uses the local credentials (`syntila_app` / `devpass`). Never leaves an empty lock file. |
| `scripts/cleanup-local-stale-execution.sh` | Clears orphaned leases, never-sent assignments and Agent commands, and stuck queued Work Requests in the local PostgreSQL database. Refuses non-local hosts. |

pnpm aliases include `db:schema-lock`, `db:schema-lock:check`, and `test:two-node`.

## Local performance (`perf-*.sh`)

| Command | Purpose |
| --- | --- |
| `scripts/perf-local.sh` | Runs the local performance suite against `pnpm start:local` (`:8788`) and checks p95 latency limits in `scripts/perf-thresholds.json`. Exits 1 when a threshold is exceeded. |
| `scripts/perf-local.sh --no-thresholds --json out.json` | Prints latency numbers and writes the full JSON report (commit, date, CPU/OS info, and available timing percentiles) without failing on threshold limits. |
| `scripts/test-perf.sh` | Short perf run with history in `_perf/` and comparison against configured limits. `scripts/test-all.sh --perf` adds it as the last step (opt-in). See [PERFORMANCE_TESTS.md](PERFORMANCE_TESTS.md). |

Options (`--chats N`, `--workflow chat|work`, `--json out.json`, `--thresholds file.json`, `--no-thresholds`) control the Workflow benchmark and reporting.

The retired transport probe is reported as skipped; `--probes` is accepted for
existing invocations but does not send probes. The Workflow
scenario sends real sequential Chat requests through a connected Worker and may
consume provider quota. It removes its temporary Space after completion and
preserves it if a request times out.

## Production deploys (`prod-*.sh`)

Common to every deploy script:

- Asks `Continue? [y/N]` before touching production. `--yes` skips the question; `--skip-tests` skips the pre-deploy tests.
- Refuses to deploy unless the branch is `main`, the tree is clean and `HEAD` equals `origin/main`; `--allow-dirty` overrides this for emergencies.
- `--dry-run` runs the local gates, builds and read-only checks and only prints the steps that change production (uploads, ssh deploys, D1 apply, secret sync, `wrangler deploy`). It never asks questions.
- Secrets come from the shell environment or the gitignored `~/.config/syntila/prod.env` (names in [Production provisioning](PRODUCTION_PROVISIONING.md#release-secrets)); a missing name stops the script before anything runs.
- Settings can be overridden with the environment: `PROD_VPS` (default `syntila@46.225.103.109`), `PROD_STAGE` (`phase3-stage`), `PROD_API_URL` (`https://api.syntila.app`), `PROD_APP_URL` (`https://syntila.app`).

| Command | What it does |
| --- | --- |
| `scripts/prod-deploy-backend.sh` | Quick tests, build (`apps/backend/scripts/build.sh`), rsync of `dist/`, `migrations/` and `infra/vps/` to `~/phase3-stage/` on the VPS, then `ssh -t ... sudo bash ~/phase3-stage/vps/deploy-backend.sh` (asks for the sudo password), then a public `/health/ready` check. |
| `scripts/prod-deploy-web-app.sh` | Secrets present → gates (cloud `types:check` and tests, `flutter analyze`, `flutter test`) → `flutter build web` (`SYNTILA_API_URL` default `/api`) → bundle secret check → `pnpm production:preflight` → `pnpm email:config-check` → auth D1 migrations (`scripts/migrate-production-d1.sh`: list, confirm, apply) → `scripts/sync-worker-secrets.sh` → `wrangler deploy` → public checks (`/health` 200, `/api/session` 401, page 200). A failing step stops the script before anything is deployed. |
| `scripts/prod-deploy-frontend.sh` | Public site (`apps/site`, Astro): `check`, `test`, `build`, `check:release`, then `wrangler deploy --config wrangler.production.jsonc`. |
| `scripts/prod-deploy-all.sh [--site]` | Backend, then web app (with D1 migrations); with `--site` also the public site. Flags are passed on. Stops at the first failure and says which parts are deployed. |
| `scripts/prod-status.sh` | Read-only: API, app and site status, applied and pending backend migrations, pending D1 migrations (needs `CLOUDFLARE_API_TOKEN`), current and previous releases on the VPS, `systemctl is-active` for the service and the monitor timer. |
| `scripts/prod-rollback-backend.sh [release]` | Lists `/opt/syntila/releases`, points `current` at the chosen release (default: the previous one), restarts and checks readiness. Does not undo migrations. |
| `scripts/prod-reset-db.sh --i-understand-this-deletes-all-data` | Deletes all production data and rebuilds an empty schema through the migrations (replaces restore; there are no backups). Asks you to type the API host name. Disabled by `APP_IS_LIVE=1` inside the script; remove it when the app goes live. |
| `scripts/test-prod-scripts.sh` | Runs every `prod-*.sh --dry-run` in a throwaway repo against stub `ssh`, `rsync`, `curl`, `pnpm`, `flutter`, `node`, `bun` and `wrangler`; asserts step order and that a failing gate stops the run. |
| `scripts/prod-migrate-db.sh status` | Read-only: the last applied migrations on production and the ones in this checkout that are not applied. |
| `scripts/prod-migrate-db.sh apply` | Builds, shows the pending migrations, asks, uploads and applies them without a release. |

### What the backend deploy does on the VPS

`infra/vps/deploy-backend.sh` (run as root):

1. Refuses PostgreSQL older than 16.
2. Lists the pending migrations.
3. Creates `/opt/syntila/releases/<timestamp>`, switches the `current` link, restarts `syntila-backend`. The service applies pending migrations in `ExecStartPre` before it starts.
4. Waits for `/health/ready`; if it never becomes ready, prints the logs and rolls back to the previous release.
5. Runs `migrate.js --verify` (live schema against `migrations/schema.lock`; drift is a warning), checks that an unauthenticated API call gives 401, and keeps the last 5 releases.

### Migrations: with the deploy or separately?

With the backend deploy, normally. Code and schema ship together, the code rollback is part of that deploy, and migrations are forward-only (expand/contract). Use `prod-migrate-db.sh` to look at the state (`status`) or to apply a schema change ahead of the code (`apply`), which is only safe for expand-style changes that the running release ignores. A migration cannot be undone by switching the code back; there are no backups, so fix a bad migration forward or reset the database.

### Typical sequences

- Backend change with a migration: `scripts/test-all.sh`, then `scripts/prod-migrate-db.sh status`, then `scripts/prod-deploy-backend.sh`.
- App or Worker change only: `scripts/prod-deploy-web-app.sh`.
- Everything: `scripts/prod-deploy-all.sh --site`.
- Something went wrong after a deploy: the backend rolls back by itself when it does not become ready; for a later problem run `scripts/prod-rollback-backend.sh`. Check state with `scripts/prod-status.sh`.

## Notes

- `scripts/test-prod-scripts.sh` and `bash -n` cover the scripts without production; `prod-status.sh` and `prod-migrate-db.sh status` are the read-only checks against production. Run the first real deploy while watching it.
- Related: `docs/deployment/VPS_BACKEND.md`, `docs/deployment/VPS_OPERATIONS.md`, `docs/deployment/CLOUDFLARE.md`.
