# Multi-Worker Conversation Continuity v1

**Current execution configuration:** [ADR-019](../decisions/ADR-019-per-user-workflow-execution-configuration.md)
and [User Workflow Configuration v1](USER_WORKFLOW_CONFIGURATION_V1.md) supersede
historical phases describing Thread execution bindings and next-turn overrides.
The composer retains its layout as a display of Space preferences. One-step
requests may send a transient `executionSelection` for the current request;
Cloud validates and snapshots it without changing saved settings. Thread
execution writes remain removed, and Thread preference is future work.
Historical phase notes below describe completed iterations, not current API aliases.

**Status:** implemented through Phase 30, including legacy-assumption cleanup, the continuity regression matrix, context/revision evidence, concurrency guards and execution boundaries.
**Boundary:** Syntila Core and Human Product Protocol. **Contract version:** 1.

Space → Thread → Conversation → Work Requests is the product ownership
model for current manual AI interactions. A Conversation identifies the workflow;
a Workflow defines execution, while bindings select the Worker, model and effort.
Human team Discussion remains separate.

## Domain model and initial definitions

`Conversation` has `id`, `threadId`, `workflowId`, `workflowVersion`,
`conversationRevision`, `contextRevision`, `createdAt`, and `updatedAt`.
Identity, Thread ownership and Workflow version are immutable.

`WorkflowDefinition` has `id`, `type`, `version`, `capabilities`,
`configurationSchema`, and `execution` (a pinned execution Workflow ID/version).
Definitions live in provider-independent Core. Capabilities are the union of the
pinned graph's required Step capabilities. The configuration schema describes
optional string `workerId`, `model`, and `reasoningEffort` choices and disallows
other properties. Choices are still stored and validated through existing
Thread bindings; Phase 1 does not add a configuration-write endpoint or
duplicate that state.

| Product Workflow | Type/version | Execution Workflow | Binding |
| --- | --- | --- | --- |
| `chat` | `manual`, v1 | `chat:v1` | `chat` |
| `work` | `manual`, v1 | `direct:v2` | `direct` |

Product definition and execution graph versions are separate. New execution
graphs must not silently change existing product definitions. Work's stable
execution ID remains `direct`; snapshots, retries and AX catalog IDs are preserved.

Future graph/custom workflows can use existing Task/dependency/Run infrastructure.
No new graph IDs, custom editor, provider driver, or single-invocation-per-request
assumption is introduced. Existing multi-step workflows remain executable but do
not yet acquire Conversations. Historical `direct:v1` requests remain unassociated.

## Creation and revisions

There is one implicit Conversation per Thread, shared by every manual
Workflow (Chat and Work). The first eligible Chat/Work request creates it
lazily. Its ID is `conversation-` plus SHA-256 of the JSON array `[threadId]`;
it contains no provider handle, and its `workflow_id` records the Workflow that
opened it. Threads that already had per-workflow Conversations keep their
oldest one (by `created_at`, then `id`) as canonical; later requests from any
Workflow continue it, and history of the other legacy Conversation is not
merged. Empty Threads return no Conversations until a request is accepted. No
explicit create/reset/rename/delete operation exists in this phase.

Acceptance atomically stores the Work Request, creates/increments its Conversation,
stores an immutable association with the acceptance revision, and commits the Run,
audit and optional idempotency receipt in the same D1 batch.

`conversationRevision` counts accepted Work Requests, including requests that
later fail or are cancelled. Provider progress/results do not increment it.
Validation failure or a rolled-back batch changes nothing. Idempotent replay and
Step retry do not create new associations or revisions. Concurrent new submissions
receive distinct revisions through the serialized database transaction.

`contextRevision` starts and remains at zero in Phase 1. It reserves the revision
of materialized canonical context, not the count of provider messages. Both counters
are nonnegative and monotonic; context cannot exceed conversation revision.
Database guards prevent changing identity or existing associations.

## Human API

- `GET /api/threads/:id/conversations` returns
  `{ conversations: Conversation[] }` after Thread `view` authorization.
  No native provider data is included.
- Existing create-request routes still use execution IDs (`chat`/`direct`). They
  automatically associate current manual requests and return `conversationId`
  in `workRequest`. Optional `conversationId` must match the Thread and
  selected manual Workflow; other/incompatible IDs fail 400.
- Work history/detail reads include nullable `conversationId`. Historical
  unassociated requests return null. AX retains it in typed history/detail models
  and history copies.

Existing execution snapshots and catalog responses are unchanged. Historical
attribution still comes from immutable snapshots and execution evidence.

## Persistence and deployment

[PostgreSQL migrations](../../apps/backend/migrations/README.md)
is an additive feature migration on the fresh-start v8 baseline. Already-applied
migrations remain unchanged. It creates `conversations` and
`conversation_work_requests`, constraints and immutable/monotonic guards. It
neither rewrites historical requests nor backfills guessed context; it adds no
legacy architecture compatibility layer.

Apply the new ordered migration before deploying updated Cloud routes. Production
schema preflight checks both tables and definitions. Follow the existing
[production runbook](../operations/PRODUCTION_PROVISIONING.md) and
[persistence contract](PERSISTENCE.md). This implementation phase does not perform
a production migration or deployment.

## Continuity limits for later phases

Native provider session keys and local Engine state remain unchanged. Conversation
identity does not yet drive session-key derivation, replay history, transfer context,
summarize messages, or prove which revision a Worker consumed. Model/effort defaults
remain shared Thread binding settings; submitted selections remain immutable.
Switching Workers can resume an older local thread missing intervening turns,
as recorded in the Phase 0 audit.

Later phases must define canonical turns/context ownership, applied revisions,
provider catch-up, multiple Conversations, switching/reset semantics and concurrent
submission policy. Native handles and credentials remain Connect/Engine-owned;
Core remains provider-independent.

## Local native-session recovery

Native provider sessions are reconstructible local execution state. A missing
local mapping is recoverable when the assignment contains a validated canonical
bootstrap: the Engine starts a replacement native session with that bootstrap
and persists the new mapping only after the provider succeeds. A malformed local
mapping follows the same path after it is quarantined inside the Worker state
directory. Session identity, Worker/Profile scope, model compatibility, and
canonical bootstrap validation remain strict; an attribution mismatch or a
missing bootstrap is an actionable failure rather than permission to create an
empty context.

Early recovery and provider-independent execution failures carry bounded,
redacted private diagnostics with a stable stage name. User-facing assignment
messages remain generic, and prompts, responses, credentials, provider-native
handles, and local paths are excluded from the diagnostic channel.

## Workflow execution policy (Phase 2)

Every product Workflow definition includes `executionPolicy: WorkflowCapabilities`.
These product controls are distinct from Profile metadata and from
access/permission policy.

| Capability | Chat | Work | Meaning |
| --- | --- | --- | --- |
| `userSelectsWorker` | true | true | User may configure the logical Worker selection. |
| `userSelectsModel` | true | true | User may select a supported model or Default. |
| `userSelectsEffort` | true | true | User may choose an effort supported by the selected model/Profile. |
| `multiStep` | false | false | One request uses a graph with more than one Step when true. |
| `multiWorker` | false | false | The workflow supports distinct Worker selections for its Steps when true. |
| `automaticContinuation` | false | false | The executor advances downstream Steps automatically when true; this does not generate new user requests. |
| `requiresApprovalBetweenSteps` | false | false | The workflow has human approval gates between Steps when true. |

The execution catalog response adds the same policy plus `composerBindingId`.
Single-step entries identify their actual binding (`chat`, `direct`, or `research`).
Current multi-step graphs return null, retain per-Step settings, and advertise
`multiStep`, `multiWorker`, and `automaticContinuation` as true. Their selection
flags remain true because users can configure each Step's bindings; they have no
single global Worker/model/effort selection in the composer. Current graphs do not
require approval between Steps.

Core declares controls explicitly by versioned Workflow reference. Catalog
projection requires a declared policy and checks `multiStep` against the graph;
new Workflow releases cannot silently inherit a guessed policy. Future graph
workflows can declare different choice flags, but their execution implementation
must support any advertised continuation/approval behavior before publication.
Phase 2 does not introduce approval gates or new automatic execution behavior.

AX reads metadata instead of branching on Chat/Work IDs to select composer bindings
and controls. Model and effort choices are independently gated by policy; effort
choices additionally intersect the Profile's selected-model options. Worker
assignment/configuration affordances are only shown for a declared single binding
with user Worker selection enabled. Shared per-Step settings remain the configuration
surface for graphs. Missing metadata defaults to no selectable composer choices
until refreshed, rather than guessing control permissions.

The authenticated read-cache DTO preserves policy and binding metadata. AX strips
these presentation fields from its executable `snapshot` projection, and Cloud
never adds them to historical execution snapshots. Profile validation, Space
permissions, Worker readiness, and server authorization remain independently
required; UI flags cannot grant execution or filesystem authority.

Phase 2 adds no database migration. Deploy the updated catalog/API with AX so its
composer receives the metadata. Phase 1's pending migration requirement remains
unchanged; this phase performs no production deployment.

## Phase 3 — Next-turn defaults and accepted configuration

Current execution defaults come from User Workflow Configuration, resolved by Cloud
at acceptance. Each step freezes Worker, Profile identity/release, model, effort,
and Workflow identity/version in immutable `stepExecutionConfigs`. Manual history
also retains `turnExecutionConfig` as accepted evidence. Run/Step read models and
AX typed caches expose the same snapshot. Null model/effort means Profile/CLI
Default, not an inferred actual provider model. Assignment evidence records actual
invocation metadata. No new request reads old Thread bindings or composer overrides.

Scheduling honors the accepted Worker/Profile release and model/effort snapshot,
including explicit Default. If that Worker/Profile release becomes unavailable,
it cannot silently substitute a fallback Worker or another Profile release.
Multi-step workflows retain immutable per-Step resolved bindings rather than a
single global turn configuration. Historical requests without this optional field
retain their existing snapshots; no invented Profile metadata is backfilled.

Phase 3 adds no database migration or production deployment. Phase 1 migration
0010 is still required when releasing the Conversation API. Cross-worker canonical
history replay and session continuity remain future phases.

## Phase 4 — Worker-generated turns

`ConversationTurn` records one actual Worker assignment, rather than assuming one
user request is always one invocation. Each retry creates a distinct turn and
retains the preceding attempt. Queued requests with no assignment have no
Worker-generated turn yet. The existing request remains the user-facing submission.

Each turn stores immutable `id`, `conversationId`, execution `workflowId` and
`workflowVersion`, `userMessageId`, `workRequestId`, `assignmentId`, `taskId`,
`stepKind`, `workerId`, `workerTypeId`, snapshotted `workerDisplayName`, `profileId`,
`profileVersion` (signed release), nullable `modelId` and `effort`, nullable
`workerSessionId`, `baseContextRevision`, and `createdAt`. The execution Workflow
ID remains `direct` for Work; its Conversation retains product Workflow `work`.
Attribution comes from the assignment's authoritative selection evidence, not
current inventory, composer settings, or later Worker renames.

`status` progresses from queued to running on Connect acknowledgement (or an
explicit running assignment status), then completed, failed, or cancelled.
`startedAt` is the first Cloud-observed acceptance/running timestamp, not a claim
about the provider's exact process start. It remains null if no start was observed.
`completedAt` is the Cloud-recorded terminal timestamp; successful `resultText`
contains the recorded output text. Assignment transitions update the turn in the
same database operation, including failures outside the normal dispatcher path.
Repeated completion delivery cannot rewrite terminal evidence. Database guards
also prevent attribution edits, start-time changes, and lifecycle regressions.

`workerSessionId` is a SHA-256 reference over Connect, Worker, Profile definition
and the Syntila logical session key for durable assignments. It is
null for stateless assignments. It neither contains a native provider handle nor
proves that a CLI thread resumed successfully. Connect still owns the actual
session mapping, reset/generation state, and provider-native IDs. `baseContextRevision`
records the Conversation revision at assignment creation; it is currently zero
and does not certify canonical history ingestion. Session synchronization and
canonical context materialization remain later phases.

The new immutable `conversation_user_messages` record preserves the original
user text and author, using a deterministic message ID per associated Work Request.
It is separate from team Discussion. Existing associated request messages can be
seeded from their authoritative immutable input. Existing assignments are not
backfilled with guessed turns or session references.

Work history list/detail responses include ordered `turns: ConversationTurn[]`.
AX retains them in typed history, detail reconciliation, and authenticated read
cache. Response attribution/model/effort prefer the matching immutable turn;
requests without turn records retain existing historical evidence. Earlier attempts
remain available in request details. Null model/effort explicitly denotes Default,
not a fabricated resolved provider model. History responses cap each recorded
reply at the same 24,000-character presentation limit used by existing Step output.

[PostgreSQL migrations](../../apps/backend/migrations/README.md)
adds the message and turn tables, indexes, and atomic lifecycle/immutability
triggers. Apply 0010 and 0011 in order before deploying Cloud, then update AX.
Production preflight verifies both new table contracts and turn indexes. Current
Conversations cover manual Chat/Work; future graph Conversation association can
reuse the per-assignment/per-Step structure. No production migration or deployment
is performed by this implementation phase.


## Phase 5 — Canonical conversation history

Syntila owns an append-only history ledger for each Conversation. Provider CLI
sessions remain local execution state and are not the source of conversation
history. The version 1 entry contract covers `user_message`, `worker_response`,
`workflow_event`, `execution_event`, `artifact_event`, and `context_event`.

Each entry has a Conversation-local monotonic sequence, actor and source
references, event type, exact text when applicable, allowlisted metadata, source
occurrence time, and database recording time. History revision is the latest
sequence; it is distinct from accepted-request and materialized-context revisions.
User messages and successful worker responses retain their full recorded text.
Presentation APIs may still limit displayed replies to 24,000 characters; the
canonical history endpoint does not truncate them.

Database triggers record authoritative request acceptance and lifecycle changes,
Run/Task/turn execution events, completed worker replies, artifact creation/removal,
and context revision advances in the same transaction as their source mutation.
Repeated delivery cannot duplicate a user message or completed reply. Legitimate
repeated execution transitions, such as retrying a request, remain separate facts.
Volatile progress, raw logs, storage keys, credentials, and provider-native session
handles are excluded. An artifact event records a reference and selected metadata,
not a durable copy of the artifact's binary contents.

Entries cannot be edited or individually deleted. Source request/assignment
cleanup does not remove recorded facts. Deleting the owning Conversation is the
explicit retention boundary and cascades its history. Sequence reflects recording
order; `occurredAt` preserves source timing, including imported records.

`GET /api/threads/:id/conversations/:conversationId/history` requires
Thread view access and verifies Conversation ownership. It accepts `limit`
(1–100, default 50), `afterSequence` (default 0), and optional `throughSequence`.
The response contains `conversationId`, `historyRevision`, `throughSequence`,
ordered `entries`, and nullable `nextCursor`. Carry both cursor fields into each
subsequent request to retain a stable upper bound while new entries are appended.
Invalid or out-of-range cursors return 400; a Conversation outside the Thread
returns 404 after access checking. AX exposes typed history reads and retains its
existing timeline presentation, using canonical message/reply text where present.

[PostgreSQL migrations](../../apps/backend/migrations/README.md)
creates the ledger, indexes, immutability guards, and transactional event triggers.
It imports authoritative existing associated user messages and completed replies,
and labels other existing request/execution/artifact facts as snapshot imports.
It does not invent prior transitions or associate older unowned requests. Apply
0010, 0011, and 0012 in order before deploying Cloud; production schema preflight
checks the ledger contract. No remote migration or deployment was performed.

This phase establishes canonical storage and reads. It does not replay history
into workers, summarize context, synchronize native sessions, or advance context
revision automatically. Cross-worker catch-up requires a later context ingestion
implementation; possession of a native session is not evidence of synchronization.


## Phase 6 — Connect-owned Worker Sessions

`WorkerSession` is local execution state associated with a Conversation and a
logical Worker/Profile, rather than a model. Its version 1 record contains `id`,
`conversationId`, `workerId`, `profileId`, `profileVersion`, `nativeSessionId`,
`synchronizedContextRevision`, `status`, `lastModelId`, `lastEffort`, `createdAt`,
and `lastUsedAt`. Only Connect's Engine state stores native provider handles;
Cloud stores the opaque Syntila reference on turns, not a Worker Session table.
Last model/effort describe the last successful execution, and null denotes Default.

Cloud derives the opaque reference from Connect, logical Worker, Profile
definition, Conversation, and logical session key. Model, effort, and compatible
Profile release changes do not change it. The Thread Conversation maps to one
Thread session key shared by Chat and Work, so the same Worker/Profile resumes
its native session across Workflows.
A fresh-session retry changes the logical key and therefore the session generation.
Future multiple Conversations must allocate distinct logical keys; ownership
validation rejects using another Conversation's existing mapping.

Durable assignments carry optional `workerSession` metadata with nested
`schemaVersion: 1`, the Syntila session/Conversation/Worker IDs, and the dispatch
`baseContextRevision`. Connect validates ownership and translates this metadata
into Local Worker Protocol 4.0 execute frames. Native handles are forbidden in that
metadata. Stateless executions do not carry Worker Session state. The turn records
the frozen dispatch revision rather than a later mutable Conversation revision.

The local Engine file format advances to version 2 for Conversation executions.
Existing partitioned version 1 files resume under the same signed Profile format
compatibility rules and gain explicit ownership after successful use. Compatible
Profile releases may resume the same native session with different model/effort
arguments. Incompatible formats start a new native session and replace the mapping
only after success. Scope mismatches or invalid local records return a session
resume error; they cannot silently rewrite attribution. Native IDs remain bounded
and confined to the local state directory.

Context synchronization is not implemented in this phase. Sessions start with
`synchronizedContextRevision: 0`; successful native resume does not advance it.
The Engine refuses a nonzero target revision until canonical replay is implemented.
Statuses reserve `active` and `requires_synchronization` for this distinction.
Current Conversations retain context revision zero, so normal continuation works.

[PostgreSQL migrations](../../apps/backend/migrations/README.md)
updates atomic turn creation to retain the frozen dispatch revision. Apply after
0010–0012. Roll out the updated Connect and Engine together before enabling the
Cloud assignment extension: older strict Local Worker Protocol decoders reject
unknown execute fields. No provider CLI-specific executable, credentials service,
remote migration, or deployment is introduced.


## Phase 7 — Generic Worker execution options

The Human API Worker inventory includes optional `executionOptions` with
`schemaVersion: 1`. Core defines `WorkerExecutionOptions`, `WorkerModelOption`, and
`WorkerEffortOptions` independently of provider identity. AX parses a typed safe
projection, consumed by the Phase 8 composer. Existing `modelOptions` remains
available as an older-response fallback during that rollout.

The normalized contract contains:

- `models`: `supported`, `discovery`, `allowsCustomModel`, `allowedModelIds`,
  nullable `defaultModelId`, and catalog `options` with per-model effort choices.
- `modelSwitch.supported`: whether a compatible native session may change models.
- `effort`: supported values and nullable default for models without an override.

Values are arbitrary bounded Profile strings; workers need not share reasoning
levels. An explicit empty per-model effort list disables effort for that model.
When a known default model is declared, selection validation uses that model's
options for Default. Null model/effort preserves the provider-default request;
Syntila does not invent a resolved model or inject the advertised default.
Catalog entries are filtered by Profile allowlist and installed CLI version.
An unavailable default becomes null rather than silently selecting another model.

Profiles may add version 1 `model.executionOptions`:

~~~json
{
  "schemaVersion": 1,
  "discovery": "profile_catalog",
  "modelSwitchSupported": true,
  "effortSupported": true,
  "defaultModelId": null,
  "effortMapping": { "deep": "provider-native-level" }
}
~~~

The existing `model.catalog`, `supportedReasoningEfforts`, and
`defaultReasoningEffort` hold the advertised choices. The signed `effortMapping`
translates a selected generic value into the existing `{{reasoningEffort}}`
argument/stdin template. The original selected value stays in turn/session
metadata. Arguments, mappings, environment, credentials, and native session IDs
never enter the public execution-options DTO. TypeScript and Dart Profile
validators reject invalid versions, duplicate choices, unavailable defaults,
contradictory capability declarations, and mappings for undeclared effort values.
A declared effort capability also requires an invocation template.

For existing Profiles without the optional declaration, normalized choices use
existing catalog metadata and preserve established model/session selection
behavior. No catalog or effort values are invented when absent. New Profile
releases should declare capabilities explicitly and qualify their provider
behavior; fixture evidence does not qualify a live provider release.

Cloud validates model/effort choices against the selected published Profile in
readiness and request creation. The Engine independently rejects unsupported
model-specific effort before launching the CLI. A Profile that explicitly disables
model switching rejects a different model on an existing owned native session;
it does not silently discard history. A fresh-session operation remains explicit.
Compatible model switches and effort changes retain the Phase 6 session identity.

The current implemented discovery source is `profile_catalog`: options refresh
from the selected Profile release and observed installed CLI version. Live CLI
model discovery is not advertised or guessed. A future dynamic source needs a
signed, bounded discovery invocation and provider qualification before admission;
`dynamic` declarations are rejected until that execution path exists.

No D1 migration or protocol envelope change is needed. Existing published payloads
and starter templates remain unchanged. Deploy updated Connect/Engine validation
before publishing Profiles using the optional metadata, then update Cloud/AX for
the safe projection. No remote Profile publication or deployment was performed.


## Phase 8 — Dynamic next-turn composer

Manual single-binding workflows display the effective Worker, model, and effort
beside Send, below the message input. Attachment/history controls and the
Workflow selector use a separate utility row so execution choices remain visible
in the two-pane layout. Rows can scroll horizontally on narrower screens, while
Send stays visible. Preview has one Send control. Text input remains editable
while an execution is active; sending another request stays disabled until it ends.

Workflow policy determines which values are shown; graph workflows
retain their per-Step Work settings in the Workflows surface. The composer shows
the eligible Space Worker with its name, Connect label, and existing provider
icon or generic initial. Worker/model/effort selection remains in Workflows.
Selectors prefer the typed version 1 `executionOptions` projection from Phase 7.
Model selection is hidden when unsupported; effort follows the selected model's
capability and supported values. Older API responses retain the existing
Profile-owned `modelOptions` fallback. No global provider model list is introduced.

The composer reads the effective values from the Space Workflow configuration. It
does not write Worker/model/effort settings or create per-thread execution
overrides. Submission snapshots the resolved configuration at acceptance, and
later Space Workflow edits cannot mutate the submitted selection.

Displayed values update when the Space Workflow configuration or Worker catalog
changes. Cascading catalog reconciliation is described in Phase 9 below; Cloud and Engine
remain the authoritative validators for stale selections.

This is an AX-only UI/state change. No database migration or protocol change is
required; Phase 7's API projection is preferred, with the Profile catalog fallback
supporting coordinated rollout. No remote build or deployment was performed.


## Phase 9 — Cascading capability display

The composer reconciles the displayed model and effort against the selected
Worker's versioned execution options, including its model allowlist and
model-specific effort capabilities. Unsupported configured values are displayed
as unavailable until the Space Workflow is corrected. `Auto` remains an
absent override, allowing Profile/Engine defaults to apply.

Inventory refreshes reconcile the displayed Space Workflow values without
writing Thread settings or historical turns. Removed choices are reported as
unavailable and do not silently select a replacement.
Loading/error notifications without catalog data preserve the last usable catalog.
Worker picker callbacks recheck eligibility before accepting a selection.
Submission reads the same reconciled configuration as the composer.

This phase uses the existing Profile catalog projection, rather than live CLI
model discovery. Older API responses without typed execution options retain the
Phase 8 catalog fallback; Cloud/Engine validation remains authoritative for them.
No migration, public API change, or remote deployment is required. Workflows
remains the authoritative configuration surface.


## Phase 10 — Local Thread view state

Threads do not write Worker/model/effort preferences to Cloud. The Workflows
page remains the authoritative shared configuration surface, while the local
Thread view remembers its active tab, selected Workflow, and currently
available one-step Worker/model/effort choices so the page can reopen where the
user left it. Chat and Work draft text is also stored locally per authenticated
user and Thread; it is never included in Cloud state until the user submits it.
Unavailable or capability-incompatible selections are discarded during restore,
and attachments are not persisted. WorkflowRun and StepRun snapshots remain the
historical authority.


## Phase 11 — Conversation Router

Core exports the provider-independent `routeConversation` planner and versioned
`ConversationRoutePlan` contract. Input includes Conversation and Workflow
identities, the immutable turn selection, its frozen context revision, normalized
Worker execution options, runtime session capabilities, and Connect-owned session
metadata. Native provider handles are excluded from routing input and output.

The router returns one of:

| Action | Condition | Required context transfer |
| --- | --- | --- |
| CONTINUE_SESSION | Compatible native session synchronized to the turn revision | None |
| SYNC_AND_CONTINUE | Session is behind and incremental synchronization is supported | Delta from the synchronized revision to the frozen turn revision |
| BOOTSTRAP_SESSION | No session exists for this Conversation + Worker/Profile | Full context when revision is nonzero |
| RECONSTRUCT_SESSION | Missing native state, incompatible release, unsupported model switch, unavailable incremental sync, or only future-context sessions | Full context when revision is nonzero |
| STATELESS_EXECUTION | Turn requests stateless execution or durable sessions are unsupported | Full context when revision is nonzero |

Model handling is separate: unchanged model, KEEP_SESSION_WITH_NEW_MODEL, or
NEW_SESSION_FOR_MODEL. Effort changes alone do not split sessions. Default is an
unresolved selection; the router never guesses a provider model. A new session for
a model change requires reconstruction instead of silently abandoning history.

Matching sessions are scoped by Conversation, Worker, and Profile. Explicit release
compatibility comes from the local verified Profile adapter, not provider-name
branches. Compatible candidates are preferred; newest last-used timestamp wins,
with session ID as a deterministic tie-break. Sessions ahead of the frozen turn
revision are excluded. Invalid selections, inconsistent Workflow identities, and
corrupt context/session metadata fail closed. Routing does not mutate any input,
advance revisions, allocate sessions, or mark synchronization successful.

This phase implements the routing domain contract and decision tests. Runtime
execution remains on the Phase 6 path: there is no canonical context materializer,
Profile incremental synchronization transport, or reconstruction executor yet.
The new planner is not wired into dispatch; its full/delta requirements must be
satisfied by future execution orchestration before plans can run. Existing Engine
safeguards for nonzero context revisions and unsupported model switches remain.
No SQL migration, wire protocol change, Profile schema change, or deployment is
required. Session capability compatibility must be supplied by the Connect-local
adapter when execution integration is implemented.


## Phase 12 — Same Worker and model fast path

The generic CLI Engine continues an existing native session for the same
Conversation + Worker/Profile and model when the signed Profile declares format
compatibility and the local session is active and synchronized to the frozen turn
revision. Only the current request prompt is sent through the Profile's declared
prompt transport; native resume arguments supply the local provider handle.
Prior user messages and worker responses are not replayed. Effort arguments still
come from the immutable turn selection and signed Profile mapping.

The Engine now checks synchronized local state before rejecting a nonzero context
revision: an already synchronized compatible native session can continue. Missing,
stale, future-context, or inactive local state fails closed instead of executing
without required context. Legacy local records cannot certify nonzero context.
The store retains native identity across successful follow-ups and compatible
releases; failures do not certify synchronization or replace accepted turn data.

Execution tests use a provider fixture that requires the exact follow-up prompt,
same model argument, and original native resume handle. Separate store tests cover
exact, stale, future, and inactive context state. Current Conversations still use
context revision zero; this phase does not create a context materializer or
synchronization/reconstruction executor, and the Phase 11 Core planner remains a
separate planning contract. No migration, Profile schema, or protocol change is
required. Native session handles remain local to Connect/Engine.


## Phase 13 — Same Worker and model, different effort

Reasoning effort is a per-turn execution option transported by the signed Profile.
Changing it keeps the Conversation, logical Worker Session, and compatible native
session. Neither session keys nor model-switch checks include effort. The Engine
validates the new effort against the selected model, expands that value through
the Profile's effort mapping and invocation template, and records it as the local
session's last-used effort only after successful execution. Previous turn metadata
retains its original effort. Unsupported values are rejected rather than causing a
new Conversation or silently changing an accepted selection.

The acceptance fixture verifies Medium on an initial durable invocation and High
on the next invocation, with the same model and original native resume handle.
Cloud persistence tests verify identical Conversation/Worker Session attribution
and distinct immutable effort snapshots. The existing generic invocation path
already supports this behavior; this phase adds explicit regression coverage and
documents the invariant instead of introducing provider-specific session logic.

This applies to Profiles exposing effort as an invocation option for the selected
model. It does not infer effort support for other providers. Existing format and
context synchronization requirements still apply. No migration, Profile schema,
wire protocol change, or deployment is required.


## Phase 14 — Same Worker, different model

The generic Engine reads `modelSwitchSupported` from the verified signed Profile.
When supported, model changes use the existing compatible native handle with the
new model arguments. When unsupported, the Engine requires a canonical bootstrap
snapshot, omits resume arguments, and starts a new native session. Conversation
and logical Worker Session attribution remain unchanged; the replacement native
mapping and last model are saved only after successful execution. A failed new
invocation leaves the previous mapping intact. Later turns resume the replacement
session and send only their new request.

Cloud dispatch supplies a version 1 `bootstrap` inside `workerSession` only for
manual durable Conversations whose published Profile explicitly disables model
switching. The snapshot contains Syntila's canonical history through the sequence
immediately before the current user message, plus Conversation/context attribution.
It includes user/worker text and canonical event metadata, excluding the current
request and subsequent events. The Engine combines this historical-data snapshot
with the current request only when starting a native session; continuation ignores
it. Missing history boundaries, scope/revision mismatches, excessive history, or
oversized prompts fail closed. No content is silently truncated.

Snapshot limits are 1,000 canonical entries and 256 KiB of serialized text;
aggregate size is checked before fetching full rows. The combined prompt obeys the
existing 512 KiB Engine limit. This is bounded exact-history replay, not model
summarization, artifact-body loading, or incremental synchronization. Very long
Conversations require a future context materializer/compaction path. Context
revision remains zero until that subsystem exists; history sequence separately
freezes the bootstrap. Profiles permitting model switching keep their existing
fast path without bootstrap transfer.

This phase supersedes Phase 7's unsupported-model-switch rejection when canonical
bootstrap data is present, and implements the model replacement execution branch
planned in Phase 11. The Core router additionally requires full context for model
replacement at revision zero, since canonical message history can already exist.
The generic runtime still evaluates local Profile/session state independently of
the TypeScript Core planner; incremental synchronization remains unimplemented.

No SQL migration or signed Profile schema change is required. Local Worker
Protocol 4.0 and Connect assignment metadata gain an optional version 1
`workerSession.bootstrap` object (`conversationId`, `contextRevision`,
`throughSequence`, `text`). Native handles never leave local Engine storage.
Existing payloads continue to work with updated readers; strict older readers
reject the new field. Update Connect/Engine before enabling Cloud bootstrap
emission for Profiles disabling model switching. No remote deployment was done.


## Phase 15 — Different Worker continuity

Manual durable Conversations now send a scoped canonical context snapshot to every
selected Worker, independent of provider or model-switch capability. Connect
continues to own each Conversation + Worker/Profile session; the UI selects the
next Worker without handling bootstrap, synchronization, or native session IDs.

The runtime chooses:

- No compatible local session: bootstrap from full canonical context and execute
  the new request in a native session.
- Current local session: retain the native handle and send only the new request.
- Behind local session: retain the native handle, prepend only missed canonical
  context to the new request, and invoke the Profile's existing resume transport.

Synchronization and continuation happen in one provider invocation. No standalone
provider synchronization API, extra worker executable, or model invocation is
introduced. The ordinary signed Profile prompt transport carries canonical facts
as historical data. Existing model-switch reconstruction rules remain applicable.

The exact-history context version follows accepted Conversation request revisions.
Acceptance advances `contextRevision` with `conversationRevision`; dispatch freezes
`baseContextRevision` at the current request's revision minus one, not the latest
Conversation value. Snapshot `turnRevision` identifies the accepted current request.
A successful local execution records that revision as synchronized, because its
native session consumed prior context plus the new request and produced its reply.
Failures leave synchronized revisions and history watermarks unchanged.

History sequence remains a separate high-water mark. Cloud captures it at dispatch
and includes only earlier accepted requests, excluding current/future requests.
This includes earlier replies recorded after the current request was accepted.
Each snapshot entry carries its request's context revision (zero for unassociated
facts). Returning sessions receive entries from missed requests, newly recorded
artifact/context facts, and late replies from other Worker Sessions after their
history watermark. Revision-bookkeeping events do not trigger provider synchronization.
Own replies already produced inside the resumed native session
are excluded using canonical Worker Session attribution. No provider-native handle
is exchanged or reconstructed from natural-language claims.

`0014_exact_history_context.sql` initializes existing Conversation context revisions
from accepted request revisions and freezes implicit turn context to the original
request rather than current Conversation state. Historical turn snapshots are not
rewritten. Local Worker Session schema version 1 adds an optional
`synchronizedHistorySequence` counter (older records default to zero). Bootstrap
schema version 1 adds optional `turnRevision`; new Cloud snapshots always provide
it. Old payloads retain their former behavior; updated readers are required before
Cloud emits the new field. Legacy native records without Worker Session attribution
are reconstructed from canonical context instead of certifying unknown history.

Exact replay retains Phase 14 limits: 1,000 entries, 256 KiB snapshot, and the
existing combined prompt limit. Long-history compaction, artifact-body resolution,
provider token budgeting, and context synchronization through dedicated provider
APIs remain outside this phase. Stateless executions retain their existing policy.
The Core router remains the provider-independent planning contract; the Dart
runtime applies the same bootstrap/current/behind branches to verified local
Profile/session state. No UI workflow branches or remote deployment were added.


## Phase 16 — Provider-independent Context Engine

Core's `ContextEngine` produces version 1 `BootstrapContext`, `DeltaContext`, and
`StatelessContext` documents. Each includes scoped revisions, canonical evidence,
recent turns, and explicit structured context: objective, important decisions,
constraints, current state, open issues, artifact references, workflow state, and
summary. Facts carry revision and history-sequence provenance; cleared values
retain tombstones so deltas can communicate removals.

Cloud route modules assemble inputs from canonical history and the frozen Work
Request snapshot. Workflow state explicitly includes execution workflow identity
and version, Work Request identity/status, and step identity, kind, status, and
attempt. Space/Thread instructions seed constraints. Version 1 committed
`context.fact_updated` Syntila events materialize scalar or identified string
facts; worker prose never becomes authoritative decisions or summaries. Missing
facts remain empty. This phase adds no context-authoring endpoint or automatic
summary generation. Artifacts carry identity/digest, not bodies or storage secrets.

Durable execution uses full context for bootstrap and changed facts/evidence for
synchronization; Connect/Engine preserve structured workflow facts in deltas.
Stateless assignments carry optional `statelessContext` through the same generic
Profile prompt transport, without creating native durable sessions. Current
sessions retain the existing new-request-only fast path. Workflow state is a
dispatch-time snapshot, not a live status subscription.

Core owns assembly and validation, Cloud owns SQL reads, and Connect owns native
session synchronization. Snapshots reject out-of-bound revisions, unordered
history, more than 1,000 entries, or serialized documents over 256 KiB. Recent
turns are the last 20 user/worker history entries; exact history is retained.
The Engine's combined prompt limit still applies. Compaction, generated summaries,
artifact-body resolution, and provider token budgets remain future work.

Context size limits include the complete serialized document, including repeated
recent-turn evidence and structured facts, rather than raw history text alone.
Cloud treats history/serialized-byte overflow as an assignment admission failure
before creating an assignment or consuming Worker capacity. The failure offers a retry icon and asks the user to confirm clearing AI History.
The confirmed retry starts a fresh session in the same Thread, retaining the latest
preceding AI answer and the failed request. Canonical history remains intact;
the context floor excludes older exchanges. The retry API requires `clearAiHistory: true`
for `context_limit_exceeded`. Migration `0079_ai_history_cutoff.sql` adds the
Thread history cutoff and Conversation context floor. The shared Thread session key
includes the Thread session generation, so subsequent requests continue the fresh
session after a reset. Earlier exchanges remain readable in Conversation.
Cloud reports the stable `context_limit_exceeded` error code and fixed public
guidance in Thread history, including for previously stored fixed context-limit
errors. Retry advice disallows replaying the same oversized snapshot. This is an
additive error-taxonomy value; older readers may display their generic fallback.

No Phase 16 database migration is required. Structured context documents and the
optional Local Worker Protocol 4.0 `statelessContext` envelope use schema version 1;
updated Connect/Engine readers must precede Cloud emission of the new field.
No deployment is included.


## Phase 17 — Workflow-aware context

Version 1 Context Engine documents distinguish `conversationContext` from
`workflowExecutionContext`. Conversation context holds persistent objective,
decisions, constraints, state, issues, artifacts and summary. Execution context
is scoped to one Work Request and receiving `activeStepId`: it includes the
workflow/version, status, task graph, attempts, Worker attribution, and completed
transitive prerequisite results. Core validates receiving-step membership, missing
dependencies, duplicate identities and cycles. Pending, failed, downstream and
unrelated step results are excluded. Results remain historical data, not trusted
instructions. Existing `context` and `workflowState` fields remain available in
version 1 for the current protocol readers.

Chat execution context contains task identity/state but no added environment or
execution artifact set. Work and other workflows include scoped Space, Thread
and Connect identities, immutable Space/Thread instructions, and artifact
identity/digest references from the same Work Request and Space. Local filesystem
state, paths, credentials and artifact bodies are not read from Cloud. Connect
continues to provide authorized Work Root access through the existing execution
policy. This is a dispatch-time state snapshot, not a filesystem inspection.

Cloud dispatch passes the actual receiving task identity to assembly. Core
selects prerequisite outputs from the persisted dependency graph. For example,
VERIFY receives IMPLEMENT's completed result and attributed Worker; FIX can
receive transitive IMPLEMENT and VERIFY results once its dependencies complete.
The receiving step may still be queued at dispatch; its explicit identity, not a
guessed running status, controls selection. Future multi-step Conversation
workflows can reuse this contract without new provider branches. This phase does
not add new workflow definitions or attach legacy non-Conversation runs to a
Conversation.

Work/multi-step execution context is refreshed through resumed-session deltas even
when Conversation revision/history is unchanged. This distinguishes step-state
changes from conversation synchronization. Simple Chat retains its current-session
new-request-only fast path. Stateless and bootstrap transport carry the same
execution context. Documents retain the existing bounded snapshot limits; graph
reads additionally reject more than 10,000 dependency edges and 1,000 artifacts.

No database migration is required. New document fields are additive version 1
contracts; updated Engine/Connect readers must precede Cloud rollout to preserve
execution context in resumed deltas. No deployment is included.


## Phase 18 — WorkflowRun and WorkerTurn ownership

Execution now has explicit provider-independent identities:

```text
Conversation
  UserMessage
    WorkflowRun (stable logical execution)
      WorkerTurn (one actual Worker invocation)
      WorkerTurn (another step or retry invocation)
      Runtime Run attempts (existing scheduler runs)
```

A user message is immutable conversation history, not an execution. A version 1
`WorkflowRun` records Conversation/message/Work Request ownership and the pinned
execution workflow/version. `ConversationTurn` is also named `WorkerTurn` in Core;
each turn now has immutable `workflowRunId` ownership and exposes its assignment's
`runtimeRunId` when present. It retains per-invocation Worker/Profile/model/effort,
step and lifecycle evidence. There is no uniqueness constraint limiting a logical
WorkflowRun to one Worker turn.

The existing Work Request remains the authority for logical execution lifecycle,
immutable configuration, task graph and request authorization.
`conversation_workflow_runs` stores only the stable identity association, avoiding
a duplicate lifecycle projection in persistent state. Existing `runs` are scheduler
attempts: an explicit retry can add a runtime Run and Worker turns to the same
WorkflowRun without replacing the original message or historical turn evidence.
The first Chat/Work execution normally has one Worker turn; multi-step workflows
can use the same ownership structure. No new workflow definition is added here.

Authorized Work history and request-detail responses add `workflowRun` (or null
for non-Conversation requests), including status, runtime Run IDs and Worker turn
IDs. The existing flat `turns` projection remains available. AX parses and caches
this separate entity and preserves it during reconciliation. Legacy cached data
can omit the additive fields until refreshed; new Cloud turn responses always
include WorkflowRun ownership. Workflow execution context also carries the stable
WorkflowRun identity rather than treating a message as the execution.

`0015_conversation_workflow_runs.sql` initializes one stable logical run for each
associated Work Request and backfills historical turn ownership. It does not
rewrite user text, prior turn attribution/status/results or canonical history.
Triggers enforce scope and immutable associations; new assignment-created turns
receive their owner atomically. Production schema checks include the new table
and turn ownership column. Apply this schema update before deploying Cloud code.
The native Worker session contract is unchanged; no remote migration/deployment
is performed by this implementation.


## Phase 19 — WorkflowRun and WorkflowStepRun data model

Version 1 `WorkflowRun` now exposes `triggerMessageId`, `startedAt`, `completedAt`
and nested `stepRuns`, in addition to identity, Conversation, workflow/version and
status. `triggerMessageId` names the immutable user message; `userMessageId` remains
the same association in the existing read contract. Work Request owns status;
WorkflowRun timestamps persist lifecycle evidence from Work Request transitions.
First start is retained across retries, completion is cleared on reopening and
recorded on terminal transition. Unrelated metadata updates do not move completion.
Historical first starts are recovered from existing task, turn and runtime Run
evidence; absent evidence stays null.

Each version 1 `WorkflowStepRun` has stable identity and parent `workflowRunId`,
`taskId`, definition `stepId`, execution `role`, Worker/model/effort, logical Worker
Session reference, `baseContextRevision`, status, result, step lifecycle timestamps
and `workerTurnIds`. Current built-in definition IDs and roles use StepKind (e.g.
chat, implement, verify); the domain fields remain distinct strings. No new custom
or repeated-role workflow definitions are enabled in this phase.

`conversation_workflow_step_runs` persists immutable step/task/parent identity.
Existing `workflow_tasks` remain the single owner of step state and output.
Worker turns receive immutable `workflowStepRunId` ownership; several turns can
belong to one step across retries. Before dispatch, the StepRun spaces the
immutable resolved binding. Once dispatched, selection/session/context attribution
comes from its most recent actual Worker turn, including explicit null model/effort
for provider defaults rather than falling back to configured values. Historical
Worker turns remain immutable. During a queued retry the last actual selection is
still visible until the new invocation, but result/completion remain empty.

Results expose completed step text through the existing 24,000-character Human
Product read limit, not raw provider output JSON. Failed/queued/running steps expose
no stale result. Workflow context includes StepRun identity/role and prefers actual
Worker attribution while retaining its separate, bounded context assembly. Logical
Session references are allowed; provider-native handles remain Connect-local.

Accepted Conversation Chat/Work requests now atomically materialize their planned
queued tasks and StepRuns before scheduling. Each initial simple request has one
StepRun; idempotent submission replay creates no additional step. Existing workflow
initialization remains idempotent. Existing tasks discovered before association
also acquire StepRuns through the WorkflowRun insertion trigger.

`0016_workflow_step_runs.sql` backfills logical steps and turn ownership, initializes
WorkflowRun timestamps, and installs ownership/lifecycle triggers. Historical turn
selection, status, results and canonical history are preserved. Authorized Work
read models and AX cache round-trip nested steps and timestamps; older cached
records can omit the additions until refreshed. Production schema checks cover
the new table and columns. Apply the schema update before deploying Cloud. No
Connect/Engine framing or provider transport change is required, and no remote
migration/deployment is included.


## Phase 20 — Simple Chat/Work presentation

WorkflowRun, WorkflowStepRun, routing and execution graphs remain internal
execution models. Their presence in a response/cache does not enable orchestration
UI. Ordinary Chat and Work continue to show the user's message, Syntila's initial
progress, then the actual Worker name/icon and response. Model/effort selection
stays near Send and historical attribution remains accurate.

Current controls use request language: Send request, View request details, Retry
request and Cancel request. Cancellation/waiting messages do not expose run/step
terminology. Optional request details lead with Worker identity and retain useful
status, model/effort, timing, responses and recovery actions; they do not label the
one-step execution Implement, render a workflow version, or show a graph/step
counter. Existing optional technical troubleshooting details remain explicitly
expandable rather than being added to the conversation.

Backend `workflowRun` and `stepRuns` stay available for state, synchronization,
future workflows and diagnostics. UI must not infer an orchestration display from
these records' presence or counts. A future multi-step presentation requires its
own product design and explicit enablement. Widget regression tests populate
these records for both Chat and Work while asserting Worker identity/icon, message
content, friendly request details, and absence of internal run/step identifiers
or graph/orchestration labels.

No database, public API, runtime protocol or provider transport change is required.


## Phase 21 — Future multi-step presentation capability

AX provides an opt-in `prepareWorkflowRunPresentation` adapter for the future
step-list UI. It returns no presentation by default. Explicit product enablement
and a matching versioned workflow with `executionPolicy.multiStep = true` are both
required. Current Chat/Work screens do not invoke or enable it. Increasing backend
StepRun or Worker-turn counts does not change their conversation presentation.

The adapter prepares a workflow-name title and ordered rows from the pinned
definition's step order, independent of database row/invocation order. Each row has
a user-facing step label, semantic state, Worker name/type, model and effort. A
future view can present the requested pattern:

```text
Implement + Verify
✓ Implement   ChatGPT · Model X · High
● Verify      Gemini  · Model Y · High
○ Correct     ChatGPT · Model X · Medium
```

Completed, active and pending map to those semantic states; waiting, failure and
cancellation remain distinct and must get accessible status labels rather than
being mistaken for completion. Caller-supplied definition labels support Correct
without changing its underlying implementation role. This example is presentation
preparation, not registration of a new correction/custom execution graph.

Actual Worker identity/model/effort come from the latest scoped immutable Worker
turn identified by the StepRun, rather than live composer/catalog preferences.
Provider-default model/effort stay null for the future view to label as defaults.
Pending steps can use frozen binding labels and configured StepRun choices. If the
latest invocation is absent from a partial history page, an older invocation is
never substituted as the current Worker; canonical StepRun selection remains
available with a generic Worker label.

The adapter rejects foreign workflow versions/scopes, duplicated or unknown steps,
invalid definition order and unsupported statuses. Incomplete step state produces
no speculative graph. Ordered row collections are immutable. Tests exercise the
three-row example, recorded attribution, default selections, non-happy states and
partial-history behavior; Chat/Work widget tests also carry extra internal StepRun
records to prove that count alone never enables orchestration UI.

No new UI widget, active product flag, workflow definition, database migration,
API or runtime protocol change is introduced. Rendering and explicit rollout
remain deferred until multi-step Conversation workflows are enabled.

## Phase 22 — Worker switch UX

Chat and Work apply composer Worker changes immediately to the current local
next-turn selection, without confirmation dialogs or context-synchronization
messages. The selection is restored locally for that Thread when it remains
available, but is never written to Cloud preferences. Sending retains the same
Thread and selected workflow; routing, bootstrap, resume and delta
synchronization remain below the UI boundary. Existing turns retain their
recorded Worker attribution. No extra timeline event is needed while the
selected Worker is already visible beside Send.

Switching clears the prior Worker's model/effort before reconciling the target
Profile's execution options and restoring its remembered choices. It also refreshes
the display label and clears the previous fallback Worker and fallback label,
so the next-turn binding cannot carry another Worker's identity metadata.

Widget regressions exercise repeated switches for both Chat and Work, immediate
submission to the selected Worker, absence of confirmation/synchronization UI,
and no mutation of shared Thread defaults. Existing composer tests preserve
earlier submitted selections when preferences change. No database migration,
public API or runtime protocol change is required.

## Phase 23 — Model and effort UX

Model and effort selections configure the next request without adding change
messages to the timeline. Worker responses expose compact recorded metadata such
as `Model Y · High` through an information icon beside the Worker name. Hovering
or tapping reveals the detail, keeping ordinary Chat and Work headers quiet and
making the information accessible on touch devices as well as desktop.

Metadata uses the immutable matching Worker turn, with request-step snapshots
only when turn evidence is absent. It never uses current composer or catalog
selections to relabel historical responses. Null recorded choices remain
`Default model · Default effort`; Syntila does not invent resolved provider
defaults. Syntila progress/error messages do not show Worker configuration.

Widget coverage exercises Chat and Work, distinct historical configurations,
explicit defaults, misleading current-step metadata and tap disclosure. No
database, API or protocol changes are required.

## Phase 24 — Failure UX

Chat and Work translate execution failures into actionable product messages.
Unavailable conversation continuity asks the user to retry without exposing a
native session handle or resume status. Other stable failure codes explain
readiness, sign-in, access, usage limits, model availability and timeouts.
Unknown execution failures receive a generic retry message, not provider output.
Local submission validation messages remain available to explain form/access
problems before an execution exists.

Request details retain results, timing, Worker identity and execution choices,
but remove the technical expansion containing assignment IDs, Engine/Profile/tool
versions, session policy, retry session strategy and raw error codes. Technical
evidence remains in existing Connect/Engine logs and Profile Lab diagnostics;
presentation does not modify stored failure evidence or execution behavior.

A successful reconstruction notice requires explicit recovery evidence. This
phase does not infer recovery from an error code or claim that context was
restored; automatic reconstruction belongs to Phase 25. Existing Cloud failure
normalization may classify continuity failures as generic execution failures,
which receive the generic message rather than an unsupported diagnosis.

Widget regressions exercise failure messages and detail views in both Chat and
Work, hiding native identifiers and diagnostics. No migration or public contract
change is introduced.

## Phase 25 — Worker-step session reconstruction

The generic CLI Worker Engine owns reconstruction inside the existing assignment
execution. An unavailable native session is invalidated locally, then a single
replacement attempt receives the complete frozen canonical bootstrap from the
Context Engine plus the current request. WorkflowRun, StepRun, assignment,
logical WorkerSession scope, model, effort and base revision remain unchanged.
The replacement uses the Profile's ordinary new-session arguments, without the
rejected native handle. Native handles remain local execution state.

Reconstruction requires a signed `session_unavailable` stderr-pattern mapping to
`session_resume_failed`, a failed native resume, no final response or success
evidence, and no reported provider work/tool progress. Generic provider failures,
timeouts, authentication failures, malformed output and successful session-ID
mismatches do not trigger replay. Both attempts share the original timeout
budget; a failed replacement is terminal rather than recursively retried.

Local WorkerSession schema v1 adds `invalidated` status. Rejected handles cannot
resume after Engine restart. Invalidation checks the expected native handle so
an already replaced mapping is preserved. Successful replacement records its
new native identity and consumed revision/history watermark, retaining logical
scope and creation time. Failure leaves invalidated state and never advances
synchronization. Missing canonical context invalidates the rejected handle but
does not attempt reconstruction. Scope/attribution errors still fail closed.

Technical invalidation/reconstruction events are logged locally with request and
assignment correlation. Normal UI receives only the eventual result or friendly
failure; the Engine does not claim recovery before successful completion.

Tool Profile schema v1 adds the bounded `session_unavailable` pattern vocabulary.
ChatGPT/Gemini fixture profiles and fresh-start draft starter seeds include it.
Existing Drafts and signed releases are not rewritten. Rollout requires the
updated Engine and a newly qualified/promoted signed Profile with the mapping.
No runtime protocol or D1 table migration is required; the baseline seed change
affects new starter provisioning only.

Executable tests cover full-context reconstruction, failed replacement without
revision advancement, missing context, restart after invalidation, stale-handle
invalidation rejection and signed error classification. Existing session scope,
model-switch, output mismatch and provider failure tests remain applicable.
Live provider reconstruction and remote Profile promotion were not performed.

## Phase 26 — Context revision and synchronization evidence

Conversation acceptance maintains separate monotonic `conversationRevision` and
`contextRevision` fields. Under the current exact-history policy both advance on
accepted requests; history sequence additionally identifies late responses and
context/artifact events within that revision. Replays, progress and failed batches
do not invent revisions. These semantics supersede the Phase 1 reservation above.

Each dispatch freezes the preceding accepted-request boundary as
`baseContextRevision`, plus its canonical history watermark. WorkflowStepRun
spaces that immutable invocation evidence from its Worker turn; queued steps
use the immutable request boundary. Later Conversation changes and completion
never relabel an older step's starting revision. The fresh-start schema rejects
turn insertion when its base differs from its scoped request boundary, and retains
the existing immutable-attribution update guard.

Connect-local WorkerSession records `synchronizedContextRevision` and
`synchronizedHistorySequence` only after successful native execution. With a
bootstrap, the consumed revision includes the current request (`turnRevision`);
it cannot merely record the preceding base. Store writes reject incorrect
bootstrap watermarks, decreasing revisions/sequences and values outside the
protocol's safe-integer bounds before changing the file. Invalidated sessions
also cannot bypass the newer-than-turn context guard.

Local diagnostic events `engine.context.selected` and
`engine.context.synchronized` record logical Conversation/WorkerSession scope,
request/assignment correlation, the frozen base, prior synchronized revision,
target revision and history watermark. The synchronized event follows successful
persistence; failures produce no success evidence. Native handles and context text
remain excluded. No continuity bookkeeping is added to ordinary Chat/Work UI.

Tests cover wrong dispatch boundaries, rollback of rejected assignments, frozen
StepRun/turn evidence after Conversation advancement, consumed-turn synchronization,
regression/bounds rejection without file changes and safe diagnostic fields.
Local schema-v1 fields and public/runtime contracts are unchanged. A new guard is
part of the existing v8 fresh-start schema; existing initialized databases need
that guard installed separately before claiming equivalent enforcement. No remote
schema or Engine deployment was performed.

## Phase 27 — Parallel-step causality and native-session exclusion

Independent Worker steps may start from the same accepted context boundary.
Their immutable turns and response events retain that base when either completes
or the Conversation advances. Canonical context excludes current-request sibling
responses; workflow context supplies completed prerequisite results only. A
sibling's completion never retroactively changes an already supplied snapshot.

Dispatch now persists versioned `contextSnapshot` evidence in the assignment
permission snapshot: base revision, consumed-turn target revision, history
watermark and SHA-256 fingerprint of the exact canonical context sent. The
fresh-start schema prevents rewriting this evidence after a Conversation turn
exists. A fingerprint identifies the supplied payload; it does not imply the
worker saw later results or archive the payload itself.

Native session execution is exclusive within its local scope. The generic Engine
holds a nonblocking OS file lock from before reading native state through provider
execution, reconstruction and persistence, with an in-process guard for multiple
Engine instances. A competing execution fails before provider startup with an
existing availability error; it does not wait and silently ingest newer state.
Different Worker/session scopes and stateless executions remain independent.
Callers may retry a rejected execution through existing request handling.

Persistent lock files are not ownership markers. OS ownership ends on normal
release or process death, so restart does not require deleting a stale lock file.
The lock directory stays inside Connect-owned Engine state. This coordinates
Syntila Engine processes; external CLI usage is outside that boundary. Runtime
Engine processes execute in one isolate; this is not a multi-isolate lock service.

Tests exercise two Worker steps from one base, sibling-response exclusion, frozen
turn/event evidence after Conversation advancement, immutable snapshot evidence,
same-scope exclusion, independent scopes, cross-process exclusion, crash release
and rejection before provider invocation. No parallel product workflow or UI is
enabled by this phase.

Public/runtime and local session schemas are unchanged. Local `.session-locks`
files are created automatically. Existing databases need the new snapshot guard
installed for matching enforcement; no remote schema deployment was performed.

## Phase 28 — Workflow and execution boundaries

The existing v8 execution path now separates planning, execution configuration,
continuity preparation, context construction and provider invocation explicitly.

| Boundary | Responsibility | Implementation |
| --- | --- | --- |
| Workflow Engine | Determine Steps, dependencies, prompts and lifecycle | Core Workflow planner; Cloud `workflow.ts` |
| Execution Engine | Snapshot selected Worker/model/effort and execution policy; return generic Step results | Cloud `execution-engine.ts` |
| Conversation Router | Choose continuity action and prepare full/delta/new-request context | Core `conversation-router.ts`; local `conversation_execution_router.dart` |
| Context Engine | Assemble canonical conversation and receiving-step workflow context | Core Context Engine, supplied by Cloud-owned context loading |
| Worker Engine | Validate local native state and the signed Profile execution contract; supervise CLI, reconstruct and persist | Generic CLI Worker Engine and signed Tool Profiles |

The Workflow runner calls `prepareWorkerStepExecution` rather than deriving
session keys, runtime policy or Worker options itself. It calls
`completeWorkerStepExecution` to translate admitted execution evidence into a
provider-independent StepResult. Graph scheduling, cancellation, retry policy
and request lifecycle remain Workflow responsibilities. Assignment dispatch
retains authorization, Profile admission, frozen context evidence and D1 access.

The local ConversationExecutionRouter receives validated native-session state
and the immutable context envelope. It returns a continuity action and prepared
prompt without reading persistence, resolving Profiles or starting processes.
Current-session execution sends only the new request; behind sessions receive a
delta; bootstrap, reconstruction and stateless execution receive full context.
Model-switch capability and unavailable-handle validation remain generic Worker
Engine concerns. Reconstruction reuses the same prompt-preparation boundary
within the original Worker step and WorkflowRun.

Cloud never owns native session handles. Connect retains session files, locks
and local diagnostics. The existing Core Router remains the provider-independent
policy boundary; the Dart adapter spaces that policy onto validated local state
and the existing runtime envelope. No provider-specific execution path, new
workflow UI, orchestration service or public compatibility API is introduced.

Tests cover execution-option snapshots, stable session scope, generic result
attribution, all five runtime continuity actions and missing-context rejection.
Existing execution, reconstruction, concurrency and Profile acceptance fixtures
continue to exercise the integrated path. Public/runtime contracts, local session
schemas and database schemas are unchanged; this phase requires no migration.
Live provider and remote deployment validation remain separate release gates.

## Phase 29 — Continuity regression matrix

Coverage combines provider-independent routing, SQLite-backed Cloud persistence,
local Engine subprocess fixtures and AX widget tests. Each layer verifies its own
boundary; routing decisions alone are not evidence that a provider resumed.

| Transition / invariant | Expected | Executable coverage |
| --- | --- | --- |
| Same Worker/model/effort | Continue, new request only | Core `conversation-router.test.ts`; Engine `conversation_execution_router_test.dart`, `engine_session_release_compatibility_test.dart` |
| Effort change only | Same native scope, new turn effort | Core routing matrix; Cloud `conversation-turns.test.ts`; Engine `worker_session_test.dart` |
| Model change | Keep session or reconstruct according to Profile session/model options | Core routing matrix; Engine release compatibility subprocess fixtures |
| New Worker | Bootstrap existing canonical context | Core routing matrix; Cloud bootstrap fixtures |
| Return to previous Worker | Resume its own session with bounded delta | Core round-trip regression; Engine delta-context fixtures |
| Worker switch in Chat/Work | No warning | AX `spaces_pages_test.dart` |
| Connect/Engine restart | Read persisted native state without in-memory dependency | Engine `worker_session_test.dart` uses a new store instance; release compatibility tests start separate Engine processes |
| Lost native session | Invalidate, reconstruct once, retain logical run | Engine release compatibility fixtures and invalidation/replacement tests |
| Chat request | One WorkflowRun and one StepRun | Cloud turn regression and workflow-run projection tests |
| Work request | One WorkflowRun and one StepRun | Cloud `conversation-workflow-step-runs.test.ts` |
| Future multi-step records | Several StepRuns under one trigger message | Cloud `conversation-workflow-runs.test.ts`; no new product workflow is enabled |
| Parallel steps | Preserve each frozen base and exclude unseen sibling answers | Cloud `conversation-bootstrap.test.ts`; Engine session-lock tests |
| Next-turn defaults change | Historical attribution remains unchanged | Core immutable-input matrix; Cloud completed-turn/defaults regression; AX response-details tests |

The round-trip regression retains separate Worker/Profile identities and checks
that returning to the original Worker selects its existing session and only the
missing revision range. The completed-turn regression changes persisted Thread
execution defaults and reads historical attribution again, rather than relying on
an unchanged in-memory object. Native-state tests recreate their store to make
restart persistence explicit.

This phase changes tests and documentation only. Database, runtime and public
contracts are unchanged; no migration or deployment is required. Fixture providers
establish deterministic protocol behavior, not live-provider acceptance.

## Phase 30 — Remove superseded execution assumptions

The audit retains the product defaults and removes residual compatibility paths
rather than deleting valid configuration or historical evidence.

| Old assumption | Current ownership / cleanup |
| --- | --- |
| Selected Worker identifies the Conversation | Conversation identity is Thread + Workflow; turns and WorkerSessions carry Worker/Profile identity |
| Model/effort are global conversation state | Thread bindings are configuration defaults; composer choices are local next-turn preferences; immutable turns retain actual execution choices |
| Messages invoke CLI directly | Submission creates product request/run records; Workflow scheduling delegates execution; Connect supervises the generic Engine |
| Work tab knows a provider runtime | Composer consumes normalized Worker options; shared `WorkerPresentation` owns branding and generic fallback, with no execution behavior |
| Workflow owns provider/session behavior | Execution Engine owns session scope/configuration; local Router and Worker Engine own continuity and native handles |
| One request means one provider session | Runs own StepRuns and immutable invocation turns; compatible native sessions can span requests and reconstruction stays within a step |

Composer, submission and binding controls now use only the canonical product
fields `workerId` and `reasoningEffort`. Removed snake-case aliases are not part
of the v8 product contract. The fixture that previously supplied `worker_id` now
uses that contract. SQL column names and runtime protocol fields are unaffected.
The Worker icon/name mapping shared by composer and responses is isolated in
`worker_presentation.dart`; unknown Workers retain catalog names and a generic
visual fallback. Signed Profiles remain the source of provider execution
options and session contracts.

The existing v8 architecture guard now checks that Workflow dispatch and result
handling use the Execution Engine, session keys/policies do not move back into
Workflow planning, canonical prompt preparation stays in the local Router, and
composer modules do not regain native execution state or legacy binding aliases.
No historical turn projection, native release-format handling, execution default
settings or existing workflow graph is removed.

Verification includes the full JavaScript and AX suites, static analysis and
architecture/protocol/documentation guards. This phase introduces no schema or
public protocol migration. Clients or hand-authored configuration that supplied
only the retired snake-case binding aliases must use the canonical camel-case
fields; no unreleased-architecture compatibility adapter is retained. No remote
rollout or live-provider validation is performed by this cleanup.

### AI History clearing and Conversation retention

Clearing AI History records the Cloud timestamp on the Thread and advances each
Conversation's canonical context floor. It preserves the original Work Requests,
turns, answers, Worker identity, model and timing evidence without copying them
into discussion messages. AX filters AI History by request creation time while
Conversation continues rendering those same original records. AX uses the exact
Cloud cutoff, fences earlier reads, and reconciles other clients through the
existing clear event.

Both Chat and Work use the next Thread session generation after a clear. This
resets session continuity; native provider session files remain owned locally by
Connect/Engine and are not physically erased by the Cloud action. Clearing the
Conversation deletes discussion messages and Work with their canonical history;
Thread removal retains its existing cascading deletion behavior. Active Work
must be cancelled before either clear action. Records already deleted by the
former archive-and-delete implementation cannot recover missing metadata.
