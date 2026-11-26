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

## Where each tool runs

Everything is built, tested and deployed from the dev machine (the Mac). GitHub builds Windows Connect only.

| Tool | Used for |
| --- | --- |
| `bun` | backend, tests, backend build |
| `pnpm` / `node` | Cloud (auth edge) tests, TypeScript packages, `wrangler` |
| `flutter` | web app (`apps/app`), desktop apps |
| `dart` | Connect (`apps/connect`), Worker Engine |
| `wrangler` | auth Worker, D1 migrations, public site |
| `ssh` / `rsync` | backend deploy to the VPS |
| GitHub Actions | Windows Connect build and release only ([GITHUB_ACTIONS.md](GITHUB_ACTIONS.md)) |

## Production

- Release with the `scripts/prod-*.sh` scripts ([TEST_AND_DEPLOY_SCRIPTS.md](TEST_AND_DEPLOY_SCRIPTS.md)); check state with `scripts/prod-status.sh`.
- `pnpm app:run:prod` runs the web app locally against the **production** Cloud through `scripts/local-cloud-proxy.mjs`: live accounts and data.
- `pnpm tail:api` streams production Worker logs.
- Connect: install `syntila-connect`, pair Workers, and run the per-user login service (`launchd`, `systemd --user`, or Windows logon task).
