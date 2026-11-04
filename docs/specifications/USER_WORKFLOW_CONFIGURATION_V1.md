# User Workflow Configuration v1

Global per-user preferences are separate from Syntila-owned Workflow definitions
and Space/Thread authored context. Preferences
are keyed by authenticated user and stable Workflow ID, not definition version.
The newest definition validates step IDs. Definition graphs, prompts, labels,
and signed Profile execution metadata are never copied into preferences.

```json
{
  "schemaVersion": 1,
  "workflowId": "full_cycle",
  "enabled": true,
  "defaults": { "worker": "worker-id", "model": "model-id", "effort": "high" },
  "stepOverrides": { "verify": { "worker": "review-worker-id" } }
}
```

Model and effort omissions mean `Auto`; a step override may omit Worker to
inherit the workflow's explicit Worker. Workflow defaults must name a Worker
when enabled. An absent row means enabled with no Worker configured and `Auto`
model/effort, so it is unresolved until the user selects a Worker. Writes
normalize null and `Auto` to omission for model/effort and remove empty step
overrides. `Auto` in a step clears that step's model or effort choice and
inherits the default; it does not bypass an explicit Worker. Effort strings are
Profile-owned, not a fixed provider enum. Worker IDs identify user-owned
inventory entries.

## Authenticated human API

- `GET /api/user/workflow-configurations`: versioned sparse collection.
- `GET /api/user/workflow-configurations/:workflowId`: sparse collection scoped
  to one known Workflow (empty when unconfigured).
- `PUT /api/user/workflow-configurations/:workflowId`: replace one complete v1
  preference; returns `{ configuration }`.
- `DELETE /api/user/workflow-configurations/:workflowId`: reset; returns the
  default v1 configuration and deletes the row.

No user ID is accepted in the payload. Existing human authentication and cookie
mutation origin protection apply. Model/effort validation uses owned Worker
inventory and published, non-revoked Profile execution options. Every enabled
Workflow step must resolve to an explicit owned Worker. Offline readiness does
not invalidate preferences. Unchanged selections are retained
when inventory/Profile metadata is unavailable; execution must still perform
its own current authorization, grant, capability and readiness checks.

## Resolution boundary and rollout

Core exposes a pure definition + user-default + step-override resolver; it does
not pick a runnable Worker or inject provider defaults. AX has typed immutable
configuration models and a dedicated typed data-source interface implemented by
its authenticated API client. Phase 2 adds the global Workflows page and session query cache; see
[AX server state](../architecture/AX_SERVER_STATE.md#global-workflows-page).
Phase 4 applies this resolution at preflight and request acceptance. Disabled
Workflows cannot execute. Thread bindings no longer provide execution defaults.

Space overrides now sit between owner-global defaults and execution. A transient
composer selection may overlay the same sparse selection type for a one-step
request only; it is validated at acceptance and is never saved to Space or user
preferences. Thread-level preferences remain a future layer. Effective
configurations are frozen at acceptance; historical requests are never rewritten
when preferences change.

Apply additive v8 migration `0018_user_workflow_configurations.sql` before
serving these endpoints. It creates a user-owned table with cascading user
removal and a composite primary key. No existing configuration or Work Request
is migrated or rewritten; this is part of the v8 baseline, with no legacy API.

## Workflow editor

Selecting a card or Edit opens the Workflow editor on the global Workflows page.
Default execution contains Worker, model, and effort pickers. Advanced contains
a numbered list of the definition's fixed steps in definition order. Each row
summarizes inheritance or its explicit execution choices, and expands to
Execution controls: Use workflow defaults or Override. Model and effort `Auto`
values inherit the corresponding workflow defaults, with the inherited value
shown. Worker selection is explicit; a step override may omit Worker only to
inherit the workflow's explicit Worker.
An effort-only override does not copy the default Worker or model into storage.
Empty overrides are omitted rather than recording an override-mode flag.

Changing Worker clears explicit model and effort choices; changing model clears
explicit effort. Inherited fields remain inherited. Options and validation use
owned Worker/Profile metadata, including model-specific supported efforts.
Missing Workers and incompatible effective defaults or step choices are
identified inline and block Save; a default change may require correcting a
step override.
Cloud independently validates each write through the existing v1 API.

Offline readiness is separate from Profile execution-option compatibility. Offline Workers
remain selectable and labeled. Missing saved Workers and model/effort choices
remain visible instead of silently reverting to `Auto` or another Worker. Unchanged selections
with missing inventory or Profile metadata can be preserved, matching the Cloud
intent rule. Removing a step override can also restore already-saved workflow
defaults while metadata is unavailable; changed combinations require supported
metadata. The open editor
observes the shared Worker query, so inventory refresh revalidates the draft.

Reset restores the whole workflow through the authenticated reset API. Reset
step to inherited values and Use workflow defaults remove only that step's local
override; Save commits the resulting sparse configuration. Cancel discards the
local draft. Failed writes retain the draft and expose the API error for explicit
retry. Mutations update the shared preference cache without a follow-up GET.

Advanced execution preferences are exposed only in this editor. Users cannot
create Workflows, add/remove/reorder steps, edit system prompts, or alter internal
contracts. Syntila owns the definitions and structure; users own execution
preferences. Phase 3 introduces no schema or API migration.

## Execution resolution and snapshots

Cloud resolves the Space owner’s global defaults plus a shared Space workflow override
for both validation and submission, regardless of the requester.
Defaults are overlaid by sparse step overrides. Every step must name an explicit
Worker from the selected Space Workflow Workspace inventory; Cloud's internal
execution grant, Thread permissions, Profile execution options, readiness, and
Workspace eligibility rules still apply. Resolution verifies every configured
Worker in one Workspace before freezing the request. A missing, offline, or
incompatible Worker fails admission; it is never silently replaced. `Auto`
model and effort remain null, meaning the signed Profile/provider CLI default;
Syntila does not guess a provider model or effort.

Every new accepted Work Request stores `stepExecutionConfigs` keyed by definition
step kind in its immutable v1 snapshot. Each value records schema version, Worker
ID, Profile ID/release version, nullable model/effort, and Workflow ID/version.
Manual WorkflowRun/StepRun read models expose these same accepted snapshots as
`executionConfigs`/`executionConfig`, including queued steps before dispatch.
Worker turns retain actual invocation evidence separately. Graph executions use
the same accepted Work Request step snapshot and scheduler admission boundary.
Retries and request replays use the frozen snapshot, not current preferences.
The scheduler requires the recorded Worker and Profile release and uses recorded
model/effort even when null. Profile changes or revocation fail admission rather
than substituting a release. Existing historical requests remain unchanged; no
missing Profile identity is reconstructed from today's inventory.

The composer displays Space execution choices and allows a one-step request to
edit Worker, model, and effort locally. AX sends that transient selection with
the authored request, attachments, Workflow identity, and idempotency key;
Cloud validates it and includes the resolved values in the immutable snapshot
without changing saved preferences. Multi-step Workflows do not accept this
override. Unconfigured Workflows and reset leave the Worker unresolved with
`Auto` model and effort defaults, so execution remains blocked until a Worker is
selected, with no legacy Thread binding or persistent composer fallback. Thread settings retain authored
instructions and initial Workflow selection, but no execution configuration or
implicit Worker scheduling writes. Generic Settings remains account/application
configuration. Workflows is the authoritative global execution editor.

## Migration and cleanup

Apply `0018_user_workflow_configurations.sql` and
`0019_thread_execution_configuration_cleanup.sql` before updated AX/Cloud.
0018 creates user-owned sparse preferences. 0019 removes obsolete execution
choices/labels/fallbacks from mutable Thread configuration, preserving authored
Thread and step instructions and initial Workflow selection. Shared Thread choices
cannot be assigned unambiguously to one user, so they are not copied into global
preferences. With no saved user preferences, execution has no configured Worker
and cannot execute until one is selected.

Accepted request snapshots and historical runs are never migrated or backfilled.
The snapshot's versioned execution data remains immutable. Old API clients trying
to write Thread execution fields receive 400. Invalid or multi-step
`executionSelection` payloads receive 400; ship AX and Cloud together. There is
no compatibility alias or runtime fallback.
Historical read-only fields remain evidence, not a source for new execution defaults.

## Ownership and future extensions

```text
Workflow Definition
       ↓
User Workflow Configuration (Space owner)
       ↓
Space Workflow Configuration
       ↓
Scope default Workflow selection
       ↓
Execution Resolution
       ↓
WorkflowRun
       ↓
StepRun
```

```text
User Workflow Configuration
       ↓
Space Workflow Configuration
       ↓
Thread preference       [future]
       ↓
Composer override       [one-step, current request only]
```

The composer override is transient and is never persisted in Workflow
Configuration. A future Thread preference may overlay the same sparse selection
type before it, without schema redesign or historical rewrites. See
[ADR-019](../decisions/ADR-019-per-user-workflow-execution-configuration.md).

Each user and Space also has one sparse default Workflow selection. It is stored
separately from execution fields, defaults to `chat`, and is never copied into a
Workflow Definition. `GET/PUT /api/user/workflow-default` and
`GET/PUT /api/spaces/:spaceId/workflow-default` read or update the selection.
Only enabled Workflows can be selected. Chat is always enabled and is the
automatic fallback when the selected Workflow is disabled or a Workspace change
resets the scope.

## Focused validation

Core resolver tests cover sparse Auto/default inheritance and fixed step overrides.
Cloud tests cover authenticated ownership/isolation, invalid capability combinations,
reset, unavailable Worker intent, runtime admission, immutable Run/Step snapshots,
Profile pinning, rejection of obsolete writes, and cleanup migration invariants.
AX tests cover Profile model/effort filtering, invalid combinations, editing/saving,
reset/inherit, inventory changes, navigation, session isolation, query deduplication,
cache reuse, and global preference projection into retained Thread controls.
Component validation is AX + Cloud and direct shared contracts. No Workspace,
Profile Lab, Public Site, native packaging, or full-repository run is required.

## Shared Space configuration

Every Space has a Workflows tab. Its initial effective configuration inherits the
Space owner's global settings, ensuring all members and Threads share execution
choices. `GET /api/spaces/:spaceId/workflow-configurations[/:workflowId]` returns
these effective preferences. Membership is required to read; only the owner may
PUT a complete workflow override or DELETE it to restore global inheritance.
Payloads reuse the versioned execution preference shape and reject ownership fields.

Editing starts with the effective global values. Save forks that entire workflow
for the Space; omitted model/effort fields then mean `Auto`, and step fields
inherit the Space workflow defaults. Other workflows continue inheriting global
settings. A Space override may preserve an explicit Worker or remain unresolved
until one is selected. Reset deletes the override and returns current owner
defaults.
Space updates never modify user preferences or another Space. Global changes affect
inherited workflows, while saved Space overrides remain independent.

Migration `0020_space_workflow_configurations.sql` adds a Space-owned table with
cascading deletion and a composite Space/workflow key. It performs no eager copying
or historical backfill. Apply it before updated Cloud/AX. Execution resolves from active Space-granted inventory using existing
Thread permissions and readiness checks; saved explicit Workers still require
a valid Space grant in the selected Workspace; request authorization still uses the actual requester. All new
runs snapshot their resolved choices as before. No Thread execution override exists.

Migration `0028_workflow_default_selection.sql` adds separate user and Space
default-selection rows and normalizes any legacy Chat rows to enabled. It does
not copy workflow definitions or execution selections.

## Workspace selection

Global Workflows and the Space Workflows tab select one Workspace before editing
or executing workflows. Only its Workers and signed Profile execution options are
available to the editor, write validation, and runtime Worker resolution. An
explicit Worker outside that Workspace is rejected. Offline Workers in the
selected Workspace retain their saved choices; execution still requires readiness.
With no selection, new execution is unavailable until a Workspace is chosen.
No Workspace is guessed during migration.

The authenticated APIs are `GET/PUT /api/user/workflow-workspace` and
`GET/PUT /api/spaces/:spaceId/workflow-workspace`. GET returns
`{ workspaceId, inherited, workspaces: [{ id, name }] }`. PUT accepts
`{ workspaceId, confirmReset: true }`; a Space may instead send
`{ inherit: true, confirmReset: true }`. Unknown fields and foreign/revoked
Workspaces are rejected. Only a Space owner may change its selection; members
may read it. Selection choices are the settings owner's Workspaces; members see only the
selected Workspace metadata.

A Workspace change requires a visible confirmation and an explicit API reset
confirmation. Settings and preference deletion commit in one D1 batch. All
workflows become enabled with no configured Worker, `Auto` model/effort, and
inherited steps; each must be assigned a Worker before execution.
Global changes also reset overrides in owned Spaces that inherit the Workspace;
Spaces with an explicit Workspace keep their configurations. A Space selection
forks the entire scope, suppressing global workflow preferences so explicit
Space defaults are independent. Resetting a workflow in this scope clears its
Worker and uses `Auto` for model and effort; returning to the global Workspace deletes the scope setting and
restores current global preferences for all workflows.

Selecting an owned Workspace authorizes its execution in the owner's Space,
including inherited Spaces and newly created Spaces. Existing grant restrictions,
suspension, expiration, member rights, and admission checks remain authoritative.
Switching does not revoke historical grants or alter accepted runs. Grant creation
is audited. Space updates notify other clients through existing collaboration
events. No new execution or provider protocol is introduced.

Apply `0022_workflow_workspace_selection.sql` with AX and Cloud together. It
adds separate user/Space Workspace settings with cascading scope deletion and
nullable Workspace references. It replaces existing `allowWork: false` with
disabled per-workflow Work configurations while preserving saved selections;
Chat remains unchanged. It removes `allowWork` from Space settings, and obsolete
writes receive 400. The Space Workspaces tab and its GET/POST connection API are
removed. Read-only grant metadata now uses
`GET /api/spaces/:spaceId/workflow-workspace/grants`; canonical Workspace grant
management APIs remain for execution authorization. Historical snapshots are
unchanged; no production migration is performed by implementing this feature.

## Catalog refresh and selection intent

Saved global/Space Workflow preferences and transient Work-tab selections express
Worker/model/effort intent. Their optional `catalogRevision` records the observed
catalog; it is not an execution pin. Fresh catalog changes do not invalidate a
still-supported selection or mutate saved settings, inherited overrides, or
restored composer state. Removed models or unsupported efforts remain visible
and require an explicit replacement; stale or unavailable catalogs still block
new execution. The existing unchanged-unavailable preference preservation rule
continues to apply to saved settings.

Cloud validates effective choices against current authorized Worker capabilities
and records that catalog revision in each accepted request binding. Acceptance
rechecks the pinned bindings before persistence. Scheduler dispatch and retries
continue enforcing exact catalog revision matches. The Engine additionally
enforces Service-owned provider-catalog pins; static capabilities remain bound
by the admitted Profile. An accepted request is never rebased onto a newer
catalog. Auto values remain user intent
rather than being materialized into saved preferences.

No D1 migration or protocol version change is required. Existing observed
revisions in preferences and local view state remain readable; historical
request/assignment snapshots retain their original immutable revisions.

## Space Workflows page removed from AX (2026-10-15)

AX no longer offers a Space-level Workflows page or Space menu item;
`/spaces/:id/workflows` opens the Space. Workflow, Worker, model and effort for
a Thread come from the owner's default configuration when the Thread is
created or its Workflow is changed, and the Thread's last choices (active tab,
Workflow, Worker, model, effort) are restored from local per-user Thread view
state. Cloud still resolves and honors any existing Space override rows and
Space Workflow Workspace selections; their endpoints, tables and runtime
precedence are scheduled for removal separately, because a Space's Workspace
grant depends on that selection.

## Workflows move into Workspace tabs (2026-10-17)

The standalone Workflows page and menu item are removed; `/workflows` opens
Workspaces. The Workspaces page shows one tab per registered Workspace (Thread
tab style) with its machine info, Workers and Workflows.

### Per-Workspace storage (migration `0072`)

`user_workflow_configurations` is keyed `(user_id, workspace_id, workflow_id)`
and `user_workflow_defaults` `(user_id, workspace_id)`. Existing rows move to the
user's selected Workspace; rows of users without one are dropped (they had
nothing to attach to).

- `GET|PUT|DELETE /api/user/workflow-configurations[/:id]` and
  `GET|PUT /api/user/workflow-default` accept `?workspaceId=`. Without it they
  address the selected Workspace. The Workspace must be owned by the caller and
  not revoked (404 otherwise); Workers must belong to the addressed Workspace.
  The configuration list response includes `workspaceId`.
- The selected Workspace (`user_workflow_settings`) now only decides which
  Workspace new Work runs on. Changing it no longer deletes configuration.
  `confirmReset` is required only when Spaces inheriting the global Workspace
  have their own overrides, which are still reset because they reference the
  previous Workspace's Workers.
- Space resolution reads the owner's rows for the Space's effective Workspace
  (its own selection, otherwise the global one), including Spaces with their own
  Workspace.
- AX: each Workspace tab edits its own workflows through
  `AxWorkflowConfigurations.forWorkspace`; the tab shows "Active" or a
  "Use this Workspace" action for the selected Workspace.

### Space Workspace selector

The Space page header shows a Workspace control backed by the existing
`/api/spaces/:id/workflow-workspace` endpoint. The owner chooses "Default
Workspace" (follow the owner's selected Workspace) or one of their Workspaces;
other members see the current Workspace read-only. Changing it asks for
confirmation and resets that Space's own workflow overrides and default (they
reference the previous Workspace's Workers); the chosen Workspace is authorized
for the Space. Threads then use that Workspace's Workers and workflows.

### Member access (migration `0073`)

`workspace_member_access(workspace_id, policy_json)` optionally limits what
invited Space members can run on a Workspace. No row means no limit. A row holds
`{schemaVersion:1, workers:{<workerId>:{models:[…]|null, efforts:[…]|null}}}`:
a listed Worker is shared, a null list shares every model or effort, and an
unlisted Worker is not shared.

- `GET|PUT /api/workspaces/:id/member-access` is owner-only (404 otherwise).
  `PUT {restricted:false}` removes the row; `PUT {restricted:true, workers}`
  replaces it, and every Worker must belong to the Workspace.
- Enforcement is in `resolveWorkflowExecutionBindings`, so it covers request
  validation and creation. For a requester who does not own the Space's
  effective Workspace, each step's Worker, model and effort (configured or
  composer override) must be shared; otherwise the request fails with 403.
  When models or efforts are limited, Auto is not shared, because the Worker
  could pick an unshared value. The owner configures an explicit model/effort in
  the workflow, or members choose one.
- AX: each Workspace tab has an owner-only "Member access" section (limit switch,
  per-Worker share, model and effort chips; Save access).

### Member choices

`GET /api/workers?includeShared=true` (sent by AX) returns the caller's own
Workers plus, for Spaces they belong to but do not own, the Workers of the
Workspace those Spaces run on (the Space's own selection, otherwise the owner's
global one; revoked Workspaces excluded). With a member-access policy only the
listed Workers appear, and their `executionOptions` are narrowed to the shared
models and efforts (custom models are disabled when models are limited). Shared
rows hide the owner's machine details (`providerToolName`, `providerToolVersion`,
`engineVersion`) and the unused legacy `modelOptions`. Without
`includeShared` the endpoint is unchanged, so Cloud's own configuration
validation never sees other owners' Workers.

The Thread composer therefore offers members exactly the choices the server will
accept; the check in `resolveWorkflowExecutionBindings` remains the authority.

## Space workflow editing removed from AX (2026-10-17)

AX no longer has any screen that writes workflow settings for a Space: workflows
are edited per Workspace in its tab, and a Space follows the Workspace it runs
on. The Dart client therefore dropped its Space write paths
(`saveSpaceWorkflowConfiguration`, `resetSpaceWorkflowConfiguration`,
`saveSpaceWorkflowDefault`), and a Space-scoped `AxWorkflowConfigurations` is
read-only. `WorkflowsPage` now requires a `workspaceId` and only renders inside
a Workspace tab (no standalone title, Workspace picker or per-Space reset).
Cloud's Space override routes and tables are unchanged and still resolve for
existing data; removing them is a separate, breaking Cloud change.

### Default policy, per-person overrides and Person Grants (ADR-020)

Migrations `0074`-`0076`. The Member access policy above is the Workspace
**default**. Optional fields and rules added on top of it:

- `mode`: `chat` (read-only Workflows), `work` (also file changes) or
  `work+shell` (also commands). Absent means no ceiling beyond Space role
  permissions, so policies saved earlier behave as before. The AX editor starts
  new limits at `chat`. Enforced per Workflow step in
  `resolveWorkflowExecutionBindings` using the step's required capabilities.
- Per-person override (`workspace_member_overrides`): replaces the default for
  one person, never merges. Owner-only
  `GET|PUT|DELETE /api/workspaces/:id/member-access/people/:userId`
  (`DELETE` resets to the default).
- Workspace invitations (`workspace_invitations`) and Person Grants
  (`workspace_person_grants`). A Workspace owner invites by email
  (`GET|POST /api/workspaces/:id/invitations`,
  `POST .../invitations/:invitationId/revoke`); the invitee lists
  (`GET /api/workspace-invitations`) and accepts
  (`POST /api/workspace-invitations/:id/accept`). Invitations last 7 days, are
  single use, need the signed-in email to match, and are capped at 20 pending
  per Workspace. Accepting creates only the grant and never a people
  relationship. With no default policy the person starts as chat-only with no
  Workers shared.
- A Space owner may select a Workspace lent to them; the user-level default
  still accepts only owned Workspaces. The Space grant is created by the lender,
  capped by the borrower's mode, with concurrency 1, and never changes the
  lender's Worker scheduling. On a lent Workspace every requester except its
  owner needs their own active grant, so other members of the borrower's Space
  are refused with 403 (strict, non-transferable, no re-lending).
- `POST /api/workspaces/:id/person-grants/:userId/revoke` ends a grant, revokes
  the borrower's Space grants on that Workspace and is audited. Steps already
  running finish; new and queued dispatch stops.
- `PUT /api/workspaces/:id/person-grants/:userId/quota` sets
  `{maxConcurrentRequests: 1-10}` (default 1), enforced at admission with 429.
- `GET /api/workspaces/:id/people-with-access` is the owner-only list with mode,
  quota and usage-only figures (requests, approximate seconds, Worker ids, last
  used); the borrower's content is never returned.

Not implemented: a total run-time quota and a per-grant Work Root (the Work Root
is local to the Workspace Service). AX screens for per-person overrides,
invitations and the access list are pending; the API above is complete.

### Space Workspace selection in AX

There is no account-wide default Workspace for Spaces. A Space uses only the
Workspace explicitly chosen for it, or none (it cannot run Work until one is
chosen). Attaching a Workspace is a permission decision, so it is never
inherited or selected silently.

- The Create Space dialog has a Workspace field that starts at "No Workspace".
  If the user owns exactly one Workspace, a one-click "Use <name>" button picks
  it; nothing is preselected. Cloud refuses a Workspace the user does not own
  or that is not shared with them.
- Changing a Space's Workspace is an owner-only action with confirmation.
- A revoked or unavailable Workspace shows "unavailable"; there is no automatic
  fallback to another machine.
- The account-level Workspace selection only decides whose account workflow
  templates are displayed. It grants no Space access.
- Migration `0103` gave every existing Space an explicit Workspace (the one it
  effectively used if still usable, otherwise none).

Not yet built: a "Mac was set up again - reconnect these Spaces?" prompt after
a Workspace reinstall. Until then the owner re-selects the Workspace per Space.
