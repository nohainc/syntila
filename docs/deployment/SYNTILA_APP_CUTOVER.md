# Syntila production cutover — 2026-10-28

The production application is deployed at https://syntila.app using Worker
`syntila-app`, version `3ca099b5-998e-4240-80b6-28cfc510e910`.
The public site remains at https://conclaveax.com, using `syntila-site`, version
`a4834def-8cac-4249-97bc-839dcafc78cc`; its app links now target Syntila.

The new D1 database is `syntila`, ID
`6130c425-59e2-4ec7-b7bd-d3fe8a8ea6a7`, in EEUR. All 90 migrations are applied;
there are zero user accounts and no foreign-key violations. No old production
rows were copied. Artifacts use `syntila-artifacts-production`. The former app,
database and artifact bucket remain intact.

Authentication audiences, token prefixes, local paths, markers, package root,
remaining filenames and deployment scripts use Syntila. Generated Dart protocol
bindings were refreshed. Existing real GitHub repository URLs and marketing,
email and download addresses on conclaveax.com remain valid. The future
syntila.com domain is not configured.

## Verification

- Production Worker dry run and both production deployments succeeded.
- HTTPS app index, `/health` and `/api/auth/get-session` returned HTTP 200.
  Health reported `production`; the unauthenticated session was null.
- Public DNS resolvers returned Cloudflare addresses for syntila.app. The
  machine's cached negative DNS result required `curl --resolve` for live
  checks immediately after provisioning; TLS certificate validation stayed on.
- The deployed D1 schema gate passed: 17 required tables, 14 critical table
  definitions and seven indexes. The gate now accounts for the existing
  parallel-slots migration; its 13 regression tests passed.
- App validation passed: formatting, analysis and 1,113 tests. Release Flutter
  web compilation passed.
- Site component validation passed: Astro diagnostics, build and four tests.
- Profile Lab component validation passed: analysis and 74 tests.
- Cloud validation initially passed 1,230 tests with six timeouts. All 53
  tests in the three affected files passed when rerun with one worker.
- Deployment/migration script tests passed (66 tests across 14 files).
- Connect validation found eight failures. After fixing macOS signing of
  copied Engine aliases, all 28 tests in the seven affected files passed.
  Connect service compiled, started headlessly and stopped cleanly.
- Branding, documentation links, protocol generation and production-security
  checks passed. Broader Engine validation still encounters process timeouts;
  real provider tests require separate opt-in credentials/environment.

This scope covers the renamed auth contracts, deployment configuration, fresh
schema and direct desktop consumers. It does not certify a newly signed desktop
installer release or real provider execution.

## Operational impact

Recreate accounts and reconnect desktop clients to the new origin. No old
sessions or registrations are transferred. Local paths and marker names now
use Syntila; existing local Conclave state is not copied by this cutover.
Email/password registration uses the existing authorized conclaveax.com email
senders. No test email was sent. GitHub and Google sign-in remain disabled until
new-origin OAuth callbacks and the corresponding Worker secrets are configured.

## Planned root-site / app-subdomain transition

The public site is being prepared for `https://syntila.app`, and the web app
for `https://app.syntila.app`. The app Worker must retain the root domain until
legacy auth and Connect clients have a verified path; do not transfer the
root hostname to the site before that compatibility is in place and tested.
The Worker now has both domains attached. The stable backend-token issuer is
configured separately as `SYNTILA_BACKEND_TOKEN_ISSUER=https://syntila.app`;
changing `BETTER_AUTH_URL` must not silently change the issuer expected by the
VPS. Set and validate the passkey relying-party ID and permitted origins so
existing passkeys remain usable. Update Google and GitHub OAuth callback URLs,
verify sign-in and desktop authorization, and plan reauthentication for
host-only browser cookies. Preserve existing Connect installation and
runtime identity, and verify existing saved root-domain Cloud URLs before
cutover. Redirect legacy website paths to their matching new URLs. The Privacy
Policy contains outstanding disclosure placeholders and must be completed
before publishing the revised site.

Cutover preparation in this checkout preserves `https://syntila.app` as the
backend JWT issuer while allowing `https://app.syntila.app` as the auth origin.
The public-site Worker is configured to run before static assets and forward
root-domain `/api/*` and `/health` requests to the auth Worker through its
`LEGACY_AUTH` service binding. It redirects known old app paths to the app
subdomain and redirects the old public-site hostnames to the matching new site
paths. These are staged changes, not proof that existing desktop clients,
passkeys, or cookies work after deployment. Keep the old and new browser origins
in the VPS `ALLOWED_ORIGINS` setting until the transition is complete; retain
existing persisted Connect and Profile Lab Cloud origins. Verify old desktop
sessions, Connect recovery, both OAuth providers, and passkeys against the
actual deployed services before declaring cutover complete.
