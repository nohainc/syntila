# People v1

People is a private directory distinguishing between established collaborators, pending personal invitations, and approved personal connections. Email invitations remain pending until accepted. Creating an invitation does not create a Person. Successful membership creation in a Group Space establishes relationships between the new member and every existing member of that Space, including collaborators other than the inviter.

## Collaborators vs. Personal Connections

The directory recognizes two distinct relationship tiers:
1. **Known collaborator:** someone the user has worked with in a shared Group Space (`people_relationships`). A collaborator is eligible for a personal invitation or invitation to other Spaces, but is not automatically a personal connection and does not automatically have a Direct Space.
2. **Pending personal invitation:** an explicit invitation sent to establish a direct 1:1 communication link.
3. **Approved personal connection:** a connection formed when a personal invitation is accepted by the recipient. Acceptance provisions exactly one shared Direct Space; either participant can create its first Thread.

Group Spaces never automatically generate Direct Spaces between all participating members.

## Personal invitation lifecycle

~~~text
Alice selects Add Person
         │
         ▼
Alice enters Bob's email (or selects known collaborator)
         │
         ▼
Personal invitation created (pending)
         │
         ▼
Bob receives invitation
         │
    ┌────┴────┐
    ▼         ▼
 Accept     Decline
    │         │
    ▼         └── No Direct Space
Connected
    │
    ▼
Get or create unique Direct Space (unordered pair {Alice, Bob})
    │
    ▼
Add Alice + Bob as participants
    │
    ▼
Direct Space available to both users, who can create Threads
~~~

- **Concurrency and idempotency:** If Alice and Bob invite each other concurrently, or if acceptance is retried, Cloud guarantees race-safe convergence: exactly one Direct Space is retrieved or created for the unordered pair `{Alice, Bob}`.
- **Contact removal:** Removing a personal connection disassociates the 1:1 connection and archives or freezes the Direct Space. Contact removal has no effect on unrelated shared Group Spaces.
- **Identity:** Relationships bind strictly to immutable user IDs (`userId`). Mutable display names and emails are never used as permanent relationship identifiers.
- **Deployment:** Apply migration `0107_optional_direct_general_thread.sql` before deploying Cloud code that creates personal Spaces without a default Thread. Existing General Threads and their references are preserved.

## Personal support Space

`POST /api/people/support` (authenticated) returns the caller's personal support Space with the configured support account: `201` with `{ spaceId }` when created, `200` when it already exists.

- **Configuration:** `SYNTILA_SUPPORT_ACCOUNT_EMAIL` names the support account (trimmed, case-insensitive). It is resolved to an immutable user ID on each request and must be an active user. Missing or unresolvable configuration returns `503`; the support account itself gets `409`; a block in either direction returns `403`. Nothing is created in these cases.
- **Shape:** The Space is an ordinary Direct Space (owner: the user; collaborator: the support account) with no default Thread, and no `person_connections` row, so support is not a personal connection. `support_spaces (user_id, support_user_id)` marks it, enforcing one per user per support identity; migration `0108_support_spaces.sql`.
- **Idempotency and races:** The Space, memberships, Direct Space row, per-user state, and marker are written in one atomic batch. A concurrent loser fails on the unique pair or marker, re-reads, and returns the winner's Space.
- **Existing history:** If a Direct Space already exists for the pair (for example from a prior connection), it is adopted and marked rather than duplicated, preserving its Threads and messages.
- **Identity changes:** Changing the configured account leaves earlier support Spaces with the previous account and provisions a new one on the next request. The support account's access is limited to its membership in each user's Space.

### Support: visibility, restrictions, deployment

- **Sidebar:** The support Space is hidden by default for its owner (`direct_space_user_state.hidden = 1`). Opening it, replies, and unread state never change that; only the user's setting does (Settings → Show Syntila Support in sidebar, `PATCH /api/spaces/:id {hidden}`), which applies to every device. `GET /api/people/support` reads `{spaceId|null, hidden}` without provisioning. "Message Syntila" in the application menu opens the Space (provisioning on first use) while hidden, with a loading notice and a Retry action on failure. Ordinary Direct Spaces keep their open/reply-unhides behavior.
- **Messaging only:** For both participants, Chat, Work, and own Workers are denied in a support Space (`loadSpacePermissions` returns `isSupport` and cleared rights; `requireWorkflowPermission` and the execution-selection path reject with 403). Space responses carry `isSupport`; the client shows only the human composer and no AI History.
- **Two-user workflow:** (1) The operator configures `SYNTILA_SUPPORT_ACCOUNT_EMAIL` for an existing active account. (2) User A chooses Message Syntila; the Space is created hidden and A sends a message. (3) The support account sees the Space with unread state and replies as a human; A's sidebar stays unchanged. (4) A enables the Settings switch and the entry appears on all A's sessions. (5) B repeats independently and receives a separate Space.
- **Deployment prerequisites:** Apply migrations `0108_support_spaces.sql` and `0109_support_space_default_hidden.sql` before deploying Cloud and app. Local and production Wrangler configurations set `SYNTILA_SUPPORT_ACCOUNT_EMAIL` to `syntila@nohainc.com`; without a valid configuration support returns 503 and the app shows a retryable error. The support account must be an active user and is a member of every user's support Space.
- **Validation status:** Flutter analyze is clean; focused app tests pass; the full app suite has 2 failures that predate this work (Research workflow configuration, phased-queue badge). Cloud: all 8 `support-space` tests and the thread read-model test pass, and the typecheck is clean except `implement-plan.ts` (a `loadSpaceWorkflowConfigurations` signature mismatch from separate in-progress work). The full Cloud run still has about 27 failures in older Direct Space suites (`direct-space-*`, assignment races, `implement-plan`), caused by in-progress changes not made here (optional General Thread, own-Worker selection, missing delete guard) and not by support code. They must be resolved or updated before `pnpm validate:cloud` is green.

## Persistence and identity

Membership derivation alone cannot retain People after the last shared Space disappears. `people_relationships` therefore stores one canonical undirected pair of user IDs and its establishment timestamp. The ordered composite primary key prevents duplicates and self relationships. Both identities reference users. A membership insertion trigger establishes pairs atomically with membership creation; membership and Space deletion leave those pairs intact.

Migration `0023_people_relationships.sql` backfills accepted co-members across all Spaces, using their earliest shared membership timestamp. It consolidates duplicate pending invitations by retaining the oldest and revoking the rest, then enforces one pending invitation per Space and case-insensitive email. Expired pending invitations may be replaced. The migration does not send invitations or modify historical accepted memberships.

## Authenticated APIs

`GET /api/people` returns `{schemaVersion: 1, people: [...]}` for the authenticated user only. Each Person has:
- `userId` (stable identifier)
- current `displayName`
- `email`
- nullable `avatarUrl`
- `establishedAt`
- current `sharedSpaceCount` (counting shared Group Spaces only)
- `sharedSpaces: [{id, name}]` (Group Spaces only)
- `invitableSpaces: [{id, name, permissions, canInvite}]` (Group Spaces owned by user)
- `pendingInvitationSpaceIds: string[]`
- `connectionStatus`: `'connected' | 'disconnected' | 'blocked' | 'invitation_sent' | 'invitation_received' | 'collaborator'`
- `directSpaceId`: `string | null` (present when connected or disconnected)
- `generalThreadId`: `string | null` (present only for existing Spaces with a legacy General Thread)
- `invitationId`: `string | null` (present when pending invitation exists)

Profiles and personal connection states are joined live rather than copied into relationships. There are no creation, deletion, ownership, global search, or enumeration endpoints.

`POST /api/people/connections/:userId/disconnect` (and `DELETE /api/people/connections/:userId`) transitions an approved personal connection to `'disconnected'` with `disconnected_at` timestamp. Historical conversation messages remain preserved in the Direct Space in read-only audit state. Reconnection is initiated via a new personal invitation (`POST /api/people/invitations`).

`POST /api/spaces/:spaceId/invitations` accepts exactly one of `email` or `userId`, plus role/permissions. A known `userId` must be an established Person of the caller; Cloud resolves the current email and applies existing Space invitation authorization. Self invitations and duplicate pending invitations are rejected. Acceptance claims the invitation and creates membership in one batch; failed, expired, or competing acceptance cannot establish a relationship.

## AX synchronization

The session-wide `['people']` query contains immutable domain models, shared by the People page and Space invitation picker. Bootstrap loads it once; page and dialog navigation reuse cached state. Session clearing fences outstanding reads. There is no People polling.

Existing authorized Space events refresh People after acceptance, membership changes, and Space deletion. Better Auth profile updates publish durable, ID-only `people.updated` events to established peers' user streams. This event cannot contain profile fields or execution/Space identity. User and Space reconnect recovery refresh registered People even when its page is closed. The invitation picker submits stable user IDs; email remains available for someone new.

Apply migrations 0023 and 0025 before deploying Cloud and AX changes. Migration 0025 removes obsolete member-level invitation rights from persisted Space snapshots; invitation management is owner-only. Relationship retention currently has no manual removal control; account deletion cascades relationship rows. Direct administrative profile SQL changes require an explicit synchronization signal or reconnect; application profile changes use the authentication hook.

## People page and details

The existing application/account popup opens the global `/people` route; People has no main sidebar entry and does not depend on selected Space. Name/email search filters only the already-authorized in-memory People list locally without issuing Cloud discovery requests.

### Primary Add Person Action and Empty State
- **Add Person Action:** A primary "Add Person" button opens a dialog to send a personal connection invitation by email.
- **Empty State:** For new accounts without people, the page displays: `No people yet. Invite someone to start a private conversation.` with an inline Add Person button.
- **Search Empty State:** If a local query produces no matches, the page reports `No people match "<query>"`.

### Connection State Actions
Each Person card displays the contact's name, email, avatar, connection state badge, shared Group Spaces, and contextual actions:
- **Known Collaborator:** Displays `Collaborator` badge, `Connect` button (sends invitation using their stable `userId`), and `Add to Space`.
- **Invitation Sent:** Displays `Invitation sent` badge, `Pending` label, `Cancel` button, and `Add to Space`.
- **Invitation Received:** Displays `Invitation received` badge, `Accept` and `Decline` buttons, and `Add to Space`.
- **Connected:** Displays a `Connected` badge, a `Message` button that opens the personal Space (or an existing legacy General Thread), `Add to Space`, and a `Remove connection` action.
- **Disconnected:** Displays `Disconnected` badge, `Reconnect` button, and `Add to Space`.
- **Blocked:** Displays `Blocked` badge, `Unblock` action, and `Add to Space`.

The version 1 People response additionally includes `sharedSpaces: [{id, name}]` and `invitableSpaces: [{id, name, permissions, canInvite}]`. Shared names are restricted to Spaces where both users are members; a Person's other Spaces remain private. Invitation destinations are limited to Spaces owned by the current user and exclude archived Spaces, existing membership, and unexpired pending invitations. The permissions snapshot bounds requested collaborator/viewer rights; the invitation endpoint rechecks live ownership, membership, and invitation state on submission.

Person details and the Add to Space picker subscribe to the same session query without opening-time reads. Membership, invitation, permission, and Space rename signals update open details and eligibility. Successful invitations refresh People and registered Space invitation/audit queries; rejected writes reconcile eligibility without retrying the invitation. Session fences prevent a late successful write from reloading a signed-out user's directory.

Cold loading displays progress. Empty accounts explain acceptance; search misses have their own empty state. Connection errors preserve cached People and expose Retry, while invitation submission is disabled when eligibility reads fail or are refreshing. The existing shell live-update/reconnecting banner remains the authoritative transport indicator.

## Shared invitation flow

~~~text
USER
 ├── PEOPLE: known collaborators
 └── SPACES
      ├── Members
      ├── Invitations
      └── Permissions

First collaboration:  Email invitation → Accept → Known Person
Future collaboration: People selection → Space invitation → Accept
~~~

Space → Invite people and People → Person → Add to Space use the same `SpaceInvitationDialog` and `AxSpaceInvitations` writer. The Space dialog searches only cached People, displays recent relationships, supports multiple selections, and labels each Person as Already a member, Pending invitation, Available to invite, or unavailable. Known members and pending recipients cannot be selected. Email remains available for someone new; People selection and email entry are mutually exclusive.

Both paths expose the same per-Space permission editor. Read access is inherent in membership; Chat, Work, and own Thread management (the three Space member rights; own Workers in Chat follows Chat) are bounded by the owner's selected rights. Invitation management is owner-only and is not a member permission. Cloud validates those rules again. Each selected Person creates a normal invitation, never a direct membership. Partial multi-person failures retain only unsent selections; successful recipients are not retried. Resend preserves recipient identity and selected permissions, bounded by current rights.

Migration `0024_space_invitation_identity.sql` adds nullable `invitee_user_id` to Space invitations. Known-Person requests persist this identity; email is a delivery-address snapshot. Inbox, Accept, Reject, pending detection, and notifications use the user ID whenever present, so email changes or reuse cannot transfer consent. Unknown/legacy pending email invitations remain email-addressed until accepted; acceptance binds them to the authenticated user ID. Existing accepted invitations are backfilled from `accepted_by_user_id`. A unique pending Space/user index supplements the pending email index. Account deletion cascades invitations addressed to that deleted identity rather than falling back to a reusable email.

Apply migration 0024 after 0023, then 0025, before deploying these Cloud/AX changes. These migrations preserve accepted memberships and People relationships while cleaning persisted invitation identity and obsolete member-level invitation rights. The obsolete email-only AX writer and unused email-only authentication invitation reader are removed. There is no separate membership or global discovery API.

## Personal Connections, Lifecycle, Privacy, and Account Deletion

Direct Spaces and personal connections implement discrete user lifecycle and privacy controls:
- **Hide / Unhide Conversation:** A requesting user can hide a Direct Space from their active view (`PATCH /api/spaces/:id` with `{ hidden: true }`). It remains visible to the other participant. Visibility is restored explicitly via `{ hidden: false }` or automatically when a new incoming discussion message is received.
- **Connection Removal:** Transitioning a connection to `status = 'disconnected'` freezes direct messaging and AI execution in the Direct Space until reconnected. Disconnecting does not alter shared Group Spaces or delete message history. Reconnection reuses the canonical pair identity without duplicating spaces.
- **Blocking & Unblocking:** Users can block unwanted peers (`POST /api/people/blocks/:userId`), which immediately disconnects any active direct connection and prevents invitations, direct messages, and AI execution in both directions. Unblocking (`DELETE /api/people/blocks/:userId`) restores the ability to send reconnection invitations.
- **Direct Space Deletion Guard:** Generic destructive space deletion (`DELETE /api/spaces/:id`) is explicitly forbidden on Direct Spaces (returns HTTP 403) to prevent one user from unilaterally destroying conversation history.
- **Account Deletion Safety:** When a user account is deleted or deactivated, `handleAccountDeletionCleanup` safely transfers technical ownership of Direct Spaces to the active surviving peer (`spaces.owner_user_id = peer.id`, `space_memberships.role = 'owner'`), removes the deleting user's membership, disconnects personal connections, and cancels pending invitations. Conversation history is fully preserved for the surviving participant without foreign-key constraint failures.

## Account avatar files

`PUT /api/profile/avatar` accepts multipart form fields `original` (JPEG, PNG,
GIF, or WebP, up to 5 MB) and `thumbnail` (PNG, up to 128 KB). AX preserves the
original bytes and renders a proportional PNG with a maximum dimension of 128 px
in the browser (animated images use a still frame). Only the thumbnail is served
by the authenticated avatar route; originals remain private for future use.
R2 keys are `user-avatars/{accountId}/{uploadVersion}-original` and
`user-avatars/{accountId}/{uploadVersion}-thumbnail`. The existing `avatar_url`
column references the thumbnail. Upload versions prevent stale caching and
concurrent file overwrites. Publication checks the prior profile reference;
failed publication removes the new pair. Replacement deletes the prior pair.
Account deletion removes every object under the account's avatar prefix before
deleting the account, including interrupted-upload leftovers; storage failures
stop deletion so it can be retried. Existing single-object avatars remain readable
and are removed when replaced. No schema migration is required. Deploy Cloud and
AX together because the upload request now requires both multipart files.

Apply migration 0106 (three Space member rights) before deploying the matching Cloud and AX changes; it removes the derived `useOwnWorkers` key from member and invitation snapshots.
