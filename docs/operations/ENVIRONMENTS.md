# Local and production environments

Syntila has two environments. They never share a database, Cloud URL, or Connect state.

| | Local | Production |
|---|---|---|
| Backend API | `apps/backend` on `http://localhost:3000` (or configured port) | `https://api.syntila.app` |
| Auth Edge | `wrangler dev` on `http://localhost:8787` (`apps/cloud/wrangler.jsonc`) | Worker `syntila-app` (`infra/cloudflare/app.wrangler.jsonc`) |
| Database | Local PostgreSQL | Production PostgreSQL |
| Web app | Flutter `run` on `http://localhost:3000` | `https://syntila.app` |
| Connect binary | `syntila-connect` (from `apps/connect`) | `syntila-connect` |
| Connect state (macOS) | `~/Library/Application Support/Syntila Local/Workers/<worker-id>/` | `~/Library/Application Support/Syntila/Workers/<worker-id>/` |

Each Worker has its own credential, session, journal, and lock under `<application data>/Syntila/Workers/<worker-id>/`, while folders and the device ID are shared by the computer. See [Connect CLI and services](../specifications/CONNECT_CLI_AND_SERVICES.md) for pairing and service management.

## Local stack

1. Run PostgreSQL migrations against the local database after pulling new migrations.
2. Start the backend (`apps/backend`) and web app (`apps/app`).
3. Pair and run Connect (`apps/connect`) against the local backend URL using `syntila-connect`.

`pnpm db:cleanup:local` clears stuck execution state from the local PostgreSQL database (stop the backend first).

## Production

- `pnpm app:run:prod` runs the web app locally against the **production** Cloud through `scripts/local-cloud-proxy.mjs`: live accounts and data.
- `pnpm deploy:api` deploys the Cloudflare Worker; build `apps/app/build/web` first. CI normally does this (`deploy-cloud.yml`).
- `pnpm tail:api` streams production Worker logs.
- Connect: install `syntila-connect`, pair Workers, and run the per-user login service (`launchd`, `systemd --user`, or Windows logon task).
