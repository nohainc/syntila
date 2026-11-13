# VPS backend migration plan (Cloudflare Workers/D1 → Bun + PostgreSQL)

Status: **active** · Owner: Vitalii · Implementer: Claude · Updated 2026-11-13

Syntila is not in production, so this plan drops backward compatibility: the
database starts from a fresh schema, old migrations are deleted, and APIs may
change where that improves the design or performance. Cloudflare keeps human
authentication, token issuance and static web hosting; everything else moves
to the VPS.

## 1. Reassessment of phases 1–5

| Phase | Result | Keep | Change / retire |
| --- | --- | --- | --- |
| 1 Hardening | UFW, SSH keys only, auto updates, local-only PostgreSQL | all | — |
| 2 Bun + systemd | `/opt/syntila/releases`, systemd credentials, health | all | — |
| 3 Core backend (`apps/backend`) | `/v1` API, realtime gateway, event log, idempotency, tests, smoke/load scripts | server bootstrap, config, migrations runner, auth verifier, Bun pub/sub gateway mechanics, seq-log + ack + idempotency patterns, ops scripts | **Retire the `/v1` domain** (`store.ts`, `api.ts`, `0001_core.sql`) once the ported domain covers it — two domain models must not coexist. Its delivery guarantees move into the ported realtime/Workspace paths. |
| 4 Auth + networking | Caddy TLS, `api.syntila.app`, Cloudflare user token route, verified end to end | Caddy, DNS, user token route, key rotation | **Remove** the Cloudflare Workspace token route: Workspace runtime credentials move to PostgreSQL and authenticate directly against the VPS. The Dart `backend_client` is re-targeted to the ported API (keep token refresh, reconnect, seq cursor, outbox). |
| 5 Reliability | nightly dump, restore test, monitor, journald, swap, resilience tests (all passed) | all | Restore test and resilience test must be updated to the new schema/API (step 7.3). |

**Main gap found:** the VPS covered ~10 tables of ~110 and none of the
Cloudflare-specific runtime (3 Durable Objects, the `syntila-run` Workflow,
cron jobs, email, R2 bindings). Clients still use Cloudflare `/api/*`.

## 2. Target architecture and decisions

```
Browser / Flutter app ──HTTPS+WSS──► api.syntila.app (Caddy → Bun) ──► PostgreSQL
Workspace Service     ──HTTPS+WSS──►            "                  ──► R2 (S3 API)
        │ sign-in only
        ▼
Cloudflare Worker: Better Auth, desktop auth, backend token issuance, static app, email relay
```

| # | Decision | Reason |
| --- | --- | --- |
| D1 | **Port `apps/cloud` domain code to Bun** (into `apps/backend`), not a rewrite. | 46k lines of tested behaviour; 167 test files / 1,568 tests become the parity gate. |
| D2 | **Fresh PostgreSQL schema**: one `0001_initial.sql` generated from the final D1 schema, cleaned (no `__migration_*`, legacy or dead columns), PostgreSQL types: `timestamptz`, `boolean`, `jsonb`, `bigint` identities where useful, proper FKs and indexes. All 114 D1 migrations are deleted from the backend path. | No production data; better types and indexes. |
| D3 | **D1-compatible PostgreSQL adapter** (`prepare/bind/first/all/run/batch`, `?N`→`$N`, `batch` = one transaction, timestamps returned as ISO strings) so handlers port mechanically; SQLite-only SQL (75 sites) rewritten. Hot paths later move to direct `Bun.SQL`. | Fast, low-risk port; performance work where it matters. |
| D4 | **Durable Objects → in-process services**: Workspace gateway, realtime gateway and thread coordinator run in the Bun process; single-writer guarantees use PostgreSQL row locks / advisory locks and fencing counters. | Removes DO RPC hops and per-DO cost; ready for multi-node via a bus later. |
| D5 | **Cloudflare Workflow `syntila-run` → PostgreSQL durable workflow runner**: instances, memoised step results, `waitForEvent`, `sleep`, retries; claimed with `FOR UPDATE SKIP LOCKED`. | Same semantics, no vendor runtime. |
| D6 | **Cron → in-process scheduler** guarded by advisory locks (5-min recovery sweeps, daily pruning). | |
| D7 | **R2 via `Bun.S3Client`** with a key scoped to the needed buckets; **email** via a small authenticated Cloudflare relay route (keeps `send_email`). | No new vendors. |
| D8 | **Identity**: Cloudflare keeps Better Auth + desktop sessions in D1 (auth tables only). The VPS provisions users from signed tokens; profile data (avatar, privacy, plan) lives in PostgreSQL. | Cloudflare = authentication only. |
| D9 | **Workspace Services authenticate to the VPS** with their runtime credential (hash in PostgreSQL); registration uses the human token. | One hop fewer, no D1 dependency. |
| D10 | **Keep `/api/*` paths and payloads** unless a change brings a clear win; clients switch base URL + bearer token. The realtime and Workspace runtime protocols keep their shapes but gain seq/ack/idempotency where missing. | Minimal Flutter/Dart churn. |

## 3. Phases

Each phase ends with a gate. Validation follows AGENTS.md (focused tests →
component validation); no phase is "done" on self-review alone.

### Phase 6 — Foundation (port infrastructure)
**Status: ✅ done (2026-11-13).**
- 6.1 inventory → `VPS_PORT_INVENTORY.md` (151 handlers, 91 tables, 50 triggers, 91 SQLite-only SQL sites).
- 6.2 schema → `apps/backend/migrations/0001_initial.sql` (91 tables, 85 indexes, 50 PL/pgSQL triggers, official Worker catalog seed). The Phase 3 `0001_core.sql` is deleted; `deploy-backend.sh` resets the prototype schema once.
- 6.3 `src/platform/pg-d1.ts` adapter + tests.
- 6.4 tests: the Cloudflare suite is copied to `apps/backend/test/domain` and runs on **bun test** against real PostgreSQL (`helpers/pg-d1.ts`: a fresh database per call cloned from a template in ~50 ms; `helpers/pg-sync.ts`: synchronous fixture access through a worker; `helpers/vitest-compat.ts`: the `vi` API on bun:test). D1-migration tests and Cloudflare-auth tests were removed from the backend suite (they stay in `apps/cloud`).
  **Baseline: 495 of 1,017 tests pass on PostgreSQL** — the rest is Phase 7 work (SQLite SQL, ad-hoc test schemas, bindings).
- 6.5 platform: `background.ts` (`waitUntil`), `r2.ts` (R2 over `Bun.S3Client`), `email.ts` (HMAC-signed relay), `cloudflare-workers.ts` (Workflow types), `unavailable.ts` (explicit errors for not-yet-ported bindings).
- 6.6 domain code copied to `apps/backend/src/domain` (`apps/cloud` stays intact until Phase 8). `server.ts` serves `/api/*`, health, background tasks, the cron schedule (advisory-locked), graceful drain. Auth: backend JWT only (`domain/auth/identity-service.ts`); token claims now carry `sid`, `client`, `client_aud`. User provisioning is cached (one write per user per 5 min). The Phase 3 `/v1` prototype is retired.
- Build: `pnpm --dir apps/backend build` → `dist/server.js` + `dist/migrate.js` (one bundle, no node_modules on the VPS). Deploy: `infra/vps/deploy-backend.sh`.
- Temporarily unavailable until 7.8: smoke, load and resilience scripts (they targeted `/v1`).

**Decision update (D4):** Durable Objects will run in-process under a small
host that implements the subset they use (`storage` get/put/delete/list on
PostgreSQL, alarms, hibernatable WebSockets via Bun upgrades) instead of being
rewritten — less code churn, same performance benefit.

**Gate:** server boots on the new schema; adapter tests pass; at least one
route group's tests pass on PostgreSQL.

### Phase 7 — Domain port, slice by slice
**Progress (2026-11-13): 944 of 1,033 ported tests pass on PostgreSQL** (Phase 6 baseline 495).
- SQL dialect: ~100 SQLite constructs rewritten; adapter quotes camelCase aliases, returns 1/0 for predicates, binds JSON text safely; schema helpers `syntila_json_set/remove/patch/path`.
- Durable Objects run in-process (`src/platform/durable-objects.ts`): storage and alarms in PostgreSQL, hibernatable WebSockets bridged to Bun upgrades, idle eviction.
- Cloudflare Workflows replaced by `src/platform/workflows.ts` (memoised steps, retries, buffered events, sleeps, leases); `runtime.ts` wires everything.
- End to end (`test/runtime.test.ts`): JWT REST, realtime WebSocket fan-out, Workspace registration with a desktop token and gateway WebSocket connect.
Remaining: ~89 tests, full Workflow → Workspace → result journey, browser realtime ticket, smoke/load/resilience scripts for `/api`.

Order follows dependencies; each slice = SQL dialect fixes + its tests green on PostgreSQL.
1. Identity & accounts: provisioning, `/api/session`, profile, avatar (R2), privacy, plan, account execution slots.
2. Spaces & people: spaces, memberships/permissions, direct spaces, support spaces, people/connections/invitations, workspace invitations, notes, pins, notifications, home read model, user files.
3. Threads & conversation: threads, discussion messages + attachments, reply references, read states, conversation history/turns/workflow runs/step runs, thread policy, request queue, thread history actions.
4. Execution: work creation/lifecycle, work requests/inputs/files, workflow engine (D5), scheduler, assignment dispatcher/delivery/liveness/revocation/start permits, execution phases, MCP tool dispatch, implement-plan.
5. Workspace runtime: registration/ownership/release, gateway (D4) incl. sessions, inventory, allowed folders, member access, grants, worker plugins, worker output images, input delivery, worker preferences.
6. Catalog & admin: worker catalog/profiles (V9), releases & release trust, profile lab policy, model discovery, issue reports (+R2 diagnostics), admin routes.
7. Realtime gateway (D4) with seq cursors and resync; cron jobs (D6); email relay (D7).
8. Retire Phase 3 `/v1` domain; update smoke, load, resilience and restore tests to the ported API/schema.
**Gate:** all ported test files pass on PostgreSQL; `bun test` + typecheck clean;
smoke test of the main user journeys against the VPS (sign in → Space → Thread →
Chat request → Workspace executes → answer streamed and persisted).

### Phase 8 — Cloudflare slimming
1. Reduce the Worker to: Better Auth, desktop auth intents/sessions, user token
   issuance, static web assets, email relay. Remove Workspace token route, DOs,
   Workflow, crons, R2 app bindings and app routes.
2. Fresh D1 schema with auth tables only (`migrations-auth/0001_initial.sql`).
3. CORS/same-site review: web app on `syntila.app`, API on `api.syntila.app`.
**Gate:** `pnpm validate:cloud` equivalent for the auth Worker green; sign-in
(web, desktop, Profile Lab audiences) works and issues backend tokens.

### Phase 9 — Clients
1. Flutter app: API base `https://api.syntila.app`, token provider (web cookie →
   `/api/backend-token`; desktop session → token), bearer on every call,
   realtime URL + ticket, 401 → refresh. Remove cookie-only assumptions.
2. Workspace Service: runtime credential auth against the VPS, gateway URL,
   reliable result delivery (persist result until ack), reconnect/backoff.
3. Profile Lab and CLI management paths that call Cloud.
4. Re-target or merge `packages/dart/backend_client`.
**Gate:** `pnpm validate:app`, `pnpm validate:workspace`, focused Dart tests;
end-to-end run on a real Mac Workspace with a real provider CLI.

### Phase 10 — Performance and load
1. Load scenarios (extend `scripts/loadtest.ts`): 1k/5k idle sockets; 500
   active users posting; 50 concurrent AI streams with token-rate progress;
   Workspace reconnect storms; slow consumers (backpressure).
2. Measure CPU, RSS, event-loop lag, PostgreSQL p50/p99, connection pool waits,
   fan-out latency; `pg_stat_statements` top queries → indexes / rewrites;
   move hot paths off the adapter to direct `Bun.SQL`.
3. Caddy `encode zstd gzip` for JSON; PostgreSQL tuning for the VPS size
   (`shared_buffers`, `work_mem`, `effective_cache_size`, autovacuum).
4. 24 h soak with synthetic traffic; resilience suite re-run.
**Gate:** documented targets met (initial: p99 API < 150 ms, p99 fan-out
< 250 ms at 2k sockets, no memory growth over 24 h, no lost/duplicated persistent
events).

### Phase 11 — Launch and cleanup
1. Pre-launch: alert channel + external uptime + Hetzner Backups confirmed;
   decision on off-site continuous backups (recommended: pgBackRest → R2).
2. Launch: deploy auth Worker + clients pointing at the VPS. No data migration
   (fresh start); existing accounts keep working because auth stays in D1.
3. Rollback: previous Worker + client builds remain deployable; D1 app data is
   preserved untouched (read-only) until cleanup.
4. Post-launch: structured error logging + alert on error rate, daily review
   for one week.
5. Cleanup after 2 stable weeks: delete `apps/cloud` app code and D1 app tables,
   old docs; update ARCHITECTURE.md / AGENTS.md (D1 rules → PostgreSQL rules).

## 4. Open decisions for Vitalii
- Off-site continuous backups before launch (Phase 11.1).
- Email: Cloudflare relay (default) vs a provider API.
- Performance targets in Phase 10 (defaults above).

## 5. Open operator items from Phase 5
Alert channel in `/etc/syntila/monitor.env` + `--test-alert`; external uptime
check; enable Hetzner Backups.
