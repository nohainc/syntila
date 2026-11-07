# ADR-029: Direct Spaces and Personal Connections

**Status:** Accepted; **Date:** 2026-11-06

Extends ADR-008 and ADR-020. Complements People v1.

## Context

Syntila currently organizes collaboration around Spaces (now categorized as Group Spaces) where multiple users collaborate across Threads. People (`/api/people`) currently maintains an automatic private directory of known collaborators derived symmetrically from shared Space memberships (`people_relationships`).

To expand Syntila into an AI-powered messenger, users must be able to establish one-to-one direct conversations. When two users connect, they need a dedicated, shared communication context supporting both human messaging and AI workflows without creating redundant, fragmented spaces or granting unintended local machine access.

## Decision

### 1. Two Space kinds: `group` and `direct`

Syntila formalizes two distinct kinds of Spaces:
- **`group` (default):** Multi-user collaboration Spaces with roles (`owner`, `collaborator`, `viewer`), member management, invitations, and configurable member permissions.
- **`direct`:** Dedicated one-to-one Spaces established between two approved personal connections.

### 2. Distinction between Collaborators and Personal Connections

Collaboration in a Group Space does not imply a personal messaging relationship:
- **Known Collaborator:** A user with whom the caller shares at least one Group Space (stored in `people_relationships`). A collaborator is visible in People and eligible for direct personal invitation, but does not automatically have a Direct Space.
- **Pending Personal Invitation:** An explicit, reciprocal invitation to establish a direct connection.
- **Approved Personal Connection:** Two users who have explicitly agreed to connect. Each approved connection pair has exactly one Direct Space.

Group Space membership never automatically creates Direct Spaces between co-members.

### 3. Direct Space Cardinality and Participants

- **One Space per Unordered User Pair:** Exactly one Direct Space exists for any distinct pair `{userA, userB}`.
- **Strict Two-Participant Limit:** Direct Spaces have exactly two participants. Adding additional members is strictly forbidden.
- **No Type Conversion:** A Direct Space cannot be converted into a Group Space, nor can a Group Space be converted into a Direct Space.

### 4. Technical Ownership and Symmetric Permissions

To preserve database schema and foreign key compatibility without rewriting the baseline table definitions:
- The `spaces.owner_user_id` column is retained and populated with the original inviter's user ID (or a deterministic participant ID).
- In `space_memberships`, one user has role `owner` and the other has role `collaborator`.
- **Symmetric Messaging and Workflow Rights:** Technical ownership does not confer unequal messaging rights. In application and authorization logic, both participants have identical, symmetric rights:
  - Both participants can read, post Discussion messages, and run Chat with their own Workers.
  - Both participants can create and manage additional Threads.
  - Both participants can reset AI conversation context and archive/restore Threads.
- **Restricted Owner Administrative Powers:** Owner-level powers that could unilaterally disrupt the other participant are disabled for Direct Spaces:
  - Adding members is forbidden (`403 Forbidden`).
  - Kicking or changing the role of the other member is forbidden.
  - Converting the Space kind or reordering/renaming the Space globally is restricted.
  - Deleting the default General Thread is forbidden.
  - Destructive clearing or deletion of shared Threads created with mutual participation is prohibited unless initiated via mutual agreement or explicit contact removal semantics.

### 5. Thread lifecycle

- **Creation:** Connection approval retrieves or creates the unique Direct Space without creating a Thread. Either participant may create Threads.
- **Existing General Threads:** Previously created default General Threads are preserved and cannot be deleted by either participant.

### 6. Reuse of Existing Thread, Discussion, Work, and AI Models

Direct Spaces do not invent parallel chat or agent infrastructure:
- Human messaging uses standard `discussion_messages` and real-time collaboration streams.
- AI interactions use standard `conversations`, `work_requests`, `workflow_tasks`, `runs`, and `worker_assignments`.
- Context truncation, generation fencing, and AI history cutoffs apply identically as defined in ADR-009 and ADR-012.

### 7. Per-Viewer Dynamic Display Identity

Direct Spaces present a personalized identity depending on who is viewing the Space:
- When viewed by User A, the Space title is User B's current profile `displayName`, and the avatar is User B's profile `avatarUrl`.
- When viewed by User B, the Space title is User A's current profile `displayName`, and the avatar is User A's profile `avatarUrl`.
- Underlying persistence and authorization strictly use immutable user IDs (`userId`), never mutable display names or emails.

### 8. Execution and Workspace Boundaries

- Direct Space membership does not grant access to the other participant's local Workspace or execution environments.
- Personal Spaces support only Chat, using a Worker owned by the requester. Person Grants and another participant's Workspace do not confer Worker access in a personal Space.
- Local provider credentials, API keys, and file trees remain safely bounded within their respective owners' Workspaces.

### 9. Removal, Retention, and Deletion Semantics

- **Hide Conversation:** A local per-user state change (or local archive flag) that removes the Direct Space from that user's active sidebar without deleting messages, revoking connections, or affecting the other participant's view. Incoming messages restore visibility.
- **Remove Contact:** An explicit termination of the personal connection.
  - Breaking a connection does not modify or delete shared Group Spaces.
  - The Direct Space is archived or transitioned to read-only/disconnected status, preventing new message submission while preserving historical audit and legal retention.
- **Account Deletion:**
  - If a participant deletes their account, database referential integrity (`spaces.owner_user_id ON DELETE RESTRICT`) must not deadlock account deletion.
  - Deletion of an account cascades the personal relationship and either cleans up or tombstones the Direct Space (e.g. archiving the Space and replacing the deleted user with a deactivated placeholder), preserving data integrity for the remaining participant without leaving dangling foreign keys.

### 10. Sidebar Navigation Structure

The application sidebar introduces a first-class **Personal** section positioned above or distinct from **Spaces**:
- **Personal:** Lists Direct Spaces labeled with the contact's name and avatar, containing Threads created by participants and any existing General Thread.
- **Spaces:** Lists Group Spaces and their respective Threads.

### 11. Migration, Full Acceptance, and Rollout Policy

- **Existing People Migration:** Existing `people_relationships` entries are preserved as collaborators (`status = 'collaborator'`). Syntila does **not** automatically generate Direct Spaces for pre-existing collaborator pairs. Direct Spaces are provisioned exclusively upon explicit mutual consent via personal invitation acceptance.
- **Group Space Integrity:** All existing Spaces retain `kind = 'group'` by default. Group Space permissions, membership caps (ADR-024), thread hierarchies, and workspace grants remain strictly isolated and unaffected across personal connection lifecycle events (connecting, disconnecting, blocking, or hiding).
- **End-to-End Reliability & Concurrency:**
  - Racing personal invitations between the same pair resolve to a single canonical connection with mutual consent.
  - Acceptance retries are idempotent and consistently return the identical Direct Space ID.
  - Reconnection after disconnection restores the existing Direct Space rather than creating orphan duplicates.
- **Performance & Scalability:** Read models (`/api/home`, `/api/people`, `/api/spaces`) batch direct space state resolution and member counting, avoiding N+1 queries.

## Consequences

- Direct messaging is fully integrated into the existing Syntila core domain with minimal schema complexity.
- No parallel chat protocol or separate database tables are needed for 1:1 discussions.
- Group Spaces remain completely untouched and retain their existing ownership, membership limits (ADR-024), and permission rules.
