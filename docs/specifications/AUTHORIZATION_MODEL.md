# Authorization Model

**Status:** Current security policy for Syntila, Cloud, Workspace ownership, Threads, and Tool Profiles.

Cloud resolves the authenticated Better Auth session to an active Syntila user. It derives Space roles from `space_memberships`; it does not trust client-supplied organization or Workspace membership claims.

## Space access

Space roles are `owner`, `collaborator`, and `viewer`. Their permission sets are defined in `packages/security/src/index.ts`:

- Owners can read, write, and manage their Space, start Work, and control Runs.
- Collaborators default to reading, Chat, Work, and management of their own Threads. Owners can refine these rights individually.
- Viewers can read Space content.

Cloud checks membership at the resource boundary. A missing, suspended, or deactivated user is denied.

## Workspace execution access

A Workspace has one Cloud owner. The owner manages the Workspace runtime. Space
execution access is selected by the Space owner in Workflows; Cloud materializes
and validates the internal Space-to-Workspace Grant used for admission. The
grant is not managed from the Workspaces page and does not change Workspace
ownership.

Cloud authorizes each Thread operation and assignment using Space membership, Workspace ownership/grants, Thread state, logical Worker readiness, and scheduling policy. Workspace independently enforces local permissions, readiness, concurrency, deadlines, cancellation, and process cleanup.

Assignment execution uses one canonical permission vocabulary across Cloud,
Workspace Runtime Protocol, Workspace, and Engine admission:

- `repository:read`
- `repository:write`
- `shell:execute`
- `network:use`

Cloud intersects only the permissions allowed by the requester's Space member rights
with `workspace_space_grants.allowed_permissions_json`, then applies the
request's read-only Step policy. Cloud does not pretend to know the local
Worker permission set. Workspace compares the exact permission IDs in the
assignment snapshot against the installed Worker's local permission ceiling;
unknown names are rejected. Space access policy values such as `view`,
`discuss`, and `execute` are a separate vocabulary and are not assignment
execution permissions.

Workspace Grant writes validate permission IDs against that four-value set and
reject duplicates. Explicit Worker IDs must be bounded IDs of Workers already
inventoried on the granted Workspace; an empty list leaves all its Workers
eligible (with at most 64 explicit IDs). There is no Worker capability filter;
workflow enablement and access policy are Cloud-owned. Network policy accepts only
`deny_all` with no hosts or `allowlist` with unique, lowercase exact DNS
hostnames (no scheme, port, path, wildcard, or IP literal). Concurrency must be
an integer from 1 through 1024 and is intersected with the Worker and Cloud
limits. The default is one concurrent assignment.

Grant status transitions are `active` ↔ `suspended`; either state may become
`revoked` or `expired`. Revoked and expired Grants are terminal. The owner API
can activate, suspend, or use the dedicated revoke operation; expiration is
driven by `expiresAt` and is not a client-settable status.

## Tool Profile administration

Profile administration and publication use the dedicated `profiles:admin` and
`profiles:release:manage` permissions. Cloud resolves authorized operators
from its configured identity set. V9 Profile payloads are canonical,
schema-validated revisions; authorization, digest validation, and Workspace
admission protect them without a separate Profile signature.

## MCP server configuration

MCP servers (ADR-028) are installation-local data owned by the Workspace
Service. Only the Service decides which servers an execution may use: a server
must be consented (hash of the consent document, including its command and the
hash of every tool definition) and enabled for the Step. The Service then puts
the resolved launch (`name`, absolute `command`, `arguments`, `environment`) in
`execute.request.mcpServers`. Cloud never receives server commands, arguments,
environments or tokens; it sees only enablement state and tool-definition
hashes. The Engine treats `mcpServers` as already authorized, writes a private
per-execution config file, and deletes it afterwards. Environment values may
hold credentials; they are written only to that owner-only file and are never
logged, persisted in Engine state, or included in diagnostics.

## Step-up authentication and audit

Sensitive ownership or release operations may require a recent step-up proof tied to the current human session. Each route declares its required assurance and Cloud checks it before mutation. Security-relevant authorization, ownership, Workspace, Thread, and Profile changes are written to the applicable audit stream without credentials or secret payloads.

Workspace ownership reconciliation is a narrow migration recovery operation.
It requires a desktop session created by fresh browser approval and an exact
local Workspace/runtime identity that Cloud can prove belongs to the signed-in
user. Cloud may reconstruct a missing v8 installation binding only when there
is no competing active binding and no recorded Release. It never transfers an
active foreign-owned installation or uses email equality as ownership proof.
The reconciliation is audited; ambiguous state requires operator investigation.

## Secret boundary

`POST /api/desktop-auth/password` supports headless Workspace setup with an
existing account's email/password. It delegates verification and rate limiting
to the same Better Auth sign-in route as AX, refuses incomplete/MFA challenges,
then issues only a `syntila.desktop.management` session using the existing
single-use claim mechanism. Its temporary authentication cookie is not returned
to the caller and the temporary web session is signed out. Passwords are never
persisted by Workspace or Syntila application tables. Responses are no-store.
This does not transfer installation ownership or create a Profile Lab session;
normal ownership and registration checks still apply.

Provider credentials stay in the local provider CLI configuration. Runtime credentials are stored in the operating system secure store. Cloud persistence, assignment messages, diagnostics, audit records, and artifacts must not contain plaintext secrets.

## Space member rights v1

Space membership remains the boundary for reading. Owners retain all member
rights and control Space settings and every Thread. For other members, the
owner can set explicit permissions: Use Space AI for chat (`chat`), Use Space AI for work (`work`), and
Create threads (`manageOwnThreads`). The Members tab shows these in a checkbox grid;
only the owner can edit permissions, and the Owner badge appears beside the owner's name. Thread
lists show the creator's email below the title when that person is not the
Space owner. The current Thread creation identity is its immutable
creation-time `lead_user_id`; the API does not reassign this field.

The v1 rights map lives at `spaces.settings_json.memberPermissions[userId]`.
Missing maps preserve role defaults: collaborators have Chat, Work and Thread creation;
viewers can read; owners have all rights. Own Workers in Chat is available by default
and always available for all members rather than configurable in the Members grid. Workspace
attachment requires an explicit grant for non-owners; member invitations remain
owner-only.
Malformed stored overrides fail closed. Removing a member removes their override
and revokes their contributed Workspace Grants.

`PATCH /api/spaces/:id/members/:userId/permissions` accepts
`{ permissions: { chat, useOwnWorkers, work, manageOwnThreads } }`.
All four fields must be booleans; extra fields are rejected. `useOwnWorkers`
is stored and returned as false whenever `chat` is false, and a stored
override without it grants no own Workers. Owner rights
cannot be changed. Existing role presets remain available through the role
endpoint and reset the member's explicit rights to that preset. Space and
member read models include effective `permissions`. Ordinary Space responses
omit the internal member and invitation permission maps. General Space
settings writes cannot change the member or invitation permission maps.

Workflow enablement is configured on global/Space Workflows, together with its
selected Workspace. Only the Space owner may change Space workflow settings.
Submission and validation enforce the effective workflow enabled flag and the
requester's member rights. Dispatch continues to check current member rights,
Workspace grants, and accepted execution snapshots. Chat requires Chat permission.
Migration 0022 converts existing Space-wide Work denials to per-workflow disabled
flags and removes `settings.allowWork`; obsolete writes receive 400. History is
preserved, and accepted runs retain their execution evidence. Already-running
provider calls are not cancelled by a settings change.

Own Workers in Chat (`useOwnWorkers`) lets a member answer the Chat workflow
with a Worker from a Workspace they own, instead of a Worker from the Space's
Workflow Workspace. Only Workers the member owns qualify; Workers other people
share with them (Person Grants, the Space Workspace) do not. On first use the
member's Workspace receives a read-only Space grant (`repository:read`, one
concurrent assignment) made by that member and audited as
`chat.own_workspace.authorized`. Admission rejects a non-Chat workflow, a
missing right, or a Worker the requester does not own. Dispatch rejects any
Chat candidate outside the Space Workflow Workspace unless the requester owns
it and currently holds the right (`own_worker_not_allowed`), so other members
can never run someone's personal Worker. The Worker sees only the
conversation context the Thread provides and runs in its owner's Workspace,
not in Space files. The assignment snapshot records `workerOwnerUserId` and
`workerOwnerName`; `workerOwnerName` is set only when the Worker ran outside
the Space Workflow Workspace. Conversation turns expose it, and the message
header shows it after the Worker name; responses from the Space Workspace show
no owner.

Own Thread management permits creation and management of Threads created by
that member, while the owner can manage every Thread. Destructive cleanup follows
the narrower shared-history policy below, independently of `manageOwnThreads`. It does not grant rights
to execute Chat or Work. Composer choices configure the next turn and do not
change historical execution metadata.

Workspace attachment is an explicit Workspace grant, separate from member
permissions. Workspace ownership is checked independently of Space rights;
Workspace owners must explicitly authorize a contribution when they are not
the Space owner. The Space owner or Workspace owner may revoke the attachment;
only the Workspace owner manages the Workspace itself.
The Space UI replaces the technical grant-permission editor with the Work
switch. New UI attachments allow repository reads/writes and shell execution,
subject to the Workspace's local Worker permission ceiling. Existing grant
restrictions and network policy still apply. Work rights provide the execution
ceiling, intersected with the grant and the request's read-only Step policy.

Invitation management is owner-only; there is no member-level invitation right
to delegate or persist. `POST /api/spaces/:id/invitations`
accepts the same optional `permissions` object. Invitation rights are
snapshotted in `settings.invitationPermissions[invitationId]` and intersected
with the owner's current rights at acceptance. Revoked ownership prevents
acceptance. Members cannot list, create, resend, or revoke pending invitations.
Invitation acceptance cannot rewrite an existing member's rights.

Migration 0025 removes obsolete `inviteMembers` snapshots from persisted Space
settings. Deploy Cloud before the updated AX app. Older clients cannot bypass
the owner-only invitation boundary or current member rights.

## Private notes

A note is visible to and changeable by its owner only. Space owners, other
members, and Workers cannot read it, and notes are never added to Thread or
Worker context. A Thread note needs Thread view access when it is read or
saved through the Thread; the owner keeps the note in My Notes after the
Thread is deleted or they lose access to it. See
[AX server state: Private notes](../architecture/AX_SERVER_STATE.md#private-notes).

## People

An accepted Space membership automatically establishes symmetric user-ID relationships with co-members. Pending invitations never grant People visibility. Authenticated `GET /api/people` exposes only established peers and supports no global search or caller-supplied owner. Known-Person invitations require both a caller-owned relationship and Space invitation rights; removal from a Space preserves the relationship but removes that Space authorization. See [People v1](PEOPLE_V1.md).

Known-Person Space invitations persist `invitee_user_id`; recipient inbox access and Accept/Reject compare the authenticated user ID, independent of email changes. Email-addressed invitations remain available for new collaborators and bind identity on acceptance. Invitation selection grants no membership or consent. Both People and Space entry points use the same permission-checked invitation endpoint. Migration 0024 adds a unique pending Space/recipient identity constraint without changing accepted memberships.


## Shared Thread history and lifecycle

Every member with Thread view access may archive/restore a Thread and reset its
AI context, including viewers. These actions do not grant Chat, Work, rename,
or configuration rights. Archived Threads are readable; restore is required
before new Chat messages or AI requests. In-flight work may finish.

The author or Space owner may remove a human Discussion message. Removal keeps
its ID, original author, timestamp, and timeline position, replacing its body
with an attributed removal notice and clearing attachment/reference links.
`eventType: "message.removed"` identifies this protected placeholder. Members
cannot edit or individually delete placeholders or other system notices.
AI request/answer records remain execution evidence rather than editable Chat.

Archive, restore, and AI reset append attributed, timestamped Discussion notices
(`thread.archived`, `thread.restored`, `ai.context_reset`). Notice text is human
readable; clients use the optional `eventType` field for protected rendering.
This is an additive read-model extension; existing message kinds are unchanged.

Clear Conversation and Delete Thread require the Space owner, or the immutable
Thread creator when no other human has ever sent a message or submitted a
request. AI answers, reading, membership, and lifecycle notices do not count as
another person's contribution. A durable `has_other_contributions` flag survives
message removal and Conversation clearing. Thread reads return the caller's
`canDestroy` capability; server authorization and an atomic mutation guard are
still authoritative. Active requests must be cancelled before clear/delete.
Clear removes Discussion, canonical Conversations, requests, diagnostics and
Worker continuity, then inserts exactly one `conversation.cleared` notice.
A later clear removes the previous notice. Thread identity/settings/status and
work files remain. Delete removes the Thread and its history.

Reset AI context remains available when history capacity is exhausted and while
requests are active. It requires no model call. It advances the canonical history
floor, AI history cutoff, session generation, and AI context generation. New
requests capture the new context generation. Late responses from earlier
generations stay readable but are excluded from future AI bootstrap context;
subsequent steps of superseded requests use isolated sessions. Reset does not
undo work or replenish provider/billing quotas. Context-limit retry also records
an attributed reset notice and preserves its existing latest-answer retry policy.

Migration `0087_thread_history_permissions.sql` adds notice/contribution/context
generation fields and insertion triggers. Historical hard-deleted contributions
cannot be reconstructed, so all preexisting Threads conservatively require the
Space owner for clear/delete. Newly created Threads use the precise creator
exception. Apply the migration before deploying the updated Cloud routes; older
clients may display notices as ordinary messages, while Cloud still protects
them from edits/deletion. No local Workspace or provider credential migration
is required. Personal hide/unhide is outside this feature.
