# ADR-024: Free Spaces hold up to four people

Status: accepted. Extends [ADR-022](ADR-022-account-plans.md).

## Policy
A **Free-owned Space allows four human members in total, owner included**
(`FREE_SPACE_MEMBER_LIMIT`, `account-plan.ts`). A Plus-owned Space has no
subscription-based member cap. The **Space owner's effective plan** decides
(same expiry and `past_due` grace rules as ADR-022), never the inviter's or the
recipient's plan, so a Free person can join a larger Plus-owned Space. Each
Space is counted on its own. There are no plan limits on Spaces or Threads
themselves. Workspace sharing, personal Workspace and execution concurrency
policies are unchanged. Membership never grants access to a shared Workspace.

## Counting
- **Members:** every `space_memberships` row (owner, collaborators, viewers).
  AI Workers are not Space members and are not counted.
- **Reservations:** each distinct *valid pending* invitation
  (`status = 'pending'` and not past `expires_at`) reserves one slot.
  Revoked, declined, expired and accepted invitations reserve nothing.
- **Allowed:** members + reservations must stay at or below four.
- **Duplicates:** a second invitation for the same person (email or user,
  existing normalization and unique indexes), a resend, an idempotent retry, or
  inviting an existing member returns the existing conflict/replay and never
  takes another slot.
- **Acceptance** turns the invitation's own reservation into membership; its
  reservation is excluded from the count, so acceptance never needs a second slot.
- **Freed by:** removing a member, revoking, declining or letting an invitation
  expire.

## Enforcement
The only paths that add a person are creating an invitation and accepting one
(creating a Space adds the owner alone). Ownership transfer does not exist, so
there is nothing to re-evaluate there; if it is added it must run the same
admission rule against the new owner.

`spaceMemberAdmissionSql` is evaluated *inside* the write:
- **Invite:** `INSERT ... SELECT` puts `NULL` into the NOT NULL `token_hash`
  when admission fails. The constraint error rolls back the whole batch
  (including any idempotency receipt) and maps to the stable error, so
  concurrent invitations cannot exceed the allowance.
- **Accept:** the invitation `UPDATE` sets `status` to `NULL` the same way, so
  the membership insert never happens. The owner's entitlement and capacity are
  re-read at acceptance.
- A cheap pre-check returns the same error early with a clear message.

Error: HTTP 402, `code: "space_member_limit_reached"`, message "Free includes up
to 4 people in each Space, including the owner." followed by, for the owner,
"Upgrade to Syntila Plus to allow larger Spaces, or remove a member or
invitation." and, for an invitee, "The Space owner needs to upgrade or free a
slot." Authorization (owner-only invitations) is unchanged.

## Existing Spaces and downgrades
Nothing is removed, revoked or deleted automatically. A Free-owned Space that
has more than four people (or pending invitations) after a downgrade keeps all
of them. Additions are blocked: new invitations, and acceptance of pending
invitations while members plus *other* reservations are already at four. Removing
members, revoking invitations and all other management stay available; once
capacity opens, a kept invitation can be accepted. Upgrading lifts the limit
immediately.

## Read API and UI
`GET /api/spaces/:id/members` also returns
`usage: { members, pendingInvitations, limit }` (`limit` is `null` when the
owner's plan sets no cap). The Members tab shows "3 members · 1 pending
invitation · 4 people allowed." and, at the limit, the owner/member explanation.
Uncapped Spaces show nothing about limits and nothing is advertised as
unlimited. There is no upgrade action to link yet and no checkout flow.

## Rollout and limitations
- No migration. Spaces already over four keep working; additions stop on deploy.
- Grant Plus (ADR-022) to owners who should keep inviting before deploying.
- The usage note fetches the members endpoint a second time on the client.
- The "resend invitation" action revokes and re-creates; at the limit the
  re-created invitation takes the slot the revoked one freed.
