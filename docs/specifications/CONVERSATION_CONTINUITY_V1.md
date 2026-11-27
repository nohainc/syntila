# Multi-Worker Conversation Continuity v1

**Boundary:** Syntila Core, Cloud and the Human Product Protocol on one side;
Connect and the generic CLI Worker Engine on the other. **Contract version:** 1.

A person can switch Workers, models and effort between requests in one Thread
and the conversation continues. Syntila owns the conversation history; a
provider CLI session is local, reconstructible execution state and never the
source of history.

Execution defaults come from
[User Workflow Configuration v1](USER_WORKFLOW_CONFIGURATION_V1.md)
([ADR-019](../decisions/ADR-019-per-user-workflow-execution-configuration.md)).
A one-step request may send a transient `executionSelection`; Cloud validates and
snapshots it without changing saved settings. Threads store no Worker, model or
effort preference in Cloud.

## Ownership model

```text
Space → Thread → Conversation
                   UserMessage
                     WorkflowRun (stable logical execution = one Work Request)
                       WorkflowStepRun (one per Step)
                         WorkerTurn (one actual Worker invocation; retries add turns)
                         runtime Run attempts (scheduler)
```

- **Conversation.** One implicit Conversation per Thread, shared by Chat and Work,
  created lazily by the first eligible request. Its ID is `conversation-` plus the
  SHA-256 of the JSON array `[threadId]`. Identity, Thread ownership and Workflow
  version are immutable. `GET /api/threads/:id/conversations` lists it (Thread
  `view` access, no provider data). Product definitions (`chat` → `chat:v1`,
  `work` → `direct:v2`) are versioned separately from execution graphs.
- **Revisions.** `conversationRevision` counts accepted Work Requests (including
  ones that later fail or are cancelled); acceptance also advances
  `contextRevision`. Replays, progress and failed batches add nothing. Both are
  monotonic and context never exceeds the conversation revision. History sequence
  is a separate, per-Conversation high-water mark.
- **WorkflowRun / WorkflowStepRun.** The Work Request stays the authority for
  status, configuration, task graph and authorization; the run tables store only
  stable identity plus lifecycle timestamps (first start kept across retries,
  completion cleared on reopen). A StepRun holds step/task identity, role, the
  Worker, model and effort, the logical session reference, `baseContextRevision`,
  status, result and its `workerTurnIds`. Before dispatch it shows the frozen
  binding; afterwards its latest actual turn (explicit null model/effort means
  Default, never a guessed provider model). Results are capped at 24,000
  characters in presentation.
- **WorkerTurn** (`ConversationTurn`). One row per actual assignment: Worker,
  Type, name at the time, Profile and release, model, effort, logical session
  reference, frozen `baseContextRevision`, lifecycle and result. Attribution comes
  from the assignment's selection evidence, never from current inventory or a later
  rename. Database guards block attribution edits and lifecycle regressions.
  Work history and detail responses include `conversationId`, `workflowRun` and
  `turns`.
- **User messages.** `conversation_user_messages` keeps the original text and
  author per request, separate from team Discussion.

## Canonical history

Each Conversation has an append-only ledger. Entry types: `user_message`,
`worker_response`, `workflow_event`, `execution_event`, `artifact_event`,
`context_event`. Entries have a Conversation-local sequence, actor and source
references, exact text where applicable, allowlisted metadata, source time and
recording time. Database triggers record them in the same transaction as the
source change; repeated delivery cannot duplicate a message or reply. Progress,
raw logs, storage keys, credentials and native session handles are excluded;
artifact events carry references, not bodies. Entries cannot be edited or
deleted individually; deleting the Conversation is the retention boundary.

`GET /api/threads/:id/conversations/:conversationId/history` takes `limit`
(1–100, default 50), `afterSequence` and `throughSequence`, and returns
`historyRevision`, `throughSequence`, ordered `entries` and `nextCursor`. Carry
both cursor fields to keep a stable upper bound. The endpoint never truncates
text.

## Worker sessions

A Worker session is Connect-local state for one Conversation and one Worker
Type/Profile (not per model). Only Connect's Engine stores native handles
(`nativeSessionId`); Cloud stores an opaque SHA-256 reference derived from
Connect, Worker, Profile definition, Conversation and the logical session key.
Model, effort and compatible Profile release changes do not change it. Chat and
Work share one Thread session key, so a Worker resumes its session across
Workflows. A fresh-session retry or AI History clear increments the Thread's
session generation, which changes the key.

Durable assignments carry `workerSession` metadata (schema 1: session,
Conversation and Worker IDs, `baseContextRevision`, optional `bootstrap` and
context documents). Connect validates ownership and translates it into Local
Worker Protocol 4.0 execute frames. Native handles are forbidden in that metadata.
The local record also stores `synchronizedContextRevision`,
`synchronizedHistorySequence`, last model and effort, and a status (`active`,
`requires_synchronization`, `invalidated`). It advances only after a successful
execution, to the consumed turn's revision (`turnRevision`, which includes the
current request), and the store rejects decreasing or out-of-bounds values.

## Routing

Core's `routeConversation` (`conversation-router.ts`) is the provider-independent
planner; the Engine's `conversation_execution_router.dart` applies the same
policy to validated local state and prepares the prompt. Neither reads
persistence, resolves Profiles or starts processes.

| Action | Condition | Context sent with the new request |
| --- | --- | --- |
| Continue session | Compatible native session synchronized to the turn revision | None |
| Sync and continue | Session is behind | Only the missed delta |
| Bootstrap | No session for this Conversation + Worker/Profile | Full canonical context |
| Reconstruct | Native state missing or invalid, incompatible release, unsupported model switch | Full canonical context |
| Stateless | Turn is stateless or durable sessions unsupported | Full context |

Synchronization and the turn happen in one provider invocation through the
Profile's ordinary prompt transport; there is no separate sync call.

- **Effort** changes never split sessions; the signed `effortMapping` expands the
  value into the invocation template.
- **Model change** keeps the session when the Profile declares
  `modelSwitchSupported`; otherwise the Engine requires a canonical bootstrap,
  starts a new native session without the resume handle, and replaces the mapping
  only after success.
- **Different Worker** gets a bootstrap of the canonical context; a returning
  Worker resumes its own session and receives only entries recorded after its
  history watermark, excluding replies produced inside its own session.
- **Unknown or legacy local records** without Worker-session attribution are
  reconstructed rather than assumed current.

## Context documents

Core's `ContextEngine` builds versioned `BootstrapContext`, `DeltaContext` and
`StatelessContext` documents. Each holds scoped revisions, canonical evidence,
the last 20 user/worker turns, and structured context: objective, decisions,
constraints, current state, open issues, artifact references and summary. Facts
carry revision and sequence provenance; cleared values keep tombstones so deltas
convey removals. Only committed `context.fact_updated` events create facts; worker
prose never becomes a decision or summary. Space and Thread instructions seed
constraints.

- `conversationContext` (persistent) is separate from `workflowExecutionContext`
  (one Work Request and the receiving `activeStepId`): workflow and version,
  status, task graph, attempts, Worker attribution and the completed transitive
  prerequisite results. Pending, failed, downstream and unrelated steps are
  excluded, and results are historical data, never instructions. Chat gets task
  identity only; Work adds scoped Space, Thread and Connect identities,
  instructions and artifact identity and digest (never paths, bodies or
  credentials).
- Dispatch freezes `baseContextRevision` (the accepted request's revision minus
  one), the history watermark, and persists a `contextSnapshot` (base, target,
  watermark, SHA-256 fingerprint of the context sent) in the assignment's
  permission snapshot. It cannot be rewritten once a turn exists. Independent
  parallel Steps start from the same base and never see a sibling's current
  response.
- **Limits:** 1,000 entries, 256 KiB serialized (the whole document), 10,000
  dependency edges, 1,000 artifacts, and the Engine's 512 KiB combined prompt.
  Overflow is an admission failure before an assignment exists
  (`context_limit_exceeded`), never silent truncation. The retry then asks the user
  to confirm clearing AI History (`clearAiHistory: true`). There is no compaction,
  generated summary or artifact-body loading.

## Local session safety

- **Recovery.** A missing or malformed local mapping is recoverable when the
  assignment carries a validated bootstrap (a malformed file is quarantined in the
  Worker state directory). Attribution mismatch or missing bootstrap fails closed;
  an empty context is never created.
- **Reconstruction.** If the provider rejects a resume and the signed Profile
  maps a `session_unavailable` stderr pattern to `session_resume_failed`, with no
  final response or success evidence and no reported provider work, the Engine
  invalidates the handle (checking the expected handle so a newer mapping survives)
  and makes one replacement attempt with the full bootstrap, within the original
  timeout. A failed replacement is terminal and advances nothing. Other failures,
  timeouts, auth failures and session-ID mismatches never trigger replay.
- **Exclusivity.** An OS file lock under the Engine's `.session-locks` is held from
  before reading native state through execution and persistence. A competing
  execution in the same scope fails before the provider starts instead of waiting.
  Different scopes and stateless runs are independent. The lock ends with the
  process; stale files need no cleanup. It coordinates Syntila Engine processes
  only.
- **Diagnostics.** Local events (`engine.context.selected`,
  `engine.context.synchronized`) log scope, correlation, base, prior and target
  revisions and watermark, with no native handles or context text. Early failures
  carry bounded, redacted private diagnostics; user-facing messages stay generic.

## Execution options

The Worker inventory carries `executionOptions` (schema 1): `models`
(`supported`, `discovery`, `allowsCustomModel`, `allowedModelIds`, `defaultModelId`,
per-model effort options), `modelSwitch.supported` and `effort`. Values are bounded
Profile strings; an explicit empty per-model effort list disables effort for that
model. Null model or effort means the provider default; Syntila never invents a
resolved model, and an unavailable default becomes null. Profiles may declare
`model.executionOptions` (`discovery: "profile_catalog"`, `modelSwitchSupported`,
`effortSupported`, `defaultModelId`, `effortMapping`); the TypeScript and Dart
validators reject contradictions and `dynamic` discovery. Arguments, mappings,
environment and handles never enter the public DTO. Cloud validates choices at
readiness and creation, and the Engine rejects unsupported model-specific effort
before launching. See [Worker execution options v2](WORKER_EXECUTION_OPTIONS_V2.md).

## Workflow execution policy

Every product Workflow declares `executionPolicy` (`userSelectsWorker`,
`userSelectsModel`, `userSelectsEffort`, `multiStep`, `multiWorker`,
`automaticContinuation`, `requiresApprovalBetweenSteps`), and the catalog adds
`composerBindingId` (null for multi-step graphs). The app reads this metadata
instead of branching on workflow IDs; missing metadata means no selectable
composer choices. These flags are presentation only and never grant execution or
filesystem authority.

## Product presentation

- Ordinary Chat and Work show the user's message, Syntila progress, then the Worker's
  name, icon and reply. WorkflowRun, StepRun and routing stay internal; their counts
  never switch on orchestration UI. A step-list adapter
  (`prepareWorkflowRunPresentation`) exists for future multi-step workflows and
  requires explicit enablement plus a matching `multiStep` definition.
- Worker, model and effort changes apply to the next request without dialogs or
  timeline entries. Switching Workers clears the previous Worker's model and effort.
  A reply shows `Model · Effort` in an info popover taken from the immutable turn
  (null shows `Default model · Default effort`), never from current settings.
- Failures map stable codes to actionable messages (readiness, sign-in, access,
  usage limit, model availability, timeout, continuity unavailable); unknown
  failures get a generic retry message. Request details omit assignment IDs,
  session policy and raw codes; technical evidence stays in Connect logs and
  Profile Lab.

## AI History clearing

Clearing AI History stamps the Thread with the Cloud time and raises each
Conversation's context floor, keeping the original requests, turns and answers.
The app filters AI History by that cutoff while Conversation still shows the
originals. The Thread session generation increments, so Chat and Work start fresh
native sessions (local session files are not erased). Clearing the Conversation
deletes Discussion messages and Work with their canonical history. Active Work must
be cancelled before either.

## Boundaries

| Boundary | Responsibility | Implementation |
| --- | --- | --- |
| Workflow Engine | Steps, dependencies, prompts, lifecycle | Core planner; Cloud `workflow.ts` |
| Execution Engine | Snapshot Worker/model/effort and policy; generic Step results | Cloud `execution-engine.ts` |
| Conversation Router | Continuity action and prompt preparation | Core `conversation-router.ts`; Engine `conversation_execution_router.dart` |
| Context Engine | Canonical and workflow context | Core `context-engine.ts`, fed by Cloud |
| Worker Engine | Validate local state and the signed Profile contract; supervise the CLI, reconstruct, persist | `engines/cli_worker` |

Cloud never owns native handles; Connect owns session files, locks and diagnostics.
No provider-specific execution path exists in any of these layers.

## Verification

- Core: `packages/core/test/conversation-router.test.ts`, `context-engine.test.ts`,
  `conversation.test.ts`.
- Cloud (real PostgreSQL): `apps/backend/test/domain/conversations.test.ts`,
  `conversation-turns.test.ts`, `conversation-history.test.ts`,
  `conversation-bootstrap.test.ts`, `conversation-workflow-runs.test.ts`,
  `conversation-workflow-step-runs.test.ts`.
- Engine: `engines/cli_worker/test/conversation_execution_router_test.dart`,
  `worker_session_test.dart`, `engine_session_release_compatibility_test.dart`,
  `session_execution_lock_test.dart`.

These use fixture providers and establish deterministic behavior, not live-provider
acceptance.
