# Syntila Accounts for macOS

A native SwiftUI operator application for macOS 14+. Search users by name,
email, or exact ID; inspect account metadata and lifetime Space membership,
owned Workspace, message, work request, and failed request counts; suspend/re-enable
accounts; request a password recovery email.

## Build and run

From the repository root, install the existing Node dependencies (`pnpm install`),
then run:

```sh
pnpm accounts:build
open 'apps/account_manager/build/Syntila Accounts.app'
```

You can also run `./scripts/build-account-manager-macos.sh` directly from any
working directory. It checks macOS build prerequisites and creates the app. The output is
`apps/account_manager/build/Syntila Accounts.app`; building does not launch the
app or access either database.

Requires Xcode command-line tools and Node 24+ on PATH, `~/.local/bin`,
`/opt/homebrew/bin`, or `/usr/local/bin`. The build records this repository's absolute location in the
app resources. Rebuild after moving the checkout. This is an operator tool
that requires the checkout and its dependencies, not a standalone distributable.
The build applies an ad hoc signature; release signing/notarization is not supplied.

For production access, authenticate Wrangler in Terminal using your existing
Cloudflare operator account (`pnpm exec wrangler login`). The app uses that
account's D1 permissions. It has no separate app login and must only be installed
for trusted database operators. No API key is collected or persisted by the app.

Local selects `syntila-development` through `apps/cloud/wrangler.jsonc` and
Wrangler's local persistence directory associated with that config. Run the
existing local migration/startup scripts first. Production selects
`syntila` through `infra/cloudflare/app.wrangler.jsonc`, with
explicit `--remote`. Neither target can be supplied by user-controlled input.
Switching environments clears the selected account and reloads data. Searches
return at most 200 displayed accounts; refine the search when the limit is reached.

## Account actions

Blocking uses a confirmation dialog naming the account and selected environment,
without email retyping. Unlock and password recovery still require retyping the
selected account email. The bridge rechecks user ID, email and current state.
Lock changes active to suspended, deletes browser sessions, revokes desktop
human sessions and writes an `auth_audit_events` record attributed to the local
OS operator name. Unlock changes suspended to active. Deactivated accounts
cannot be re-enabled with this tool. Existing authorization rejects suspended
users. Running work and Workspace runtime credentials are not cancelled/revoked.

Password recovery calls the selected Cloud's existing
`/api/auth/request-password-reset` endpoint, redirecting to its `/login` page.
Local Cloud must be running on port 8787. This sends a time-limited reset link,
not a new plaintext password. Cloud owns token generation, password hashing,
email delivery, expiry and session revocation. A successful request does not
prove inbox delivery; the UI states this explicitly. Email provider configuration
and rate limits still apply. Recovery is disabled for suspended/deactivated users.

SQL and persistence remain in the Cloud operator bridge at
`apps/cloud/scripts/account-manager.mjs`; the native app receives read models
and command results. This tooling uses existing Cloudflare operator access and
is separate from the human product API and Workspace runtime. It adds no public
API, database schema, credential table, migration, or compatibility layer.
Messages counts only thread discussion messages authored by the selected user.
Chat/Work request prompts are counted under Work requests, not Messages. Last
message (UTC) shows the latest discussion message send timestamp, or None when no
such messages exist. Edits and worker responses do not count as new messages.
Statistics appear in this order: Workspaces, Spaces, Messages, Work requests,
Failed requests. No new migration is introduced.
Statistics are existing product activity counts, not token/cost billing estimates.
Account metadata is held in memory, not cached on disk by this application.

## Paid membership

Each account shows its Membership (Free, or Paid with its source and period end)
and a Paid tag in the list. **Enable paid membership** writes an open-ended
`manual` row in `account_plans` (tier `paid`, status `active`, no period end);
**Disable paid membership** sets that row to tier `free`, status `canceled`.
Both use a confirmation dialog without email retyping, recheck user ID and email,
and write an `account.admin.grant_paid` / `account.admin.revoke_paid` audit event.
The displayed plan uses the same rule as Cloud's `paidOwnerSql`. Enabling
overrides an existing provider subscription row. Disabling pauses Workspace
sharing for people the user shared with (see ADR-022). Requires migration
`0094_account_plans.sql` in the selected database.

## Validation

```sh
node --test apps/cloud/scripts/account-manager.test.mjs
pnpm accounts:build
```

Tests execute SQL against an in-memory SQLite database loaded from the actual
v8 baseline and stub only network/CLI boundaries. They do not contact production
or send email. Live production authorization and actual inbox delivery require
operator acceptance. App launch and local connectivity can be checked separately
without performing any account mutation.

Wrangler's explicit local/remote command flags follow the
[official D1 CLI reference](https://developers.cloudflare.com/d1/wrangler-commands/).

## Retained development evidence

On 2026-10-25, the native release build, property-list validation and ad hoc
signature verification passed. Six focused tests passed. Manual native UI
checks loaded both the local and production account lists, inspected local
account metadata/activity, verified that the confirmation button is disabled
until the email is retyped, and cancelled the dialog. The app was returned to
Local afterward. No account mutation or email send was performed against either
live database during these checks.

Cloud component validation (`pnpm validate:cloud`) passed generated-type and
TypeScript checks; 1,192 tests passed and five assignment lifecycle/revocation/
start-permit tests timed out. A single-worker rerun of those three files passed
50 tests and still timed out on three lifecycle/start-permit tests. Those paths
were not modified by this change; their timing failures remain unresolved.
The focused account-manager SQL tests, CLI boundary tests, native build and
live read-only UI checks cover this tool's changed behavior. Production writes
and actual recovery-email delivery remain outside the retained acceptance evidence.

### Message statistics and blocking update

Eight focused account-manager tests pass, including empty-message defaults,
counts across both message sources, latest send time (excluding edits and other
users), and blocking without email retyping while stale-account checks remain.
The release app was rebuilt and its local UI verified to show Messages and Last
message (UTC), and an enabled block confirmation without an email field. The
dialog was cancelled; no account was changed. Direct-launch Node discovery now
also includes `~/.local/bin`. Validation stayed focused on this isolated operator
bridge and native app; Cloud server/runtime code and schemas were not changed.

### Discussion-only message statistics

The Messages count and Last message timestamp now exclude Chat/Work request
prompts and use only the selected user's thread discussion messages. The focused
regression fixture includes a newer request prompt and a later edit, ensuring
neither inflates the count or advances Last message. The native statistics row
now follows Workspaces, Spaces, Messages, Work requests, Failed requests.
