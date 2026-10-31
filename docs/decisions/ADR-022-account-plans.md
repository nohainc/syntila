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
  downgraded owner can still remove access. Existing grants keep working.
  Accepting a pending invitation re-checks the owner's plan and fails with a
  plain 403 (the invitee cannot fix it by upgrading). Space grants are not
  gated.
- **Read API:** `GET /api/me/plan` returns
  `{ tier, status, currentPeriodEnd, features }`.
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
