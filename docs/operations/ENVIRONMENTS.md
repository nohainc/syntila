# Local and production environments

Syntila has two environments. They never share a database, Cloud URL or Workspace state.

| | Local | Production |
|---|---|---|
| Cloud API | `wrangler dev` on `http://localhost:8787` (`apps/cloud/wrangler.jsonc`) | Worker `syntila-app` (`infra/cloudflare/app.wrangler.jsonc`) |
| Database | Local D1 `syntila-development` in `apps/cloud/.wrangler/state` | Remote D1 `syntila` |
| Web app | Flutter `run` on `http://localhost:3000` | `https://syntila.app` |
| Workspace binary | `syntila-local` (built with `--local`) | `syntila` |
| Workspace state (macOS) | `~/Library/Application Support/Syntila Local/Workspace/State` | `~/Library/Application Support/Syntila/Workspace/State` |

The Workspace environment is chosen at build time (`SYNTILA_WORKSPACE_ENVIRONMENT`). A local build uses the separate `Syntila Local` state folder and, when `workspace.nano` is created (`config init`, first run, or after `reset`), writes `cloud.url http://localhost:8787`. After that the service always connects to whatever `cloud.url` says, so check it with `syntila-local config show`. If the file was created by a different build, edit `cloud.url` or run `reset`.

## Local stack

1. Stop the local API, then run `pnpm db:migrate:local` once and after pulling new migrations. Migration 0093 updates legacy `conclave.*` desktop authentication audiences to `syntila.*` while retaining local accounts and desktop session records.
2. `pnpm start:local` opens two terminals: the API (local D1) and the web app.
3. Workspace, pick one:
   - `pnpm workspace:run:local` runs the service from Dart source.
   - `pnpm workspace:build:macos:local --install`, then `syntila-local service install|start`.
4. Talk to the local service: `syntila-local status`, or from source `pnpm workspace:cli:local status`.

`pnpm db:cleanup:local` clears stuck execution state from the local PostgreSQL database (stop the backend first).

## Production

- `pnpm app:run:prod` runs the web app locally against the **production** Cloud through `scripts/local-cloud-proxy.mjs`: live accounts and data.
- `pnpm deploy:api` deploys the Worker; build `apps/app/build/web` first. CI normally does this (`deploy-cloud.yml`).
- `CONFIRM_PRODUCTION_MIGRATION=YES pnpm db:migrate:production` applies remote D1 migrations.
- `pnpm tail:api` streams production Worker logs.
- Workspace: `pnpm workspace:build:macos:prod --install`, then `syntila service install|start`.
