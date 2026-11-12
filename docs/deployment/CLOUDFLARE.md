# Syntila Cloudflare Deployment

Current product and runtime boundaries are documented in [Architecture v8](../architecture/ARCHITECTURE_V8.md).
Operational guidance for signed Workspace and Tool Profile releases is in [Workspace release operations](WORKSPACE_RELEASES.md) and
[Release Trust and Rotation](../security/RELEASE_TRUST_AND_ROTATION.md).

## Domain plan

- `conclaveax.com` — public Astro/static-first website.
- `www.conclaveax.com` — permanent redirect to `conclaveax.com`.
- `syntila.app` — Syntila / Syntila Cloud web application.
- `syntila.app/api` — same-origin Cloud API.
- `docs.conclaveax.com` — documentation later.
- `status.conclaveax.com` — status page later.

The public site is deployed independently from the authenticated application.
Its production Worker owns only `conclaveax.com` and `www.conclaveax.com`.
It does not handle `/api/*`, `syntila.app`, Workspace Gateway traffic, or
Better Auth callbacks. PR previews use a separate temporary Workers name with
no production custom-domain routes; merging to `main` deploys the production
site through `.github/workflows/deploy-site.yml`.

The public site's production config provisions HTTPS custom domains for the
apex and `www` hostnames. The site Worker returns a permanent 308 redirect
from `www` to the apex, Astro emits trailing-slash routes, serves a static
`404.html`, revalidates HTML, and marks fingerprinted `/_astro/` assets as
immutable for one year. These rules apply only to the public-site Worker.

## Current deployment

`syntila.app` is the Syntila/Cloud application. It runs the real
application; there is no demo-mode runtime branch. Production Syntila is a
public login application whose human sessions are handled by Better Auth.
Cloudflare Access is optional for staging, administrative, debug, and other
internal environments; it is not an application authentication dependency.

The deployment builds Flutter Web with the planned same-origin API endpoint:

```
flutter build web --release --dart-define=SYNTILA_API_URL=https://syntila.app/api
```

Syntila uses its normal connection-error state when the API is unavailable. This
is intentional: development should expose integration gaps rather than hide
them behind fake runtime data.

The static application is deployed with Cloudflare Workers Static Assets. SPA fallback is enabled so Flutter web routes resolve to `index.html`.

## GitHub setup

### Better Auth providers

Configure the OAuth applications with these callback URLs:

- `https://syntila.app/api/auth/callback/github`
- `https://syntila.app/api/auth/callback/google`

The GitHub application must allow the `user:email` scope. Syntila requests
only identity scopes for sign-in; signing in with GitHub does not grant GitHub
repository access. Repository authorization is a separate future integration.

Set these values in the Worker environment:

- `BETTER_AUTH_URL` — application origin, such as `https://syntila.app`;
- `SYNTILA_APP_URL` — browser application origin used for desktop Workspace
  approval pages, such as `https://syntila.app`. Set this separately
  when the Cloud API and browser application use different origins or local
  development ports.
- `SYNTILA_AUTH_GITHUB_CLIENT_ID` — GitHub OAuth client ID;
- `SYNTILA_AUTH_GITHUB_CLIENT_SECRET` — GitHub OAuth client secret;
- `SYNTILA_AUTH_GOOGLE_CLIENT_ID` — Google OAuth client ID;
- `SYNTILA_AUTH_GOOGLE_CLIENT_SECRET` — Google OAuth client secret;
- `BETTER_AUTH_SECRET` — Better Auth encryption/signing secret;
- `BETTER_AUTH_TRUSTED_ORIGINS` — optional comma-separated additional Syntila
  origins for local or controlled preview environments.

The production Worker also uses Cloudflare Email Service for email verification,
password reset, and Space invitations. Sender configuration is centralized in
the Cloud email service and uses these production variables:

- `SYNTILA_EMAIL_FROM=syntila@conclaveax.com`
- `SYNTILA_EMAIL_FALLBACK_FROM=vitalii@conclaveax.com`
- `SYNTILA_EMAIL_FROM_NAME=Syntila`

Both addresses must be independently authorized by the Cloudflare Email
Sending configuration on the `conclaveax.com` zone before deploying this change.
The fallback is used only when the provider explicitly rejects the primary
sender before accepting the message. Timeouts, recipient failures, and unknown
errors are not retried with another sender, which avoids duplicate messages
after an uncertain provider acceptance. The retired `auth@auth.earthuc.com`
address is rejected by the configuration validator. Local development uses
`remote: true` on the `SYNTILA_EMAIL` binding so real emails are delivered via
Cloudflare Email Sending when logged into Wrangler (and falls back to logging
when the binding is absent).

For local overrides, copy `apps/cloud/.dev.vars.example` to `apps/cloud/.dev.vars` and use
non-deliverable `*.test` addresses. The development Wrangler configuration keeps
the email binding for local simulation/remote sending but does not hardcode production sender
variables. The production deployment workflows validate configuration and binding shape;
they do not send a test message or prove Cloudflare sender authorization.

The shared delivery service reports accepted delivery separately from sender
authorization, recipient rejection, rate limiting, provider availability,
temporary failure, and configuration errors. Account registration uses a 2-step
pre-signup verification code (`POST /api/auth/sign-up/send-code` followed by
`POST /api/auth/sign-up/email` with `otp`) so the user's email address is
verified before the account and session are created. Invitation creation
preserves its boolean delivery result.

The automated coverage and the controlled production sender smoke test are
documented in the [email delivery verification runbook](EMAIL_DELIVERY_VERIFICATION.md).

### GitHub sign-in

GitHub sign-in uses Better Auth's GitHub provider. It is active only when both
`SYNTILA_AUTH_GITHUB_CLIENT_ID` and `SYNTILA_AUTH_GITHUB_CLIENT_SECRET` are
set; without them the "Continue with GitHub" button returns to the sign-in page
with "Sign-in with this provider is not set up on this server yet."

1. Open **GitHub → Settings → Developer settings → OAuth Apps → New OAuth
   App**. Use a separate app for local development and production, because a
   GitHub OAuth App accepts a single callback URL.

   | Environment | Homepage URL | Authorization callback URL |
   | --- | --- | --- |
   | Production | `https://syntila.app` | `https://syntila.app/api/auth/callback/github` |
   | Local (isolated mode) | `http://localhost:3000` | `http://localhost:8787/api/auth/callback/github` |

   The callback URL is the Cloud API origin (`BETTER_AUTH_URL`), not the
   Flutter app origin. Syntila requests only the `user:email` scope; leave
   device flow off.
2. Generate a client secret and copy the client ID and secret.
3. Production: add them as the GitHub Actions secrets
   `SYNTILA_AUTH_GITHUB_CLIENT_ID` and `SYNTILA_AUTH_GITHUB_CLIENT_SECRET`
   and run the deployment workflow, or set them on the Worker directly with
   `pnpm exec wrangler secret put SYNTILA_AUTH_GITHUB_CLIENT_ID --config
   infra/cloudflare/app.wrangler.jsonc` (and the same for the secret).
4. Local: add both values to `apps/cloud/.dev.vars` and start
   `./scripts/start-local.sh --isolated`. The default local mode proxies to the
   production gateway, so a GitHub sign-in there completes on the production
   origin and does not sign in the local app.

Behavior:

- A new GitHub account creates a Syntila user from its verified primary email,
  name and avatar. Anyone with a GitHub account may sign in; membership in
  Spaces still requires an invitation. An account without a verified email
  cannot sign in.
- Implicit account linking is disabled. If a Syntila account already exists for
  the same email, GitHub sign-in returns to the sign-in page with an "account
  already exists" message. Sign in the usual way and use **Link GitHub** in the
  profile security settings; later GitHub sign-ins then work.
- Return targets and failures behave as described for Google sign-in below.

### Google sign-in

Google sign-in uses Better Auth's Google provider. It is active only when both
`SYNTILA_AUTH_GOOGLE_CLIENT_ID` and `SYNTILA_AUTH_GOOGLE_CLIENT_SECRET` are
set; without them the "Continue with Google" button returns to the sign-in page
with "Sign-in with this provider is not set up on this server yet."

1. In Google Cloud Console open **APIs & Services → OAuth consent screen**.
   Choose **External** so any Google account can sign in, fill in the app name,
   support email and authorized domain, and request only the `openid`, `email`
   and `profile` scopes (non-sensitive; no Google verification is required).
   Set the publishing status to **In production**. In **Testing** status only
   listed test users can sign in and grants expire after seven days.
2. Open **Credentials → Create credentials → OAuth client ID**, type **Web
   application**. Use a separate client for local development and production.

   | Environment | Authorized JavaScript origin | Authorized redirect URI |
   | --- | --- | --- |
   | Production | `https://syntila.app` | `https://syntila.app/api/auth/callback/google` |
   | Local (isolated mode) | `http://localhost:8787` | `http://localhost:8787/api/auth/callback/google` |

   The redirect URI is the Cloud API origin (`BETTER_AUTH_URL`), not the Flutter
   app origin.
3. Production: add the client ID and secret as the GitHub Actions secrets
   `SYNTILA_AUTH_GOOGLE_CLIENT_ID` and `SYNTILA_AUTH_GOOGLE_CLIENT_SECRET`
   and run the deployment workflow, or set them on the Worker directly with
   `pnpm exec wrangler secret put SYNTILA_AUTH_GOOGLE_CLIENT_ID --config
   infra/cloudflare/app.wrangler.jsonc` (and the same for the secret).
4. Local: add both values to `apps/cloud/.dev.vars` and start
   `./scripts/start-local.sh --isolated`. The default local mode proxies to the
   production gateway, so a Google sign-in there completes on the production
   origin and does not sign in the local app.

Behavior:

- A new Google account creates a Syntila user from its verified email, name and
  picture. Anyone with a Google account may sign in; membership in Spaces still
  requires an invitation.
- Implicit account linking is disabled. If a Syntila account already exists for
  the same email (for example email and password), Google sign-in returns to the
  sign-in page with an "account already exists" message. Sign in the usual way
  and use **Link Google** in the profile security settings; later Google
  sign-ins then work.
- After sign-in the browser returns to the application page that started it.
  Cloud accepts only its own origin and `SYNTILA_APP_URL` as a return target.
  Provider failures return to `/login?error=<code>` on the application origin.

Store `SYNTILA_AUTH_GITHUB_CLIENT_SECRET`,
`SYNTILA_AUTH_GOOGLE_CLIENT_SECRET`, and
`BETTER_AUTH_SECRET` only with Cloudflare Worker secrets (for example,
`wrangler secret put`). Do not commit values to source, Wrangler configuration,
CI files, or browser bundles. These are ultimately secrets on the
`syntila-app` Worker. The production deployment workflow accepts the same
names as GitHub Actions secrets and copies them to the Worker before
deployment. Client IDs may be ordinary environment configuration, but should
still be managed per deployment.

V9 Profile publication does not require a Profile signing key or Profile trust
root. Cloud revalidates the candidate JSON, canonical digest, evidence, and
expected revision, then publishes the current Profile atomically. The
`SYNTILA_RELEASE_PUBLISHER` and `SYNTILA_RELEASE_TRUST_KEYS_JSON` settings
remain only for Workspace application-release verification.

Profile Lab requires the active browser account `vitalii@nohainc.com`.
Both Wrangler configurations set `SYNTILA_PROFILE_LAB_OWNER_EMAIL`; this exclusive
owner policy replaces the legacy user-ID allowlists for this deployment. Browser
approval, session claim, and subsequent Lab requests enforce the policy.
All environments support Profile publication and rollout; there is no release
mode switch. The access endpoint reports effective permissions. macOS Developer
ID signing does not gate the internal lifecycle.

Profile Lab builds default to `https://syntila.app`. Development builds
can select local Cloud with
`--dart-define=SYNTILA_CLOUD_URL=http://localhost:8787`; the Cloud connection
settings also allow a local origin override and can reset to the build default.
The app accepts HTTP only for loopback addresses in development builds. Release
builds require HTTPS. Saved Profile Lab sessions are bound to the selected
origin, so switching Cloud targets requires signing in again.

Better Auth uses database-backed HttpOnly sessions in `auth_sessions`. The
production policy is a 14-day session with daily refresh, no session data
cookie cache, Secure/HttpOnly/SameSite=Lax cookies, and same-origin mutation
protection. Better Auth's standard session listing and revocation endpoints
remain available under `/api/auth/*`; Syntila never receives or stores the
session token.

Repository Settings -> Secrets and variables -> Actions:

- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_API_TOKEN`

Create a Cloudflare API token with only the permissions required to deploy Workers for this account/zone. Do not commit tokens.

Then run:

```
Actions -> Deploy Syntila App -> Run workflow
```

Before applying production D1 migrations or deploying Workers, the workflow
runs the v8 clean-schema and Work v1 regression acceptance tests. CI also runs
the v8 runtime and Work v1 end-to-end suites. Failures stop the production
deployment.

After applying production D1 migrations and before deploying
`syntila.app`, the workflow runs
`scripts/production-workspace-gateway-smoke.mjs --schema-only`. It compares the
stored `CREATE TABLE` definitions and columns for the Workspace and desktop
auth tables with the versioned migration contract. It explicitly requires
both supported audiences in both desktop auth constraints and reports a legacy
single-audience constraint with an instruction to apply pending migrations.
The workflow fails on any missing, unexpected, or drifted contract. This check
only reads schema metadata; it never repairs table definitions.

After deploying `syntila.app`, the same script runs as a production
acceptance gate. It creates one disposable AX browser session and exercises the
Workspace desktop-auth lifecycle: create an intent, approve it in the browser
session, claim it, and validate the resulting `syntila.desktop.management`
session. For Profile Lab, it creates an intent and requires browser approval to
reject the disposable non-owner identity. The rejected intent must remain
unapproved and unclaimable; Workspace credentials must also be rejected by Lab
administration. Positive owner authentication is covered by the Cloud acceptance
tests and requires the real owner account for a live browser check.
The smoke uses the Workspace session to register
a uniquely named Workspace, performs an HTTP/1.1 WebSocket upgrade, sends
`workspace.hello`, requires the matching `workspace.hello.ack`, requests
synchronization and requires a correlated `workspace.sync.result`, verifies the
persisted Gateway session, and deletes both desktop auth flows plus the
disposable Workspace and user rows in `finally` cleanup. No Profile release
operation is part of this smoke.

The GitHub Actions secret `BETTER_AUTH_SECRET` must match the
`syntila-app` Cloudflare Worker secret. The workflow uses it only to sign
the temporary browser approval cookie for the disposable auth identity; it
does not print the secret or cookie. The runtime credential and Profile Lab
session credential are generated for that run and are never written to workflow
logs or a URL. A failed schema check, auth request, audience check, registration,
Gateway exchange, or cleanup fails the deployment workflow. The smoke uses DML
only for disposable rows and does not change production table definitions.

That automated deployment acceptance does not replace the packaged desktop
lifecycle release run. Before publishing a Workspace release, execute
the production scenarios in the
[Workspace lifecycle release validation runbook](../operations/WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md)
(written for the earlier desktop app; apply the scenarios that still map to the
CLI and service, such as restart persistence and reauthentication). The runbook distinguishes automated CI evidence from
required production-device evidence.

The custom-domain route in `infra/cloudflare/app.wrangler.jsonc` targets `syntila.app`. Because `conclaveax.com` is already on Cloudflare, the Worker custom domain can create/manage the required DNS routing and certificate during deployment.

## Durable Objects & Database Migrations

### Durable Object migrations

Wrangler applies Durable Object migrations in sequence. Preserve every tag in
`infra/cloudflare/app.wrangler.jsonc` when deploying or re-provisioning; the
earlier tags are retained only because Cloudflare applies migration history
cumulatively. The active runtime binding is `WorkspaceGateway`.

### D1 Database Provisioning
New development databases use the clean v8 schema from
`apps/cloud/migrations-v8`. Apply every ordered migration when initializing
the local database:
```bash
pnpm exec wrangler d1 migrations apply syntila-development --local --config apps/cloud/wrangler.jsonc
```

Production now targets the separately provisioned `syntila`
database. It was initialized from the clean v8 baseline, then populated from a
private export of the existing production database. Aggregate row counts and
key parent-child relationships were checked after import. The old
`syntila-production` database remains intact as a rollback copy until the v8
Worker deployment and production checks pass. The v8 migration is a clean
baseline, not an in-place upgrade for a database initialized from an earlier
migration chain. Do not apply it to the old database.

`0001_syntila_v8.sql` has already been applied in production and is immutable.
Schema changes use new ordered forward migrations; the production deployment
workflow applies pending migrations before deploying the Worker. Migration
`0002_desktop_auth_multi_audience.sql` rebuilds the two desktop auth tables,
preserves existing rows and active sessions, validates before/after row counts,
and installs the multi-audience constraints. Never re-bootstrap production to
deliver a schema change. The complete lifecycle policy is in
[Persistence Contracts](../specifications/PERSISTENCE.md#d1-schema-lifecycle).
Migration `0003_workspace_installations.sql` adds stable installation
ownership, seeded from runtime identity history and release audit events. If
legacy history reused an installation ID across multiple Workspaces, it keeps
the same owner and selects the sole non-revoked Workspace; if every associated
Workspace is revoked, it selects the newest historical Workspace and retains
that owner. It fails closed on mixed owners, multiple non-revoked Workspaces,
live credentials attached to revoked Workspaces, or one Workspace mapped to
multiple installation IDs. Runtime credentials remain independently rotatable.
Migration `0004_workspace_runtime_identity_uniqueness.sql` adds the
database-enforced one-unrevoked-runtime-identity-per-Workspace invariant and
fails closed if existing rows violate it. The production schema smoke checks
the required unique partial indexes before proceeding.
Migration `0005_workspace_schema_alignment.sql` aligns the deployed
`execution_workspaces` and `workspace_runtime_identities` table definitions
and indexes with the v8 canonical contract while preserving all existing rows.

The `workspace-gateway-schema-regression.test.ts` test constructs a clean
SQLite database by applying the ordered SQL migrations in
`apps/cloud/migrations-v8`, checks critical runtime tables, and exercises the
production Gateway connection, heartbeat, and disconnect statements. The clean
schema must support every SQL statement used by current Cloud runtime code.

Chat requires the ordered `0006_chat_workflow_admission.sql` migration, which
preserves historical Work Requests, tasks, leases and linked records while
extending the Workflow and Step CHECK constraints. The populated migration test
runs with foreign keys enabled and verifies snapshots, indexes and triggers.
`0007_chat_profile_starter_attestation.sql` updates only an unchanged official
development template; published releases are immutable. Follow the
[production provisioning order](../operations/PRODUCTION_PROVISIONING.md).

The Workspace Gateway Durable Object is authoritative for live connection
state. Workspace online/offline fields and session history are persisted
projections: their writes are queued and logged on failure, but cannot reject
an authenticated connection or interrupt a heartbeat acknowledgement.
Assignment selection checks the owning Gateway's live socket and runtime ID;
it does not trust a stale database online flag. The Durable Object restores
hibernated sockets from its accepted WebSocket attachments before answering
status or dispatch requests.

Both Gateways are built so an idle connection costs no Durable Object duration.
The Realtime Gateway accepts App sockets with the WebSocket Hibernation API,
keeps each connection's identity in the socket attachment and its subscriptions
and stream cursors in Durable Object storage, and lets the runtime answer the
App's `{"type":"ping"}` by WebSocket auto-response. The Workspace Gateway does
the same for the Service's idle ping. Do not add `accept()`-style sockets,
standing timers, or per-ping work to either object: each one bills the object
for the whole time a tab or Service stays connected. Authorization is checked
on every publish and every client message, so a revoked user receives nothing
on a socket that is still open.

The app Worker runs durable realtime event cleanup hourly. Event records and
their idempotency keys are retained for 90 days, with up to 10,000 expired
records deleted per run; per-Workspace sequence cursors are retained
indefinitely. Durable events are notifications, so clients refresh current
state from Cloud read APIs after reconnect or a sequence gap. See the
[Persistence Contracts](../specifications/PERSISTENCE.md#durable-realtime-event-retention)
for the retention policy.

## Backend deployment gate

Public production deployment remains gated by the
[current v8 implementation plan](../roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md).

Before production backend deployment:

1. provision production D1/R2 resources; the deployment workflow applies the
   checked-in D1 migrations to `syntila`;
2. configure required application-release, callback, and other production secrets;
3. run Workspace lifecycle and Cloud runtime release validations;
4. run the external-user security gate, including tenant isolation and
   backup/restore verification;
5. enable API/CI ingress only after the release gates pass.

Cloud owns orchestration and persistence. Syntila Workspace maintains the
outbound runtime channel; the generic Engine invokes the provider CLI locally.

At that point the preferred topology is either:

- same origin: `syntila.app/api/*`, avoiding browser CORS complexity; or
- separated API: `syntila.app`, with explicit authenticated CORS and CSRF/session design.

The same-origin option should be preferred for the first production release unless there is a concrete reason to separate the API hostname.

The explicitly configured internal Lab owner uses its existing authenticated
browser sign-in without a separate email-verification gate. Other emails remain
denied, and no verification flags are rewritten. Profile publishing always requires
matching qualification and expected revision, regardless of desktop signing.

For an existing v8 development database missing `tool_profile_local_qualification_evidence`, run `node scripts/provision-profile-qualification-evidence.mjs` and apply `.development/provision-profile-qualification.sql` to the selected D1 database. This adopts the current baseline table, index, and immutable evidence triggers without resetting Drafts or releases. Fresh databases already include these objects.

Older development databases may retain the obsolete required
`workspace_space_grants.scope` column, causing current grant creation to fail.
The fresh v8 baseline intentionally has no grant scope or repository/path mapping
contract. Inspect the hosted schema and dependencies, export the grant table to a
protected local backup, then run `node scripts/align-workspace-grant-schema.mjs`
and apply `.development/align-workspace-grant-schema.sql` once if `scope` exists
and has no external dependencies. This removes only that obsolete column;
grant IDs, status, permissions, assignments, indexes, and triggers remain.
Fresh baseline databases need no alignment. Do not replay the baseline or revive
revoked grants to fix this error.

An older **empty** `worker_assignments` table may still require `worker_id`
instead of v8 `worker_type_id`, breaking both dispatch and Work history reads.
Export its schema with `wrangler d1 export --table worker_assignments --no-data`,
verify the table is empty and no index or trigger depends on obsolete columns,
then run `node scripts/align-worker-assignment-schema.mjs` and apply the generated
`.development/align-worker-assignment-schema.sql` once. It adds the current
required logical Worker catalog reference and removes `worker_id`, `account_id`,
`checkout_id`, and `execution_lease_id`. It preserves the table identity, inbound
references, and unrelated indexes. Do not use this empty-table repair on populated
tables or rewrite failed Work Requests; operators can retry their failed Step.
Fresh v8 baseline databases require no repair or compatibility migration.

If an older hosted `realtime_events` table lacks `workspace_runtime_id`, live
event publication fails before WebSocket delivery. Run
`node scripts/align-realtime-event-schema.mjs` and apply the generated SQL once
after confirming the column is missing. This adds the current nullable field
and preserves all events and indexes; new baseline databases already include it.
Workspace HTTP delivery persists queued messages before reporting dispatch
success. Unacknowledged assignments fail after 30 seconds; acknowledged provider
execution retains its Step deadline.

## Durable realtime stream alignment

The [1.1 synchronization contract](../specifications/REALTIME_SYNCHRONIZATION.md)
separates collaboration sequencing from execution Workspace ownership. Fresh v8
baseline databases include the stream columns and indexes.

For an existing database with Workspace-only realtime tables, export/back up the
`realtime_events` and `realtime_event_cursors` tables first. Confirm that
`workspace_runtime_id` exists (apply the preceding nullable-field alignment if
needed) and that `stream_kind` does not yet exist. Run
`node scripts/align-realtime-stream-schema.mjs` to produce
`.development/align-realtime-stream-schema.sql`. Inspect it against the hosted
schema and apply its ordered statements as one transactional D1 batch during a
publication maintenance window, before deploying the new publisher. Do not
reapply it to an already aligned database.

The alignment copies all existing events/counters into execution Workspace
streams and rebuilds the current indexes. It preserves payloads, runtime IDs,
idempotency keys and sequence counters, including counters ahead of retained
rows. Verify row counts and counters against the backup before deploying Cloud
and AX. Restore the backup if alignment fails; do not reset execution sequences.
The repository's fresh-start baseline remains the canonical schema rather than
an upgrade migration chain. No deployment or hosted-schema changes happen when
running the SQL generator.

## Space/Thread API cutover and authentication

After the Space/Thread D1 cutover, deploy the matching Cloud API immediately.
An older API still queries retired Project/Workstream tables during session
resolution, so sign-in can succeed while `/api/session` reports that the
authentication service is unavailable. Local development uses the production
API proxy by default and is affected by the same deployment mismatch.

Before publishing, run the production schema smoke gate. SQL comments are not
schema differences and must not prevent the matching API from deploying.
Production Durable Object migration history retains the applied
`v8-workstream-coordinator` creation. The subsequent
`v9-thread-coordinator-rename` migration renames that existing namespace to
`ThreadExecutionCoordinator`; do not rewrite applied history or create a new
coordinator namespace. The isolated local configuration remains a fresh start.

## Syntila domain cutover (2026-10-28)

The app Worker is `syntila-app`, with a Cloudflare-managed custom domain at
`syntila.app`. Its `SYNTILA_DB` binding points to the fresh `syntila` D1
database (`6130c425-59e2-4ec7-b7bd-d3fe8a8ea6a7`), and its artifact bucket is
`syntila-artifacts-production`. The public site retains `conclaveax.com` and
`www.conclaveax.com`; its app links use `https://syntila.app`.

No previous users, sessions, or Workspace registrations were migrated. Recreate
accounts and reconnect desktop clients to the new origin. Local application
paths, marker filenames, token prefixes and auth audiences now use Syntila.
The former database and app deployment remain intact. Existing email sender
addresses on `conclaveax.com` remain configured. OAuth providers need credentials
and callbacks registered for the new origin before they can be enabled.

## OAuth restoration after the Syntila domain cutover

Production Google and GitHub OAuth callbacks are registered at
`https://syntila.app/api/auth/callback/google` and
`https://syntila.app/api/auth/callback/github`. The Google browser origin and
GitHub homepage are `https://syntila.app`. Existing provider client IDs and
secrets were retained.

Run the manual `Sync production OAuth` GitHub Actions workflow to restore only
the four OAuth settings on `syntila-app`. It leaves `BETTER_AUTH_SECRET` intact,
so restoring OAuth does not invalidate existing sessions or encrypted tokens.
The normal deploy and OAuth sync prefer the `SYNTILA_AUTH_*` repository secrets
and fall back to the existing `CONCLAVE_AUTH_*` names until those repository
secrets are renamed. Worker bindings always use `SYNTILA_AUTH_*`. Secret values
are never printed; the temporary file is private and removed after the job.

The restoration run on 2026-10-28 succeeded. Both live sign-in initiation routes
returned HTTP 302 to the correct provider with a Syntila callback and an OAuth
state cookie. Final provider consent and authenticated account linking still
need to be completed by the account owner. Explicit linking permits different provider email addresses while implicit
account linking remains disabled. The user must already be signed in to
Syntila and complete the provider authorization. Linking leaves the Syntila
account email unchanged and cannot claim a provider account belonging to
another Syntila user. No database
migration or application session-secret rotation was required.

### Linking accounts with different emails

On 2026-10-28, `allowDifferentEmails` was enabled for explicit Google/GitHub
linking. A signed-in Syntila account may link a GitHub identity whose email
differs from its Google or Syntila email. `disableImplicitLinking` remains true;
a normal social sign-in does not merge accounts. No schema migration, email
change, or session rotation is involved.

The focused auth suite (26 tests), production deployment dry run, documentation
links and live production health checks passed. The broader Cloud suite still
reported three timeouts in assignment race tests; all 74 tests in the four
relevant race-test files passed on a sequential rerun. The auth
configuration regression asserts both different-email support and disabled
implicit linking. Final GitHub authorization must be completed by the user.
