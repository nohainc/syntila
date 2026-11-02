# ADR-022: Free and paid account plans

## Status
Accepted (foundation). Billing-provider integration is not yet implemented.

## Context
Some web-app features will be available only to subscribers. We want one
paid tier, a server-enforced gate, and freedom to rename or reprice the tier
without migrations.

## Decision
- **Two tiers per user account:** `free` and `paid`. `paid` is the stable
  identifier in D1 and the API; the product name ("Syntila Plus") lives only in
  the app (`paidPlanName`).
- **Storage:** `account_plans` (migration `0094_account_plans.sql`). A missing
  row means Free. `source` is `manual` (grants) or `provider` (future billing
  webhooks). The client never writes plans.
- **Effective tier** (`apps/cloud/src/account-plan.ts`): Paid only when
  `tier = 'paid'`, status is `active`, `trialing` or `past_due`, and
  `current_period_end` is absent (open-ended grant) or in the future.
- **Gate by feature name, not tier.** `PAID_FEATURES` lists paid features.
  Handlers that perform a paid action call `requirePaidFeature`, which fails
  with HTTP 402 and `{ "code": "paid_plan_required" }`. Only `HttpError`
  codes are exposed in error bodies.
- **First paid feature, `workspace.sharing`:** inviting a person to use your
  Workspace (`POST /api/workspaces/:id/invitations`) requires the owner's
  plan. Listing, cancelling invitations and revoking access stay free, so a
  downgraded owner can still remove access.
- **Downgrade pauses sharing.** Every read that honors a Person Grant also
  requires the owner to be paid (`paidOwnerSql`, kept in step with
  `effectiveTier` by a test): the borrower stops seeing the Workspace and its
  Workers, cannot select it, and new Work on it fails with 403. Grants are not
  deleted, so a plan that lapses only by `current_period_end` passing needs no
  event, and renewing restores access. Work already admitted finishes.
  Accepting a pending invitation also fails with a plain 403 (the invitee
  cannot fix it by upgrading). The owner's own use and Space-member use of the
  owner's Workspace are not affected.
- **Personal Workspace allowance.** Free accounts may own
  `FREE_PERSONAL_WORKSPACE_LIMIT` (1) registered Workspace; Plus has no
  subscription-based count limit. The limit and its SQL
  (`personalWorkspaceAdmissionSql`) live in `account-plan.ts` next to the plan
  rules, so expiry and `past_due` grace behave exactly as for other paid checks.
  - *Counted:* Workspaces the user owns whose status is not `revoked`
    (removal/release sets `revoked`), offline ones included. Workspaces shared
    with the user, Workers, models, Spaces and Threads are not counted.
  - *Enforced* in `POST /api/workspace-runtime/register`, the only path that
    inserts `execution_workspaces`. Admission is the `WHERE` of that `INSERT`
    inside the registration batch, and every other new-registration statement
    runs only if the row exists, so concurrent requests cannot exceed the
    allowance and a refused request writes nothing. Failure is HTTP 402
    `{ code: "personal_workspace_limit_reached", error: "Free includes one
    personal Workspace. Upgrade to Syntila Plus to connect more machines." }`.
  - *Not consumed:* recovering or reconnecting an existing installation
    (same owner, same Workspace), reauthentication and upgrades. Retrying a
    registration whose Workspace already exists is a recovery.
  - *Removal* (release/revoke) frees the slot. Local files, provider
    credentials and user work are untouched; only the Cloud registration ends.
  - **Grandfathering:** nothing is deleted, disconnected or arbitrarily
    chosen. A Free account that already owns several Workspaces (including
    after a Plus downgrade) keeps all of them, can reconnect and manage them,
    and is only blocked from registering more until it owns fewer than the
    allowance (i.e. none) or returns to Plus. Removing one of three leaves it
    still blocked.
  - The Workspace service/CLI maps the code to a
    `personalWorkspaceLimitReached` registration error and headless-login
    failure with the same message; the web Workspaces page shows usage
    ("1 of 1 personal Workspace used (Free)") and the upgrade explanation. There
    is no checkout flow yet, so no upgrade button.
- **Read API:** `GET /api/me/plan` returns
  `{ tier, status, currentPeriodEnd, features, workspaces: { owned, limit } }`
  where `limit` is `null` for Plus.
- **App:** `AxAccountPlanDataSource`, `AccountPlanController`, and
  `PaidFeatureGate` show, hide or label features; Profile shows the plan.
  Failed loads count as Free. The app never authorizes paid actions.

## Consequences
- Manual grants, until billing ships:
  `INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at)
  VALUES(?, 'paid', 'active', 'manual', datetime('now'), datetime('now'))`.
- Next: billing provider checkout/portal, a signed and idempotent webhook that
  upserts `source = 'provider'` rows, upgrade prompts, and downgrade handling.
- Plans are per user. Moving to per-Workspace billing would need a new owner
  column and a different lookup.

- **Concurrent AI executions:** Free accounts run one at a time; see
  [ADR-023](ADR-023-free-execution-concurrency.md).

- **Space members:** Free-owned Spaces hold four people; see
  [ADR-024](ADR-024-free-space-member-limit.md).

- **Research:** `workflow.research` gates the standalone Research workflow for
  the requesting account; see [ADR-026](ADR-026-research-parallel-synthesis.md).
