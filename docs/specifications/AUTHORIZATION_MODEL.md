# Authorization Model

**Status:** Current security policy for Syntila, Cloud, Worker ownership, Threads, and Tool Profiles.

Cloud resolves the authenticated Better Auth session to an active Syntila user. It derives Space roles from `space_memberships`; it does not trust client-supplied organization or Worker membership claims.

## Space access

Syntila defines two Space kinds: `group` (default) and `direct`.

In `group` Spaces, roles are `owner`, `collaborator`, and `viewer`. Their permission sets are defined in `packages/security/src/index.ts`:

- Owners can read, write, and manage their Space, start Work, and control Runs.
- Collaborators default to reading, Chat, Work, and management of their own Threads. Owners can refine these rights individually.
- Viewers can read Space content.

Cloud checks membership at the resource boundary. A missing, suspended, or deactivated user is denied.

## Direct Spaces and personal connection authorization

A `direct` Space represents a dedicated one-to-one conversation between two approved personal connections (ADR-029).

### 1. Invariants and cardinality
- Exactly one Direct Space exists for any distinct unordered user pair `{userA, userB}`.
- Exactly two participants are permitted. Adding a third member is strictly forbidden (`403 Forbidden`).
- Direct Spaces cannot be converted into Group Spaces, nor can Group Spaces be converted into Direct Spaces.

### 2. Technical ownership vs. participant rights
- For database schema and referential integrity compatibility, `spaces.owner_user_id` is retained and records the inviter (or designated participant).
- Technical ownership does not confer unequal conversational ownership. Both participants have symmetric, equivalent rights:
  - Reading, posting Discussion messages, and participating in real-time updates.
  - Executing Chat using their own Workers; other workflows are unavailable.
  - Creating additional Threads, and managing/renaming Threads they created.
  - Resetting AI conversation context.
- Administrative powers typically reserved for Space owners are strictly restricted in Direct Spaces:
  - Adding a third member or sending Space invitations is rejected (`403 Forbidden`).
  - Changing participant roles or permissions through member APIs is rejected (`403 Forbidden`).
  - Member removal is rejected (`403 Forbidden`); ending the relationship uses the contact removal flow.
  - Either participant can delete the Direct Space and its shared history. The connection remains; opening it again creates a fresh Space.
  - Transferring Space ownership is rejected (`400 Bad Request`).
  - Converting the Space kind between `direct` and `group` is rejected (`400 Bad Request`).
  - Renaming the Direct Space or archiving it globally is rejected (`400 Bad Request`). Display title and avatar are dynamically resolved from the peer's profile.
  - Deleting another participant's discussion message is rejected (`403 Forbidden`); only the message author can delete their own messages.
  - Renaming, archiving, or managing custom Threads created by the other participant is rejected (`403 Forbidden`). Each participant can only manage custom Threads they created.
  - The default General Thread cannot be renamed or archived (`400 Bad Request`), nor deleted (`403 Forbidden`).

### 3. Thread lifecycle
- Acceptance of a personal invitation provisions or retrieves the unique Direct Space without creating a Thread. Either participant may create Threads.
- Existing default General Threads are preserved and cannot be deleted by either participant.
- Thread deletion and conversation clearing strictly enforce the contribution rule: a Thread can only be cleared or deleted if the user created the Thread and no other human has contributed (`has_other_contributions == 0`). These Thread restrictions do not prevent either participant from deleting the entire Direct Space and its shared history.

### 4. Worker and execution isolation
- Membership in a Direct Space does not grant access to the other participant's local Worker or file tree.
- Direct Spaces do not support Space-level Worker attachments; callers attempting to attach a Worker receive `403 Forbidden`.
- Workflows execute under existing isolation boundaries: requesters use their own Workers in Chat, which follows the `chat` right (Direct Spaces always allow it), or explicitly authorized Person Grants (ADR-020).
- Tool calls (`input.toolCall`) in a Direct Space require that the requester owns the target Worker.
- Local credentials, provider tokens, and filesystem paths remain protected within each participant's own environment.

### 5. Removal, retention, and account deletion
- **Hide conversation:** A per-user preference that hides the Direct Space from the active sidebar. The conversation remains intact and unread activity restores it to view.
- **Remove contact:** Terminates the personal connection and transitions the Direct Space to a frozen/archived read-only state:
  - Both participants retain read-only access to historical Threads, messages, and attachments for compliance and audit.
  - Submitting new Discussion messages, creating new Threads, or initiating new Work requests is rejected (`403 Forbidden: This personal conversation is disconnected and read-only`).
  - Existing Group Spaces remain unchanged.
- **Account deletion:** Cascades the personal connection relationship. To prevent foreign key constraint violations on `spaces.owner_user_id ON DELETE RESTRICT`, account deletion routines clean up or tombstone Direct Spaces where the deleting user is the technical owner, ensuring the deletion completes cleanly while preserving data integrity for the remaining participant.

### 6. Direct Space Permissions Matrix

Members can archive or restore their own view of a Direct Space or a Group
Space shared with them, including when their role is read-only. This changes
only their visibility and does not revoke membership or alter another member's
view. A Group Space owner's archive continues to apply to the whole Space.
Direct Space visibility is restored when a new message arrives or the Space is
opened. Personal visibility uses the existing per-user Space state table.

| Operation | Alice (Technical Owner) | Bob (Participant) | Charlie (Unrelated User) | Former Connection (Disconnected) |
| :--- | :---: | :---: | :---: | :---: |
| **Discover Space (List Spaces)** | Allowed | Allowed | Denied (isolated) | Allowed (read-only) |
| **Fetch Direct Space & Threads** | Allowed | Allowed | Denied (`404`/`403`) | Allowed (read-only) |
| **Read Discussion & AI turns** | Allowed | Allowed | Denied (`404`/`403`) | Allowed (read-only) |
| **Send Discussion Message** | Allowed | Allowed | Denied (`404`/`403`) | Denied (`403 read-only`) |
| **Create Custom Thread** | Allowed | Allowed | Denied (`404`/`403`) | Denied (`403 read-only`) |
| **Manage/Rename Own Thread** | Allowed | Allowed | Denied (`404`/`403`) | Denied (`403 read-only`) |
| **Manage/Rename Peer's Thread** | Denied (`403`) | Denied (`403`) | Denied (`404`/`403`) | Denied (`403`) |
| **Rename General Thread** | Denied (`400`) | Denied (`400`) | Denied (`404`/`403`) | Denied (`400`) |
| **Archive General Thread** | Denied (`400`) | Denied (`400`) | Denied (`404`/`403`) | Denied (`400`) |
| **Delete General Thread** | Denied (`403`) | Denied (`403`) | Denied (`404`/`403`) | Denied (`403`) |
| **Delete Own Thread (no other inputs)** | Allowed | Allowed | Denied (`404`/`403`) | Denied (`403`) |
| **Delete Peer's Thread** | Denied (`403`) | Denied (`403`) | Denied (`404`/`403`) | Denied (`403`) |
| **Delete Own Discussion Message** | Allowed | Allowed | Denied (`404`/`403`) | Denied (`403`) |
| **Delete Peer's Discussion Message** | Denied (`403`) | Denied (`403`) | Denied (`404`/`403`) | Denied (`403`) |
| **Invite 3rd Member** | Denied (`403`) | Denied (`403`) | Denied (`404`/`403`) | Denied (`403`) |
| **Remove / Kick Peer** | Denied (`403`) | Denied (`403`) | Denied (`404`/`403`) | Denied (`403`) |
| **Change Peer's Role** | Denied (`403`) | Denied (`403`) | Denied (`404`/`403`) | Denied (`403`) |
| **Delete Direct Space** | Allowed | Allowed | Denied (`404`/`403`) | Allowed for a member |
| **Convert Space to Group** | Denied (`400`) | Denied (`400`) | Denied (`404`/`403`) | Denied (`400`) |
| **Transfer Ownership** | Denied (`400`) | Denied (`400`) | Denied (`404`/`403`) | Denied (`400`) |
| **Global Space Rename** | Denied (`400`) | Denied (`400`) | Denied (`404`/`403`) | Denied (`400`) |
| **Global Space Archive** | Denied (`400`) | Denied (`400`) | Denied (`404`/`403`) | Denied (`400`) |
| **Attach Space Worker** | Denied (`403`) | Denied (`403`) | Denied (`404`/`403`) | Denied (`403`) |
| **Tool Call on Own Worker** | Allowed | Allowed | Denied (`404`/`403`) | Denied (`403`) |
| **Tool Call on Peer's Worker** | Denied (`403`) | Denied (`403`) | Denied (`404`/`403`) | Denied (`403`) |

## Worker execution access

A Worker has one Cloud owner. The owner manages the Worker runtime. Space
execution access is selected by the Space owner in Workflows; Cloud materializes
and validates the internal Space-to-Worker Grant used for admission. The
grant is not managed from the Workers page and does not change Worker
ownership.

Cloud authorizes each Thread operation and assignment using Space membership, Worker ownership/grants, Thread state, logical Worker readiness, and scheduling policy. Worker independently enforces local permissions, readiness, concurrency, deadlines, cancellation, and process cleanup.

Assignment execution uses one canonical permission vocabulary across Cloud,
Worker Runtime Protocol, Worker, and Engine admission:

- `repository:read`
- `repository:write`
- `shell:execute`
- `network:use`

Cloud derives permissions from the requester’s current Space rights and the
request’s read-only Step policy. Cloud does not pretend to know the local
Worker permission set. Worker compares the exact permission IDs in the
assignment snapshot against the installed Worker's local permission ceiling;
unknown names are rejected. Space access policy values such as `view`,
`discuss`, and `execute` are a separate vocabulary and are not assignment
execution permissions.

Worker Grant writes validate permission IDs against that four-value set and
reject duplicates. Explicit Worker IDs must be bounded IDs of Workers already
inventoried on the granted Worker; an empty list leaves all its Workers
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
schema-validated revisions; authorization, digest validation, and Worker
admission protect them without a separate Profile signature.

## MCP server configuration

MCP servers (ADR-028) are installation-local data owned by the Worker
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

Sensitive ownership or release operations may require a recent step-up proof tied to the current human session. Each route declares its required assurance and Cloud checks it before mutation. Security-relevant authorization, ownership, Worker, Thread, and Profile changes are written to the applicable audit stream without credentials or secret payloads.

Worker ownership reconciliation is a narrow migration recovery operation.
It requires a desktop session created by fresh browser approval and an exact
local Worker/runtime identity that Cloud can prove belongs to the signed-in
user. Cloud may reconstruct a missing installation binding only when there
is no competing active binding and no recorded Release. It never transfers an
active foreign-owned installation or uses email equality as ownership proof.
The reconciliation is audited; ambiguous state requires operator investigation.

## Secret boundary

`POST /api/desktop-auth/password` supports headless Worker setup with an
existing account's email/password. It delegates verification and rate limiting
to the same Better Auth sign-in route as AX, refuses incomplete/MFA challenges,
then issues only a `syntila.desktop.management` session using the existing
single-use claim mechanism. Its temporary authentication cookie is not returned
to the caller and the temporary web session is signed out. Passwords are never
persisted by Worker or Syntila application tables. Responses are no-store.
This does not transfer installation ownership or create a Profile Lab session;
normal ownership and registration checks still apply.

Provider credentials stay in the local provider CLI configuration. Runtime credentials are stored in the operating system secure store. Cloud persistence, assignment messages, diagnostics, audit records, and artifacts must not contain plaintext secrets.

## Space member rights v1

Space membership remains the boundary for reading. Owners retain all member
rights and control Space settings and every Thread. For other members, the
owner can set explicit permissions: Use Space AI for chat (`chat`), Use Space AI for work (`work`), and
Create threads (`manageOwnThreads`). `chat` and `work` govern asking the AI
only; writing plain messages to other people in a Thread never needs them
(Thread `discuss` access checks membership and the Thread access policy). The Members tab shows these in a checkbox grid;
only the owner can edit permissions, and the Owner badge appears beside the owner's name. Thread
lists show the creator's email below the title when that person is not the
Space owner. The current Thread creation identity is its immutable
creation-time `lead_user_id`; the API does not reassign this field.

The v1 rights map lives at `spaces.settings_json.memberPermissions[userId]`.
Missing maps preserve role defaults: collaborators have Chat, Work and Thread creation;
viewers can read; owners have all rights. Own Workers in Chat is not a granted right:
it is derived from `chat` (see "Three-right contract" below). Worker
attachment requires an explicit grant for non-owners; member invitations remain
owner-only.
Malformed stored overrides fail closed. Removing a member removes their override
and revokes their contributed Worker Grants.

`PATCH /api/spaces/:id/members/:userId/permissions` accepts
`{ permissions: { chat, useOwnWorkers, work, manageOwnThreads } }`.
`chat`, `work` and `manageOwnThreads` must be booleans; unknown fields are
rejected. `useOwnWorkers` is optional and, if sent, must be a boolean but is
ignored; responses always return it equal to `chat`. Owner rights
cannot be changed. Existing role presets remain available through the role
endpoint and reset the member's explicit rights to that preset. Space and
member read models include effective `permissions`. Ordinary Space responses
omit the internal member and invitation permission maps. General Space
settings writes cannot change the member or invitation permission maps.

Workflow enablement is configured on global/Space Workflows, together with its
selected Worker. Only the Space owner may change Space workflow settings.
Submission and validation enforce the effective workflow enabled flag and the
requester's member rights. Dispatch continues to check current member rights,
Worker grants, and accepted execution snapshots. Chat requires Chat permission.
Space-wide Work denial is expressed as per-workflow disabled flags; the former
`settings.allowWork` is gone and writes to it receive 400. History is
preserved, and accepted runs retain their execution evidence. Already-running
provider calls are not cancelled by a settings change.

Worker selection is authorized against current ownership, sharing, Space rights and readiness. A request names its Worker explicitly; authorization is rechecked before dispatch. See [ADR-035](../decisions/ADR-035-worker-targeted-execution.md) and [ADR-042](../decisions/ADR-042-worker-space-member-access.md).

Own Thread management permits creation and management of Threads created by
that member, while the owner can manage every Thread. Destructive cleanup follows
the narrower shared-history policy below, independently of `manageOwnThreads`. It does not grant rights
to execute Chat or Work. Composer choices configure the next turn and do not
change historical execution metadata.

Worker attachment is an explicit Worker grant, separate from member
permissions. Worker ownership is checked independently of Space rights;
Worker owners must explicitly authorize a contribution when they are not
the Space owner. The Space owner or Worker owner may revoke the attachment;
only the Worker owner manages the Worker itself.
The Space UI replaces the technical grant-permission editor with the Work
switch. New UI attachments allow repository reads/writes and shell execution,
subject to the Worker's local Worker permission ceiling. Existing grant
restrictions and network policy still apply. Work rights provide the execution
ceiling, intersected with the grant and the request's read-only Step policy.

Invitation management is owner-only; there is no member-level invitation right
to delegate or persist. `POST /api/spaces/:id/invitations`
accepts the same optional `permissions` object. Invitation rights are
snapshotted in `settings.invitationPermissions[invitationId]` and intersected
with the owner's current rights at acceptance. Revoked ownership prevents
acceptance. Members cannot list, create, resend, or revoke pending invitations.
Invitation acceptance cannot rewrite an existing member's rights.

Persisted Space settings carry no `inviteMembers` snapshot, so clients cannot bypass
the owner-only invitation boundary or current member rights.

## Three-right contract

Owners grant exactly three rights to non-owner members. Defaults for a stored-override-free
member: collaborator = all three; viewer = none (read-only); owner = all, not editable;
direct-Space participants = collaborator defaults.

| Right | Semantics | Enforcement points |
|---|---|---|
| `chat` | Run the Chat workflow. Includes answering with a Worker from a Worker the member owns (the "personal Worker"). Plain messages never need it. | `requireWorkflowPermission`, scheduler `rights.chat`, thread `execute` |
| `work` | Run non-Chat workflows; sets the execution ceiling, intersected with Worker grant and Step policy. **Includes `chat`**: the effective and stored `chat` is `chat \|\| work`, and the Members grid and invitation dialog grant Chat with Work and remove Work with Chat. There is no Work-only member. | `requireWorkflowPermission`, scheduler `rights.work` |
| `manageOwnThreads` | Create Threads and manage Threads the member leads. Never grants Chat or Work. | `requireSpaceRight`, `canManageThread` |

**Personal Worker behavior.** `useOwnWorkers` is no longer an independent right. The
effective value is `chat`, computed in `spaceMemberPermissions` and
`validateMemberPermissions`, and the stored value is never read. Everything else is
unchanged: only Workers the requester owns qualify, only for Chat, with a read-only
`repository:read` Space grant created on first use, and the scheduler still rejects other
members' personal Workers (`own_worker_not_allowed`). The member is never granted the
Space's Workflow Worker by this derivation.

**Data conversion.** No data rewrite is required for correctness. Stored
`memberPermissions[userId].useOwnWorkers` is ignored on read and may stay until a later
cleanup migration drops it. Cases: (1) `chat:true`, `useOwnWorkers:true` or absent: no
change in effect (absent previously denied own Workers and now allows them, as the
documented default intended); (2) `chat:false`: unchanged, no own Workers; (3) `chat:true`,
`useOwnWorkers:false` explicit: this widens access. The Members grid never exposed the
field, so these rows can only come from direct API writes; the cleanup migration must list
them (audit event) before dropping the field, and the owner should be told. Malformed
overrides still fail closed to no rights.

**Client compatibility.** Cloud keeps returning four fields in `permissions` and accepts
the four-field PATCH body (older apps send `useOwnWorkers` from state and hide it in the
grid); clients may send three fields. The field is dropped from responses only after old
clients age out.

## Private notes

A note is visible to and changeable by its owner only. Space owners, other
members, and Workers cannot read it, and notes are never added to Thread or
Worker context. A Thread note needs Thread view access when it is read or
saved through the Thread; the owner keeps the note in My Notes after the
Thread is deleted or they lose access to it. See
[AX server state: Private notes](../architecture/AX_SERVER_STATE.md#sidebar-activity-and-personal-data).

## People

An accepted Space membership automatically establishes symmetric user-ID relationships with co-members. Pending invitations never grant People visibility. Authenticated `GET /api/people` exposes only established peers and supports no global search or caller-supplied owner. Known-Person invitations require both a caller-owned relationship and Space invitation rights; removal from a Space preserves the relationship but removes that Space authorization. See [People v1](PEOPLE_V1.md).

Known-Person Space invitations persist `invitee_user_id`; recipient inbox access and Accept/Reject compare the authenticated user ID, independent of email changes. Email-addressed invitations remain available for new collaborators and bind identity on acceptance. Invitation selection grants no membership or consent. Both People and Space entry points use the same permission-checked invitation endpoint.


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

The schema carries notice, contribution and context-generation fields with
insertion triggers. Historical hard-deleted contributions
cannot be reconstructed, so all preexisting Threads conservatively require the
Space owner for clear/delete. Newly created Threads use the precise creator
exception. Older clients may display notices as ordinary messages, while Cloud still
protects them from edits and deletion. No local Worker or provider credential migration
is required. Personal hide/unhide is outside this feature.

## Direct Space authorization

Direct Spaces (`spaces.kind = 'direct'`) represent approved 1:1 personal connections and enforce distinct authorization semantics:
- **Strict Two-Participant Invariant:** Direct Spaces are permanently fixed to exactly two members. Member invitations, third-party additions, role mutations, ownership transfers, and converting the Space to a group are rejected (`403 Forbidden`).
- **Symmetric Conversation & Execution Rights:** Both participants can create custom Threads, post messages, and run Chat with Workers in their own Workers. Personal Spaces do not permit other workflows or another participant's Workers.
- **Protected General Thread & Destructive Actions:** The default `General` Thread cannot be deleted by either participant. Either participant may delete the Direct Space itself via `DELETE /api/spaces/:id`, removing its shared history.
- **Worker Isolation:** Direct Space participation never grants access to the peer's personal Worker or AI credentials. Workflows execute only on Workers explicitly owned by the requesting member or granted via explicit Person Grants.
- **Contact Removal & Blocking:** Disconnecting freezes the Direct Space into a read-only state, preventing new direct messages or AI runs until reconnected. Blocking (`POST /api/people/blocks/:userId`) halts messaging and AI execution bidirectionally.
- **Account Deletion Ownership Transfer:** Deleting an account transfers technical ownership of Direct Spaces to the active surviving participant, preserving thread history without orphan foreign keys.

## Space member rights (three-right contract)

Owners grant exactly three rights per member, stored under `settings.memberPermissions[userId]` and, for pending invitations, `settings.invitationPermissions[invitationId]`:

| Right | Default (owner / collaborator / viewer) | Enforcement |
| --- | --- | --- |
| `chat` | yes / yes / no | Start Chat runs (`run.start`); run Chat on the member's own Workers outside the Space Workflow Worker. |
| `work` | yes / yes / no | Start Workflow runs on the Space Workflow Worker (`run.start`). |
| `manageOwnThreads` | yes / yes / no | Create and manage the member's own Threads (`spaces:write`). |

- `spaces:write` needs any right; `run.start` needs `chat` or `work`; read is inherent in membership. Owners hold all rights and cannot be overridden; invitation management, `runs:control` and `spaces:manage` are owner-only. Direct Spaces ignore stored overrides and use collaborator defaults.
- Stored values count only when strictly `true`; absent or malformed values grant nothing. A member with no override gets role defaults. Invitation acceptance intersects the snapshot with the inviter's current rights.
- `useOwnWorkers` is derived from `chat`, never stored or read from storage. Cloud still tolerates it in write bodies (ignored) so older clients keep working; Cloud responses may still include it for them.
- The legacy key is absent from both snapshot maps. Previously independent `useOwnWorkers: false` records no longer restrict members who hold `chat`; the only access change is that those members can use their own Workers.
