# ADR-022: Free and paid account plans

## Status
Accepted and implemented: the two tiers, the server-enforced feature gate and the
manual grant flow. Subscription billing through Paddle is not live: a development-only
sandbox flow and a disabled-by-default live checkout-configuration endpoint exist, but
live notifications, fulfillment and the customer portal are not implemented, and live
purchases must stay off until they are. See [Paddle sandbox](../operations/PADDLE_SANDBOX.md).
Provider-sourced plans (`source = provider`) may update `account_plans` from verified
notifications but never replace a manual grant; a verified sandbox purchase reconciles a
previous manual Free override.

## Context
Some web-app features will be available only to subscribers. We want one
paid tier, a server-enforced gate, and freedom to rename or reprice the tier
without migrations.

## Decision
- **Two tiers per user account:** `free` and `paid`. `paid` is the stable
  identifier in PostgreSQL and the API; the product name ("Syntila Plus") lives only in
  the app (`paidPlanName`).
- **Storage:** `account_plans`. A missing
  row means Free. `source` is `manual` (grants) or `provider` (future billing
  webhooks). The client never writes plans.
- **Operator protection:** the Accounts app may change manual grants only.
  The backend atomically refuses grant and revoke when a plan is provider-sourced
  or retains a provider customer or subscription ID, including records previously
  overwritten by an operator. Provider-linked billing is managed at the payment
  provider. The app disables plan controls when management status is unknown.
- **Effective tier** (`apps/backend/src/domain/account-plan.ts`): Paid only when
  `tier = 'paid'`, status is `active`, `trialing` or `past_due`, and
  `current_period_end` is absent (open-ended grant) or in the future.
- **Gate by feature name, not tier.** `PAID_FEATURES` lists paid features.
  Handlers that perform a paid action call `requirePaidFeature`, which fails
  with HTTP 402 and `{ "code": "paid_plan_required" }`. Only `HttpError`
  codes are exposed in error bodies.
- **Paid feature `worker.sharing`:** sharing a Worker with other people
  requires the owner's plan: a Person Share (`PUT /api/workers/:id/person-shares`)
  and enabling Space member access (`PUT /api/workers/:id/space-access` with any
  `enabled: true` entry). Listing, deleting a share and turning access off stay
  free, so a downgraded owner can still remove access.
- **Downgrade pauses sharing.** Admission and every list that honors a share
  also require the owner to be paid (`paidOwner`, kept in step with
  `effectiveTier`): the other person stops seeing the Worker and new Work on it
  fails with 403. Shares are not deleted, so a plan that lapses only by
  `current_period_end` needs no event, and renewing restores access. Work
  already admitted finishes. The Space owner's own Workers, which members use
  through their Space rights, are not shares and are not affected.
- **No Worker-count allowance.** The former limit on Free is removed; Free accounts may register any
  number of their own Workers.
- **Read API:** `GET /api/me/plan` returns
  `{ tier, status, currentPeriodEnd, features, attachments }`.
- **App:** `AxAccountPlanDataSource`, `AccountPlanController`, and
  `PaidFeatureGate` show, hide or label features; Profile shows the plan.
  Failed loads count as Free. The app never authorizes paid actions.

## Consequences
- Manual grants, until billing ships:
  `INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at)
  VALUES(?, 'paid', 'active', 'manual', datetime('now'), datetime('now'))`.
- Next: billing provider checkout/portal, a signed and idempotent webhook that
  upserts `source = 'provider'` rows, upgrade prompts, and downgrade handling.
- Plans are per user. Moving to per-Worker billing would need a new owner
  column and a different lookup.

- **Concurrent AI executions:** Free accounts run one at a time; see
  [ADR-023](ADR-023-free-execution-concurrency.md).

- **Space members:** Free-owned Spaces hold four people; see
  [ADR-024](ADR-024-free-space-member-limit.md).

- **Research:** `workflow.research` gates the standalone Research workflow for
  the requesting account; see [ADR-026](ADR-026-research-parallel-synthesis.md).

### Plan overview

The Profile plan summary links to the Plans & subscription page
(`subscription_page.dart`). It shows the viewer's current plan and status above the approved Syntila Plus prices (1 month $9, 1 year $81;
`plusPrices`) and a Free and Plus comparison that names whose plan decides
each limit. No billing provider is chosen, so the page has no purchase or
manage action and says so; a period end reads "Active until", not "Renews".
Places where a Free limit or a Plus-only feature stops the viewer (Worker
sharing, a full Space, full storage) link to
the page with `ViewPlansLink`. Cloud remains the only enforcement. The
comparison does not expose custom Worker plugins.

### Plus workflows

Research (`workflow.research`) and Implement (`plan_implement`,
`workflow.implement`) need the requester's Syntila Plus; Chat and Work stay
Free. `requireWorkflowEntitlement` enforces both for submission, the Thread
request queue and user-triggered retries, with `402 paid_plan_required`. The
app shows both workflows to everyone: on Free, picking one in the composer
opens Plans & subscription instead of selecting it (`workflowAccess`,
`_offeredWorkflows`). Research is shown to all accounts by owner decision,
superseding the preview-only visibility in ADR-026. Rollout: grant Plus to
accounts that should keep Implement before deploying Cloud.
