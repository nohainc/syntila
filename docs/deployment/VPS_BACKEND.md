# VPS backend (Bun + PostgreSQL)

Status: **Phase 4 — public at `https://api.syntila.app`, running in parallel.** The
Cloudflare Workers/D1 service remains authoritative for production. Nothing in
`apps/cloud` was changed; clients are not yet pointed at this backend.

## Layout

| Path | Purpose |
| --- | --- |
| `apps/backend/src/server.ts` | Process bootstrap, graceful shutdown (closes sockets with 1012) |
| `apps/backend/src/app.ts` | HTTP routing, CORS, health, WebSocket upgrade, browser tickets |
| `apps/backend/src/api.ts` | REST API `/v1/*` |
| `apps/backend/src/store.ts` | All SQL and domain rules (permissions, idempotency, event log, tasks) |
| `apps/backend/src/realtime/gateway.ts` | WebSocket protocol, subscriptions, fan-out, task delivery |
| `apps/backend/src/auth.ts` | Access-token verification (public keys only) |
| `apps/backend/src/migrate.ts` + `migrations/*.sql` | Forward-only, checksummed migrations under an advisory lock |
| `apps/backend/scripts/` | `dev-keys`, `mint-token`, `smoke`, `loadtest` |
| `infra/vps/` | systemd unit, env template, `install-phase3.sh` |

No npm dependencies: Bun's built-in `Bun.SQL`, `Bun.serve` WebSockets and WebCrypto.

## Data model (migration `0001_core.sql`)

`users`, `spaces`, `space_memberships` (owner/collaborator/viewer), `threads`,
`messages`, `workspace_services`, `space_workspaces`, `ai_tasks`,
`thread_events`, `idempotency_receipts`. Text IDs are kept so D1 rows migrate
1:1 in Phase 6; new IDs are UUIDv7 (time-ordered, so message pagination uses
the primary key).

**Thread event log.** Every persistent change in a thread (message
created/edited/deleted, task status, thread updated) appends a row to
`thread_events` with a per-thread `seq`. `threads.last_seq` is incremented
under the thread row lock in the same transaction, so the sequence is gap-free
and totally ordered. Clients resynchronise with "events since seq N". Events
are published to sockets only after commit.

**Persistent vs transient.** User messages, AI requests, final AI answers and
critical task statuses (`queued → dispatched → running → completed|failed|cancelled`)
are stored. Token streams and intermediate progress (`task.progress`) are
forwarded to thread subscribers only and dropped if none are connected.

## Reliability

- **Client → server:** messages carry a `clientMessageId`; retries return the
  original (`duplicate: true`), reuse with different content is `409`.
  Other REST creates accept an `Idempotency-Key` header (receipts kept 48 h).
- **Server → client:** every event has `seq`; on reconnect a client
  subscribes with `since = lastSeq` and receives the missed events. Slow
  consumers are disconnected at a 4 MB backlog and resync instead of growing
  server memory.
- **Server → Workspace Service:** tasks are stored before dispatch. A
  connecting workspace receives all open tasks; unacknowledged tasks are
  re-sent every 30 s. Workspaces de-duplicate by `task.id`.
- **Workspace → server:** the final result carries a workspace-generated
  `resultId`; it is stored exactly once, retries are acknowledged as
  duplicates, a different result for a finished task is rejected. Workspaces
  retry until they receive `ack` (WebSocket) or `200` (HTTP fallback).

Protocol details: [VPS_REALTIME_PROTOCOL.md](VPS_REALTIME_PROTOCOL.md).
Backups, monitoring and recovery runbooks: [VPS_OPERATIONS.md](VPS_OPERATIONS.md).

## Authentication

The backend only **verifies** tokens; it never holds a signing key in
production. Tokens are compact JWS (`EdDSA`/Ed25519 or `ES256`, `kid`
required, ≤ 24 h lifetime) with `iss`, `aud=syntila-backend`, `sub`, `iat`,
`exp` and `typ`:

- `typ: "user"` + `email`, `name` — the user row is provisioned/updated from
  the token on first use.
- `typ: "workspace"` + `owner` (user id) — the Workspace Service row is
  provisioned on first use; a revoked workspace is rejected.

Public keys (JWK array or JWKS, supports rotation by `kid`) live in
`/etc/syntila/auth-public-keys` and are passed as a systemd credential.
Cloudflare issues them (`apps/cloud/src/backend-token.ts`) with issuer
`https://syntila.app`, signed by the `SYNTILA_BACKEND_SIGNING_KEY` Worker secret:

- `POST https://syntila.app/api/backend-token` — web cookie or desktop
  `Bearer syntila_dhs_…` session → user token, 15 min.
- `POST https://syntila.app/api/workspace-runtime/backend-token`
  `{workspaceRuntimeId}` + runtime credential → workspace token
  (`sub` = execution workspace id), 60 min.

Both return `{token, expiresAt, expiresIn, backendUrl}`. Suspended users and
revoked workspaces/runtimes get no token; existing tokens die within their
TTL. The Dart client in `packages/dart/backend_client` refreshes tokens,
handles reconnect/resync and the reliable outbox.

Browsers cannot set headers on a WebSocket upgrade, so they call
`POST /v1/realtime/tickets` and connect to `/v1/realtime?ticket=…`
(single-use, 30 s). Native clients and Workspace Services send
`Authorization: Bearer`.

## REST API (v1)

```
GET    /v1/me                         PATCH /v1/me
GET    /v1/spaces                     POST  /v1/spaces            (Idempotency-Key)
GET    /v1/spaces/:id                 PATCH /v1/spaces/:id        (owner; archived:true|false)
GET    /v1/spaces/:id/members         POST  /v1/spaces/:id/members  {userId|email, role}
DELETE /v1/spaces/:id/members/:userId (owner, or self-leave; last owner protected)
GET    /v1/spaces/:id/threads         POST  /v1/spaces/:id/threads  (collaborator)
GET    /v1/threads/:id                PATCH /v1/threads/:id
GET    /v1/threads/:id/events?since=&limit=
GET    /v1/threads/:id/messages?before=&limit=
POST   /v1/threads/:id/messages       {clientMessageId, body, references?, attachments?, replyTo?}
PATCH  /v1/messages/:id               DELETE /v1/messages/:id
POST   /v1/threads/:id/ai-requests    {clientMessageId, body, workspaceId, worker?, options?}
POST   /v1/tasks/:id/cancel
GET    /v1/workspaces                 PUT|DELETE /v1/spaces/:id/workspaces/:workspaceId
POST   /v1/realtime/tickets
# Workspace Service HTTP fallback (workspace token):
GET    /v1/workspace/tasks
POST   /v1/workspace/tasks/:id/ack | /status {status:"running"} | /result {resultId, status, body?, error?}
```

Errors: `{"error": {"code", "message"}}`. Non-members get `404` for spaces and
threads (existence is not revealed).

## Deploying

From the repository root on your Mac:

```sh
rsync -a --delete --exclude node_modules apps/backend/ syntila@46.225.103.109:phase3-stage/backend/
rsync -a --delete infra/vps/ syntila@46.225.103.109:phase3-stage/vps/
ssh -t syntila@46.225.103.109 'sudo bash ~/phase3-stage/vps/install-phase3.sh'
```

The installer makes `syntila_app` the database/schema owner (required to run
migrations), installs a timestamped release under `/opt/syntila/releases/`,
switches `/opt/syntila/current`, installs the unit (migrations run in
`ExecStartPre`), waits for `/health/ready`, rolls back the symlink if the
service does not become ready, and runs `scripts/smoke.ts`.

`/health/ready` is `200` only when PostgreSQL answers, no migration is
pending and auth keys are configured. Bun binds to `127.0.0.1:3000` only;
Caddy terminates TLS (automatic Let's Encrypt, HTTP/1.1, 2 and 3) for
`api.syntila.app` and proxies HTTPS and WebSockets (`infra/vps/Caddyfile`).

## Phase 4 runbook (public endpoint)

1. Cloudflare DNS for `syntila.app`: add `A api → <VPS IPv4>` with proxy
   status **DNS only** (grey cloud). Optionally `AAAA` with the VPS IPv6.
2. On the Mac, repo root: `node apps/backend/scripts/generate-signing-key.mjs`
   (private key → `.development/`, public → `infra/vps/auth-public-keys.json`).
3. `pnpm exec wrangler secret put SYNTILA_BACKEND_SIGNING_KEY --config infra/cloudflare/app.wrangler.jsonc < .development/backend-signing-key.private.jwk`,
   then deploy the Worker as usual (`pnpm deploy:api`).
4. rsync `apps/backend/` and `infra/vps/` to the VPS and run
   `sudo bash ~/phase3-stage/vps/install-phase4.sh`. It checks DNS, deploys
   the latest release, installs the production public key, deletes the dev
   key, sets `AUTH_JWT_ISSUER=https://syntila.app` and
   `ALLOWED_ORIGINS=https://syntila.app`, installs Caddy, and checks
   `https://api.syntila.app`.

Key rotation: `generate-signing-key.mjs --rotate` appends a second public
key; deploy the VPS first, then update the Worker secret, then remove the
old public key after an hour.

Operations:

```sh
sudo systemctl status syntila-backend
sudo journalctl -u syntila-backend -f
ls -l /opt/syntila/current                          # active release
sudo ln -sfn /opt/syntila/releases/<previous> /opt/syntila/current && sudo systemctl restart syntila-backend   # rollback
```

Migrations are forward-only; a rollback across a schema change needs a
compatible schema (keep migrations additive).

## Local development

```sh
cd apps/backend
createdb syntila_test                                  # owned by a role you can log in as
TEST_DATABASE_URL=postgres://user:pass@127.0.0.1/syntila_test bun test
```

## Scaling notes (deliberately not built yet)

One process, one PostgreSQL. Fan-out uses Bun's in-process pub/sub topics
(`thread:<id>`, `space:<id>`, `workspace:<id>`), browser tickets and the
per-user cache are in memory. To run several nodes: replace `Gateway.fanout`
with a cross-node bus (PostgreSQL `LISTEN/NOTIFY` or Redis), move tickets to
PostgreSQL, and put the nodes behind a load balancer. The seq-based event log
already tolerates duplicate and out-of-order delivery, so no protocol change is
required. A local smoke run held 2,000 subscribed sockets with p99 fan-out of
~35 ms; real capacity is measured in Phase 6 (`scripts/loadtest.ts`).

## Not yet done

Switching the Flutter app and Workspace Service data paths to the VPS (the Dart client exists; wiring waits for feature parity), port of the full Cloudflare feature set (workflows, worker profiles, people,
notes, pins, read receipts, notifications, attachments upload — files stay in
R2), backups/monitoring, D1 data
migration and cutover.
