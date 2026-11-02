# Work v1 Contract

**Contract ID:** `work:v1`
**Status:** Frozen
**Scope:** Work composer and built-in Workflow semantics in Syntila

## Thread authored-content contract

Thread authored content is **GitHub-Flavored Markdown (GFM) source**.
AX edits and previews that source and renders it for reading. Existing ordinary
plain-text records remain valid Markdown; no content-format database migration
or record conversion is required in v1.

Rendered messages use one selection region across paragraphs, lists and code
blocks, allowing partial or whole-message selection. Copy Markdown preserves
the original source; copying a text selection copies the visible text.
Mouse selection follows vertical block order around horizontally scrollable
code and tables, including blocks nested inside quotes or lists. Dragging
on a later paragraph must not capture an earlier indented block.

Work history updates automatically; the composer has no manual history refresh
control. Error-specific retry actions remain available when synchronization fails.
Rendered messages retain their request identity during progress, submission
reconciliation, and history insertion, including their selection state.
The optional `submissionId` on `work_request.created` echoes the submission's
Idempotency-Key. AX reconciles the matching temporary entry before the HTTP
response arrives, preserving earlier responses and newer server state. Prompt
text is never used to correlate entries. No database migration is required.

A response renderer is scoped to its request and exact displayed text; changing
progress replaces that renderer without reusing another message’s Markdown state.

Chat and Work history open at the latest message and follow updates while the
reader is at the bottom. Scrolling up pauses following until the reader returns
to the bottom. Work sending (including keyboard submission) stays disabled only
while AX is preparing or submitting a request. The input remains editable while
a request is being prepared or executed so the user can draft the next request.
If a queued, running, or waiting request exists, Send remains available and first
asks whether to cancel that request before submitting the new one. The Workflows editor exposes
Profile-supported models, custom model IDs when allowed, and model-specific
efforts. For a one-step Workflow, the composer may temporarily override Worker,
model, and effort for the current request; those choices are never written to
Space or user Workflow settings.

The Space landing page renders an empty Thread view. Its optional Space
description appears at the top, followed by an optional Thread name field.
The Message | Ask AI switch sits immediately above the composer, leaving the
unused history area blank. The name field contains a Create Thread action, enabled
only for a nonempty trimmed name and the existing create permission. This
creates and opens the Thread without sending a message. Entered names are
limited to 22 displayed characters. Merely opening the page does not create a
Thread or read history for a draft identity. The first Chat/Work
submission creates a Thread through the existing collaboration mutation before
sending through the existing discussion/Work request APIs. The Thread name is
taken from the name field when populated, otherwise formed from complete
opening words, at most 22 displayed characters, with the
first word truncated only when it alone exceeds that limit. A failed creation
preserves the draft; a failed submission after creation retries in the same
Thread. While creation/submission is pending, both send actions are guarded.
The resulting Thread opens with the submitting composer mode and retains the other text draft.

A Thread is one **Conversation**. Chat messages and the Thread's Work Requests
share one timeline ordered by request time: each Work Request appears as the
same live Work card used by AI History, with the requester's prompt (right-
aligned for the viewer's own requests), Worker status, live activity, and the
answer or user-facing failure. These entries are projections of Work history,
not Chat messages, so they cannot be edited or deleted as Chat. Completed exchanges archived by a Work-history clear appear
as read-only `ai_request`/`ai_answer` Chat entries.

The Conversation composer has a **Message | Ask AI** switch. Message sends a
Chat message. Ask AI shows the existing Work composer (Workflow, Worker,
model, effort, attachments) and submits through the unchanged
Work Request path, so session continuity and cross-Worker context behave as
before. The persisted Thread tab state selects this switch: `chat` restores
Message, `work` restores Ask AI.

The input area keeps fixed Chat and Work buttons followed by More ▾, grouped
in one outlined track; Chat and Work explain themselves in tooltips. Selecting
another available Workflow from More replaces that label with its name and
marks the third control as active; its menu shows names and a selection mark. Chat or Work switches back in one click and restores the More
label. Only the active control is highlighted. Unavailable primary workflows
remain visible but disabled; More is disabled when no other workflows are available.
More always lists workflows in catalog order; selecting one never moves it.
The active control is shown by text color only, matching the composer's
Message / Ask AI rail, with no background fill. The existing
saved Thread selection remains in effect until changed. Selection affects the
next request, never an accepted or running request; history retains each request's
accepted workflow. Controls are guarded during request submission.

When AI History is exposed, the Thread header places icon-labelled
**Conversation** and **AI History** actions next to each other. Each pane
highlights its active label in white and the other in grey; selecting
Conversation closes AI History. Switching panes positions the destination
timeline before revealing it, so intermediate scroll offsets are not painted.

**AI History** is hidden by default. A Space owner can expose it for every
Thread in that Space with the **Show AI History tab** switch in Space Settings.
The absent or false setting keeps it hidden; hiding it does not delete Work
history or session context. When exposed, the **AI History** header action opens
the former Work timeline read-only: full
execution status, activity, Worker identity, model details, retry, cancel,
and issue reporting, with no composer. At available widths of 1000 pixels or
more it appears beside the Conversation with a vertical divider inset
20 pixels; narrower windows show it instead of the Conversation. Select the
Conversation header action to return; there is no separate close icon or
read-only label. Clearing history is a confirmed header action of the pane it affects:
**Clear Conversation History** (Chat messages, including archived AI answers)
in the Conversation header and **Clear AI History** (Work history and Worker
session context; completed answers are archived first) in the AI History
header. The sidebar Thread menu no longer offers either action.
Thread content is capped at 800 logical pixels per pane, each pane has
20 pixels of side and bottom padding, and composers stay fixed. At the wide
breakpoint the Chat composer shows Markdown formatting controls without a
visibility toggle and places Send at the right of that toolbar.

The canonical values remain strings:

- Chat: `discussion_messages.body`.
- Human Work prompt: Work Request `originalRequest`.
- Worker response: `finalText`.
- Individual Step response: `resultText`.

Cloud stores the original source and passes the original human text through the
Work Request snapshot to Workers. Markdown must not be converted to HTML or
visible plain text before submission or execution. Generated HTML, parsed ASTs,
and renderer-specific data are not persisted. Rendering is an AX concern;
Cloud remains provider-neutral. Diagnostics and stable error codes are plain
text, not authored Markdown.

There is no `contentFormat` field in this change. Introduce an explicit versioned
format contract only if multiple formats (such as diagrams, structured blocks,
or HTML documents) become a concrete product requirement.

## Runtime and admission

Cloud encodes durable Work session identities as `work-session-` plus a SHA-256
hex digest. Keys satisfy the Engine's opaque identifier contract
(`[A-Za-z0-9_-]+`, at most 256 characters). Work keeps the same identity across
requests in a Thread; Chat has a separate Thread-scoped identity and
other Steps remain request-scoped. Fresh retries get
distinct keys. This changes no persisted schema; previously rejected colon-based
keys never created usable Engine sessions.

AX exposes explicit repository read, repository write, and shell execution
choices when connecting a Workspace. Workspace owners can edit an active or
suspended Space grant through `PATCH /api/workspace-space-grants/:id` with
`allowedPermissions`; the existing permission validator, ownership check, and
terminal-state restrictions apply. Omitted permissions remain unchanged.
Work (`direct`) requires `repository:read` and `repository:write`; Test also requires
`shell:execute`. AX never widens permissions merely because a run was denied.
Run admission errors are selectable and have a copy action for the full message.

This is the single authoritative catalog and semantic definition for Work v1.
Architecture v8 preserves Workspace ownership, Thread isolation,
Cloud/Workspace transport, AX-owned Worker usage policy, and the Workspace
desktop lifecycle. Work v1 binds logical Workers and is intentionally
independent from the underlying Engine/Profile implementation. See
[Persistence Contracts](PERSISTENCE.md),
[Architecture v8](../architecture/ARCHITECTURE_V8.md), and
[ADR-011](../decisions/ADR-011-thread-working-directories.md) for the
matching runtime lease and local directory rules. A Work v1 Workflow describes
the user-visible shape of a Work Request; it does not select a Worker, provider,
model, Workspace, or execution permission.

The product flow is:

~~~text
Syntila defines canonical Steps
      ↓
Syntila defines valid built-in Workflows
      ↓
User Workflow Configuration supplies execution defaults and step overrides
      ↓
User selects a Workflow and enters a request
      ↓
Cloud resolves execution, freezes WorkflowRun/StepRun configuration, and composes Step prompts
      ↓
Workers execute
~~~

AX reads Workflow names and descriptions from the built-in catalog endpoint,
which spaces the shared core definitions. The composer selects the current
Thread default on load; it does not maintain its own Workflow name list.

## Step kinds

`StepKind` is the closed set below. These meanings are provider-independent and
must be used consistently in Work UI, persisted Workflow snapshots, APIs, and
tests.

| `StepKind` | Meaning |
| --- | --- |
| `chat` | Respond conversationally using authorized Thread context. Inspect files and use provider-supported read-only commands; do not modify files, dependencies, or repository state. Return natural Markdown. |
| `research` | Gather and summarize relevant evidence from the request and authorized context, including findings, available sources/references, constraints, uncertainties, and recommended next actions. Do not make requested changes. |
| `synthesis` | Compare all required independent Research reports and return one attributed outcome. Treat reports as evidence, preserve disagreements and uncertainties, and remain read-only. |
| `plan` | Turn the request and available evidence into an ordered implementation plan and clear completion criteria. Do not make requested changes. |
| `implement` | Make the requested changes in the Thread execution context. |
| `test` | Run relevant tests or validation against the implementation and report commands/results. Do not intentionally change product source as part of the test step. |
| `verify` | Independently compare the result and available evidence with the request and completion criteria; report confirmed outcomes, gaps, and risks. Do not implement fixes. |

`review` is not a v1 `StepKind`; review and acceptance checking are represented
by `verify`. Step kinds are semantic labels, not provider roles or Worker IDs.

## Workflow identities and versions

`WorkflowId` is the closed set of stable identifiers:

```text
chat
direct
research
plan_implement
implement_verify
full_cycle
```

Each definition has an immutable version. The v1 reference is written
`<WorkflowId>:v1`, for example `full_cycle:v1`. Display names are labels and
are not persisted identity keys. An existing version's ordered steps and
semantics never change; a future contract change requires a new version.

The current `direct` definition is `direct:v2`, displayed as **Work**, with
description "Implement the requested work." and the same single `implement`
Step as v1. `direct:v1` remains immutable with the canonical name **Direct**.
New requests using the stable `direct` ID default to v2. Saved requests retain
and validate their original Workflow snapshot and version; they are not rewritten.
AX offers the latest version of each ID for new requests while using the full
catalog to display historical versions. The API catalog includes both versions.

Research v2 (ADR-026) runs independent researchers within the Workspace's
shared parallel-slot budget, then synthesis after every researcher succeeds.
Excess branches remain durably queued; Research capacity waits do not consume
the provider execution deadline. A single free slot is sufficient to run the
graph sequentially. The Thread shows completed reports immediately and queued
branches accurately. Readiness failures, permissions, cancellation and provider
execution deadlines remain enforced. Historical Research v1 and Full Cycle
keep their accepted definitions.

The core domain uses `BuiltinWorkflowDefinition` and `BuiltinWorkflowStep`:

```ts
type StepKind = "chat" | "research" | "synthesis" | "plan" | "implement" | "test" | "verify";
type WorkflowId =
  | "chat"
  | "direct"
  | "research"
  | "plan_implement"
  | "implement_verify"
  | "full_cycle";

interface BuiltinWorkflowDefinition {
  id: WorkflowId;
  version: number;
  name: string;
  description: string;
  steps: BuiltinWorkflowStep[];
}

interface BuiltinWorkflowStep {
  id?: string; // stable instance ID; omitted historical steps use their kind
  kind: StepKind;
  order: number;
  executionMode: "stateless_read" | "stateful_thread";
  executionClass: "analysis" | "workspace_action";
  requiredCapabilities: WorkflowCapability[];
  readWritePolicy: "read_only" | "write_thread";
  timeoutMs: number;
  promptProfileVersion: string;
  dependsOn: StepKind[]; // fixed by the built-in definition
  inputsFrom: StepKind[]; // fixed upstream step results
  dependsOnSteps?: string[]; // instance dependencies for repeated kinds
  inputsFromSteps?: string[]; // instance report inputs for synthesis
  resultSemantics: WorkflowResultSemantics;
}
```

`WorkflowCapability` is a closed, provider-neutral set: `authorized_context_read`,
`thread_write`, `test_execution`, and `independent_verification`.
`WorkflowResultSemantics` is likewise closed: `conversation_response`, `evidence_summary`,
`implementation_plan`, `thread_changes`, `test_report`, and
`verification_report`. Step definitions set their required capabilities,
read/write policy, execution class, timeout, internal prompt profile, fixed
upstream inputs, and result semantics. These values are owned by Syntila and
are part of the immutable Workflow version.

## Before submission

Selecting a Workflow Workspace authorizes Cloud scheduling for its ready,
locally enabled Workers. Inventory synchronization reconciles that scheduling
state for Workers configured or verified after the selection, and also repairs
existing disabled scheduling rows on unchanged inventory reports. It does not
enable locally disabled or unready Workers, and preserves draining Workers and
Cloud concurrency limits. Assignment admission still checks active grants,
permissions, Workspace connectivity and Thread policy independently.

Before creating a Work Request, Cloud resolves every required Step binding and
checks that each Worker exists, belongs to an active Space Workspace grant,
is enabled locally and for Cloud scheduling, and is Ready. Cloud also checks
that the grant allows the permissions needed by the Step. Any explicitly configured model must
be permitted by the Thread execution policy; if that policy has an explicit
model allowlist, a model must be selected from it.

The composer requests this eligibility check before submission and presents
issues grouped by Step. Cloud repeats the checks when creating the Work Request,
so a changed grant or Worker state cannot slip through after the composer
check. An ineligible Workflow does not create a Work Request or Run.

The v1 step policy is:

| Step | Execution class | Required capabilities | Read/write policy | Result |
| --- | --- | --- | --- | --- |
| `chat` | `analysis` | `authorized_context_read` | `read_only` | `conversation_response` |
| `research` | `analysis` | `authorized_context_read` | `read_only` | `evidence_summary` |
| `plan` | `analysis` | `authorized_context_read` | `read_only` | `implementation_plan` |
| `implement` | `workspace_action` | `thread_write` | `write_thread` | `thread_changes` |
| `test` | `workspace_action` | `authorized_context_read`, `test_execution` | `read_only` | `test_report` |
| `verify` | `workspace_action` | `authorized_context_read`, `independent_verification` | `read_only` | `verification_report` |

Chat has a single `chat` Step with `executionMode: stateless_read`, prompt profile
`chat:v1`, and no dependencies or upstream inputs. It has its own `chat` binding;
it is not part of Full Cycle or any implementation Workflow.

Each step currently has a 15 minute default timeout. `inputsFrom` names the
exact fixed upstream results supplied to the step; it is intentionally
different from task dependencies when an earlier result is relevant. The
provider-neutral capability names describe what the step needs from an
execution environment without selecting a Worker or tool.

## Internal Step Prompt Profiles

`chat:v1` answers conversationally with bounded user request, Space and
Thread instructions, Chat-specific additional instructions, and attachment
or reference metadata. Files are referenced through the existing assignment
input paths. Chat may inspect the current Thread directory and repository
state using provider-supported read-only commands. It must not create, modify,
delete or rename files, change Git state, install or update dependencies, or
perform implementation work. Modification requests receive an explanation and
guidance to use Work mode. Responses use natural language and Markdown.
The assignment's `readOnly` policy enforces the existing generic Workspace and
Tool Profile sandbox path; the prompt does not grant writable access.

Cloud derives `TaskToDispatch.readOnly` from the snapshotted Step's
`readWritePolicy`; the step definition is authoritative. Workspace maps
`readOnly: true` or `executionClass: stateless_read` to
`WorkerExecutionPolicy.providerDefault`, and writable stateful assignments to
`WorkerExecutionPolicy.restricted`. Workflow names, UI mode labels and provider
identities never select these permissions. Tool Profiles translate the generic
policy to provider arguments. The current ChatGPT Profile expands
`provider_default` to `--ask-for-approval never --sandbox read-only` and
`restricted` to `--ask-for-approval never --sandbox workspace-write`, including
when resuming a conversation. No additional provider-specific flag is used.

Cloud renders prompts through the single Work v1 prompt renderer. Its fixed
profiles are `chat:v1`, `research:v1`, `plan:v1`, `implement:v1`, `test:v1`, and
`verify:v1`. A Workflow step's `promptProfileVersion` selects exactly one
matching profile. The renderer consumes structured request text, attachments,
Space and Thread instructions, step-specific instructions, authorized
upstream step results, and current Thread context. It applies bounded input
limits. Work (`direct:v2`) is the writable one-step fast path: it preserves the submitted request
as the first prompt content, then adds only configured Space, Thread, and
Work instructions (Direct for historical v1) plus a short hidden instruction to act in the authorized
Thread and return the result. Other Workflows begin with their fixed
StepKind instructions and include only the authorized handoff data for that
Step.
Profiles are internal, versioned Syntila instructions used by Cloud's prompt
renderer. They are not a user-facing template language: users cannot edit the
Syntila instructions, insert macros, or control handoff composition. Users
can specialize a run only through the bounded Space, Thread, and
Step-specific additional-instruction fields defined below.

## Team collaboration and authorization

Work belongs to the shared Space and Thread. A Space owner or
collaborator may submit a Work Request only when the member also passes the
Thread's execute-access policy and the Space permission check. Viewers
cannot submit Work. Cloud enforces these checks when creating the request; the
composer's eligibility check is informational and is not an authorization
boundary.

Space members who have Thread view access may inspect its Work timeline
and Run Details, including Work submitted by another member. Thread access
policy still controls visibility. Read access does not grant execution or
configuration rights.

Changing the Thread's default Workflow, Step bindings, or Thread
instructions requires Thread configuration access (`spaces:write` plus
the Thread manage rule). In the current model, that means a Space owner
or the collaborator assigned as Thread lead. Cloud enforces this on every
configuration write, and the UI uses the server-projected `canConfigureWork`
capability to disable unavailable controls.

Every Work Request stores the authenticated submitter as
`requestedByUserId`; clients cannot choose or override this identity. Work
history and Run Details resolve the member's display name and show who
requested the Run. The immutable requester identity remains attached to the
Work Request even if membership or display-name data later changes.

## Conversation Workflow ownership

Current `chat:v1` and `direct:v2` requests acquire a persistent Conversation
association at acceptance, with separate product Workflow IDs `chat` and `work`.
Associations and acceptance revisions are separate from immutable execution
snapshots. Existing multi-step and historical requests are preserved. This
foundation does not alter native session scopes or add context replay; see
[Conversation Continuity v1](CONVERSATION_CONTINUITY_V1.md).

Workflow control metadata now declares user Worker/model/effort selection,
Step/Worker multiplicity, automatic continuation and inter-Step approval behavior.
The composer consumes the catalog policy and `composerBindingId`, rather than
inferring a global Worker from Workflow names or the first graph Step. Model
effort choices remain Profile-constrained. See
[Workflow execution policy](CONVERSATION_CONTINUITY_V1.md#workflow-execution-policy-phase-2).

Changing composer model or effort does not append a conversation message. Chat
and Work responses keep recorded model/effort in a compact hover/tap detail beside
the Worker name, rather than repeating the configuration in each visible header.
Historical details follow the displayed Worker turn, including explicit default
selections; current composer choices never rewrite them.

Failed responses and request details use plain-language execution messages.
Native session identifiers, resume statuses, assignment IDs, runtime versions
and raw error codes belong in Workspace/Engine logs and Profile Lab diagnostics,
not ordinary Chat/Work details. Recovery notices require confirmed recovery;
an error alone never implies that the conversation context was restored.

## Step handoff semantics

The renderer passes only these inputs for each step. It does not append prior
Worker messages or conversational sessions.

Chat and Work share one durable logical session scope per Thread:
`thread:<threadId>:conversation` (plus `:gen-<n>` after a session reset).
Both workflows write to the same Thread Conversation, so switching between
Chat and Work keeps the AI history. When the same Worker/Profile handles the
next request, it resumes the existing native session and receives only the
canonical delta; any other Worker, Profile, or an unsupported model switch
starts a session from the full canonical history. Read-only (Chat) versus
writable (Work) permissions are applied per execution, not per session.
The base is encoded using the existing Engine-safe SHA-256 key format.
Chat requests use `mode = stateless` and never enqueue with the Thread
mutation coordinator or acquire its lease. This does not change their durable
provider session or read-only filesystem policy. Work/direct remains stateful,
durable, and writable within its authorized scope. Request mode follows the
canonical Workflow Steps, not the selected provider or UI label. Chat and Work
turns require an explicit retry after failure to avoid automatically replaying
an ambiguous turn into a durable conversation.
The existing fresh-retry suffix applies to Chat as well as Work.
Multi-step Workflows use a
separate durable scope for each Work Request and Step:
`work-request:<workRequestId>:<stepKind>`. Retries resume only their own
Step's session; Verify never resumes Implement's session, even when both use
the same Worker. The provider's actual session identifier remains local to the
Worker; downstream prompt handoff is always the bounded upstream
`StepResult.text` rendered by Syntila.

Every completed Step uses the same Syntila-owned `StepResult` wrapper:

```ts
interface StepResult {
  text: string;
  status: "completed" | "failed" | "cancelled";
  startedAt: string;
  completedAt: string;
  workerId: string | null;
  workerTypeId: string | null;
  engineVersion: string | null;
  profileDefinitionId: string | null;
  profileReleaseVersion: number | null;
  providerToolVersion: string | null;
  model: string | null;
  artifacts?: string[];
  changedFiles?: string[];
  testStatus?: "passed" | "failed" | "blocked" | "not_run";
}
```

The Worker final answer is plain text in `text`; Workers do not produce an
arbitrary JSON schema for Step-specific results. Syntila supplies attribution
and optional structured metadata only when it can derive them reliably. A
following Step receives the upstream result text (conceptually
`previousStep.text`) along with its other fixed inputs; result metadata and
provider conversation history are not appended to the prompt.

When a Workflow completes, its final Work answer is the terminal Step's text;
for `full_cycle:v1` this is Verify's report. The timeline keeps the ordered
Step states and selected Worker attribution as Syntila's execution summary.
When the Test report contains recognizable pass/fail/skip counts, Syntila
surfaces those counts separately as a short Test summary.

## Run details and observability

The Work timeline stays concise and links to a separately loaded Run details
view. Details use the immutable Work Request and Step records and show the
Workflow ID/version, original request, and each Step's status, assigned Worker,
Workspace and Engine versions, provider tool version when known, start/end/duration,
and bounded final result text. A queued Step may have no start time; a running
Step has elapsed time through the time details are loaded and no end time.

Advanced details may show the latest assignment ID, session policy, and stable
error code. Raw provider error strings, provider secrets, credential
environment, prompts/files by default, and local Worker logs are not included
in Run details. Results are truncated to a fixed safe display bound. Logs stay
local to Workspace and require an explicit diagnostic workflow to retrieve.

Cloud persists Step start and finish timestamps so duration reflects execution
rather than queue time. Older in-development records without these timestamps
fall back to available Step output or assignment timestamps.

| Step | Handoff |
| --- | --- |
| `research` | Original request, attachment contents, Space and Thread instructions, Research-specific instructions. |
| `plan` | Original request, attachment metadata, Research result if present, Space and Thread instructions, Plan-specific instructions. |
| `implement` | Original request, relevant Research result, Plan result if present, Space and Thread instructions, Implementation-specific instructions, and access to the writable Thread filesystem. |
| `test` | Original request, Plan result, Implementation result, Space and Thread instructions, Test-specific instructions, and current Thread filesystem. Test may run existing tests, builds, lint, and typecheck commands, but cannot edit application, test, configuration, or dependency files or fix failures. Requests to add tests are implemented in the Implement step, then checked by Test. |
| `verify` | Original request, relevant Research and Plan results, Implementation result, Test result if present, Space and Thread instructions, Verify-specific instructions, and the current Thread filesystem. Verify holds the active Thread lease for filesystem identity, but its effective permissions and provider execution are read-only; it uses a fresh Work Request-scoped Verify session. |

These result selections are recorded in each built-in step's `inputsFrom`.
Research v2 is the current Research definition (independent researchers on
different models plus synthesis, ADR-026), behind the development preview
gate until release acceptance is complete. Research v1 remains historical.
Research requires the
requester's Syntila Plus (`workflow.research`).

Research receives attachment contents; Plan receives attachment metadata only;
later steps receive neither. Current filesystem context is supplied only to
Test and Verify. Missing optional results are omitted. Selection is controlled
by the immutable Workflow definition and StepKind.

## Manual retry semantics

Retry is a user action on one failed Step in a failed Work Request. The retry
reuses the exact stored Work Request input, Workflow version, bindings, model
selections, instructions, attachment references, and prompt profile versions.
Completed upstream Steps are reused from their stored `StepResult`; only the
selected failed Step and its remaining downstream Steps execute again. A retry
creates a new Run record and retains prior assignment records for diagnostics.
There is no automatic Verify-to-Implement feedback loop.

The Work tab's Worker response bubble does not display an inline retry icon;
removing that affordance does not change the retry API or the stored execution
and diagnostic records described above.

An Implement retry requires an explicit session choice. Known pre-execution
failures such as provider unavailability, authentication, quota, missing CLI,
unsupported model/version, and permission denial recommend resuming the previous
session. Timeouts and internal/unknown failures recommend a fresh session
because the provider may have partially processed the turn. The user can
choose either option. A fresh retry gets a new logical session key; resume uses
the original Work Request and Step key. Other Step retries reuse only their own
Work Request-scoped session.

Retry admission rechecks the selected Worker's current readiness, Space grant,
capabilities, and permissions against the immutable binding snapshot. A failed
Run can be cancelled to close it without retrying. Repeated retries happen only
after another explicit user action.

Step identity and task role are the canonical `StepKind`; there is no separate
free-form `role`. A step's `executionMode`, read/write policy, timeout, prompt
profile, order, and dependencies are product-owned values. The current fixed
execution modes are `stateless_read` for `chat`, `research` and `plan`, and
`stateful_thread` for `implement`, `test`, and `verify`. A stateful
Work Request is one whose selected Workflow contains a `stateful_thread`
Step. Cloud acquires one Thread runtime lease before that request starts and
holds it through a terminal state; a stateless-only Work Request has no lease.
The request-level lease prevents another stateful Work Request from
interleaving between Steps and keeps all stateful Steps on the Primary
Workspace. Research and Plan remain stateless and read-only, and may run on
another eligible granted Workspace even while their Work Request holds a lease
for later stateful Steps. A stateful read-only Step keeps that lease to inspect
the exact current filesystem, while its effective permissions exclude
repository write. Shell
execution is withheld except for Test, which needs it for validation commands;
Test still has read-only effective filesystem permissions. Workspace passes
the explicit policy through the generic CLI Worker Engine, which applies the
signed Tool Profile's bounded provider CLI arguments and sandbox settings.
Verify always uses its own Work Request-scoped provider session, including when
the same Worker performed Implement.

## Built-in catalog

This table is the authoritative built-in Workflow set for the Work v1 contract.
Except Research v2, steps run in the listed order and depend on the preceding step. `direct`
means one direct implementation step, not a separate `StepKind`.

| Workflow reference | Display name | Fixed steps |
| --- | --- | --- |
| `chat:v1` | Chat | `chat` |
| `direct:v1` | Direct (historical) | `implement` |
| `direct:v2` | Work (current) | `implement` |
| `research:v1` | Research (historical) | `research` |
| `research:v2` | Research (current, preview) | 2–4 independent `research` instances → `synthesis` after all succeed |
| `plan_implement:v1` | Plan & Implement | `plan` → `implement` |
| `implement_verify:v1` | Implement & Verify | `implement` → `verify` |
| `full_cycle:v1` | Full Cycle | `research` → `plan` → `implement` → `test` → `verify` |

Canonical definition shape:

```yaml
contract: work:v1
workflows:
  - id: chat
    version: 1
    name: Chat
    steps: [chat]
  - id: direct
    version: 1
    name: Direct
    steps: [implement]
  - id: direct
    version: 2
    name: Work
    steps: [implement]
  - id: research
    version: 1
    steps: [research]
  - id: plan_implement
    version: 1
    steps: [plan, implement]
  - id: implement_verify
    version: 1
    steps: [implement, verify]
  - id: full_cycle
    version: 1
    steps: [research, plan, implement, test, verify]
```

This catalog fixes the complete step sequence for each reference. The
Thread may choose a default built-in, and an authorized Work Request may
select one of the same built-ins. A submitted request snapshots its exact
Workflow reference and resolved steps so later releases cannot reinterpret a
run already created.

## Persistence

The built-in catalog is code/versioned product data. Cloud does not look up a
Workflow definition in a database. Each Work Request stores `workflow_id`,
`workflow_version`, and the complete immutable `workflow_snapshot_json`.
Execution records refer to the Work Request; the snapshot is the source for
their Workflow semantics. When a built-in gets a new version, retain the old
catalog entry so existing snapshots remain verifiable and reproducible.
Cloud serves the authoritative definitions at `GET /api/workflows/catalog` as
`{ workflows: BuiltinWorkflowDefinition[] }`. AX loads this response for
display and selection rather than maintaining a second Workflow list. Backend
validation and tests use the same shared core catalog.

AX's Work composer offers the newest catalog version of each stable ID:
Chat, Work, Research, Plan & Implement, Implement & Verify, and Full Cycle.
Work is the display name of `direct:v2`; submitted IDs remain `chat` or `direct`.
Settings expose independent Chat and Work bindings followed by Research, Plan,
Implement, Test and Verify, using dynamically registered Workers. AI Chat is a
Work Request Workflow, separate from the human/team Chat discussion tab and its
Discussion message storage. Both AI Chat and Work responses use the shared
`SyntilaMarkdownBody`; authored Markdown source remains unchanged.

History and Run details space the Workflow name from the immutable saved
snapshot, falling back to the exact versioned catalog entry when necessary.
AX carries this historical name in its Work Request read model and uses the
exact ID/version catalog lookup only for older responses without a name. Thus
`direct:v1` remains Direct, `direct:v2` is Work, and `chat:v1` is Chat even when
the current catalog has changed or has not loaded. Names never come from the
current Workflow ID alone.

Submission also captures a versioned execution snapshot in `snapshot_json`:

```ts
interface WorkRequestSnapshot {
  schemaVersion: 1;
  originalRequest: string;
  attachmentReferences: WorkRequestAttachmentReference[];
  workflowId: WorkflowId;
  workflowVersion: number;
  workflowSnapshot: BuiltinWorkflowDefinition;
  resolvedBindings: Partial<Record<"direct" | StepKind, ThreadStepBinding>>;
  spaceInstructions: string;
  threadInstructions: string;
  stepAdditionalInstructions: Partial<Record<StepKind, string>>;
  promptProfileVersions: Partial<Record<StepKind, string>>;
}
```

## Work Request attachments

Work v1 history and detail responses include an additive `attachments` array
with `kind: "file"`, `name`, `sizeBytes`, an optional opaque `fileId`, and optional
`previewText` / `previewImage` display fields. AX renders bevelled cards inside
the composer above its text control and below sent prompts in Conversation and
AI History. Cards are fixed squares; thumbnails fill them with centered cover
cropping. Cards show no filename, size, or info control. For draft
attachments, Close appears at the top right only while the pointer is over the
card and removes the attachment immediately without confirmation. History
cards show Download on hover. Clicking a card opens it: images open the
original bytes (draft content or an authenticated download) in an in-app
zoomable popup; other files are handed to the browser, which opens them in a
viewer tab or the operating system's default application. Text previews and a
generic file icon remain fallbacks when an image is unavailable. Original bytes
remain private in R2. Missing preview fields fall back to the generic file
icon; historical uploads are not
backfilled. The Worker protocol is unchanged.

AX creates a square JPEG thumbnail for PNG, JPEG, WebP and GIF files, limited
to 32,000 base64 characters. A JPEG that already fits the budget is used as its
own thumbnail. Otherwise AX center-crops to a square of at most 256 pixels
(sharp at 2-3x density on the 96 px card), downscales in halving steps with
high-quality smoothing, and encodes at quality 0.85, falling back to 0.75 and
0.6 to fit. Unsupported images/documents retain a file
card. Upload accepts the existing raw body or multipart `file`, `mediaType`, and
optional `previewImage` fields. Cloud validates the thumbnail envelope and stores
bounded text/image display data in a private R2 preview sidecar. When accepting a
request it copies verified display data into the saved attachment metadata, so
history needs no original-file download or per-card preview requests. Text
previews contain at most 1,200 bytes of decoded plain source and are never rendered
as active markup. D1 holds small display previews, never original file bytes.

`GET /api/threads/{threadId}/files/{fileId}` requires current Thread view access
and a reference from an accepted discussion message or Work Request. It returns
an attachment with `private, no-store` caching and `nosniff`. Opaque IDs are not
authorization tokens. AX downloads through its authenticated API client.

Attachments are inputs to a Work Request, not Workflow definitions. A request
may include local files and `http`/`https` references. The v1 composer accepts
up to 10 attachments. The per-file and total-storage limits depend on the
**uploader's** plan, in decimal bytes (see ADR-025): Free 25 MB per file and
1 GB total; Syntila Plus 100 MB per file and 25 GB total. The file dialog
allows multi-selection in both Ask AI and Message modes. Each selected file is
admitted in order: files over the plan's file limit, files that no longer fit
the remaining storage, and files beyond the remaining slots are skipped
individually and reported in one notice, while the rest are attached. Links are limited to 2,048 characters and may
not embed URL credentials. The client uploads each file to
`POST /api/threads/{threadId}/work-request-files`, which stores the bytes in R2
bound to the uploading user and Thread and returns a server-generated `fileId`.
Work Request creation accepts only `fileId` references that match that user,
Thread, and size; D1 stores metadata/URL references, bounded display previews and `fileId`, never original bytes.
Cloud reads the bytes from R2 when it sends `assignment.start`, so they are
transient on the wire and never persisted in D1.

Each upload also records a `user_files` row (migration `0086_user_files.sql`:
owner, Thread, Space, name, media type, size). The sum of a user's rows
(archived Spaces and Threads included) is capped by the uploader's plan; an
upload that does not fit gets 413 before anything is stored, with
`code: "file_too_large"` (over the per-file limit) or
`code: "storage_quota_exceeded"` (total allowance full). Each upload first
reserves its bytes atomically (`user_file_reservations`, migration `0098`), so
parallel uploads cannot overshoot, and the reservation is released on failure
or expiry. `GET /api/files` lists the
caller's files newest first (100 per page, `?before=<createdAt>` for more) with
`usage { usedBytes, fileCount, reservedBytes, quotaBytes, maxFileBytes }`, the Thread/Space names while the
caller can still open the Thread, and `inUse` when a discussion message or
Work Request cites the file. `DELETE /api/files/{fileId}` is owner-only: it
removes the R2 object and its preview and frees the quota only once storage
confirms (references never own bytes, so citing a file twice or removing one
citation cannot change usage). History that cited
the file keeps its name and size, and downloads return 404. The daily cron
deletes uploads older than a day that nothing cites, at most 100 per run. The
AX app shows all of this in My Files (`/files`). Its **Synchronize storage**
action calls authenticated `POST /api/files/sync`. The optional `phase`
(`storage` by default, then `records`) and `cursor` query parameters continue
bounded batches; responses contain `next { phase, cursor? }` or `null` and current
`usage`. AX follows continuations and reloads the list on completion. Failures
allow a retry; completed batches remain applied and are safe to repeat.

Synchronization scans only the `work-request-inputs/` prefix, recovering uploads
whose R2 metadata identifies the caller and original Thread, excluding previews.
It refreshes names, media types and sizes, and removes the caller's accounting
rows only after a successful R2 head confirms absence. It never deletes R2 bytes,
changes another user's records, or rewrites historical attachment references.
Older objects without ownership/Thread metadata cannot be recovered. Recovered
bytes count toward quota even if usage exceeds the limit. The scan traverses
the shared prefix in bounded pages, so duration grows with total stored uploads.
Concurrent uploads/deletions may require another synchronization; this is not
an atomic snapshot. Existing orphan cleanup still applies to recovered uploads.

Attachments are validated as bounded request inputs and are materialized inside
the authorized Space work directory. Worker/Profile capability metadata is not
used to admit or reject them; workflow policy and the Space grant's execution
permissions remain authoritative. URL references are ordinary text references
and do not request provider fetching by Workspace. Chat, Work, Research, and
Implement receive safe relative file references; Plan receives attachment
metadata, and Test/Verify use their defined handoff inputs.
Thread-local execution materializes file bytes under
`.syntila/inputs/<work-request-id>/file-NNN`; paths are derived from
server-generated request identity and attachment order, never accepted from
the client. The same materialized files are immutable across retries.

### File delivery

File inputs follow [Input Delivery v1](INPUT_DELIVERY_V1.md): the request is
accepted with a file manifest, AX uploads the files afterwards in parallel,
the target Workspace Service downloads each file over authenticated HTTPS as
soon as it is uploaded, and the Workflow dispatches the first step only after
every file is verified on the Workspace. `assignment.start` carries file
references (`fileId`, `contentDigest`), never file content.

This
does not add media-specific Workflows or imply that every provider understands
every file format. The current ChatGPT and Gemini releases declare `text` and
`local_file`; until a release explicitly declares more, image, audio, and video
attachments are rejected during eligibility validation.

```ts
interface WorkRequestAttachmentReference {
  kind: "file" | "url";
  name: string;
  mediaType: string;
  sizeBytes: number;
  fileId?: string;
  previewText?: string;
  previewImage?: string; // bounded JPEG base64, presentation only
  url?: string;
}
```

Cloud copies the selected binding and its Worker ID, model, fallback, and
additional instructions for each Step in the selected Workflow. Assignment
selection and prompt construction read these snapshots for a Work Request;
they do not consult later Thread bindings or Space/Thread
instructions. The submitted input and attachment contents are also retained
in `input_json`. Status and execution records may change, but the Workflow and
execution snapshots do not. Pre-snapshot Work Requests cannot be reconstructed
reliably and must be resubmitted in development environments.
The development baseline omits the former space-owned Workflow tables;
existing local databases created from that unreleased schema must be reset and
rebootstrapped rather than upgraded through a compatibility layer.

## Thread Work configuration

### Work execution path

Work Requests selecting Work use the configured `direct` Worker binding and hold a
Thread runtime lease for the request because Work contains the stateful
`implement` Step. Cloud dispatches the assignment to
the selected Worker's Workspace; the Workspace starts the generic CLI Worker
Engine, which resolves the signed Tool Profile and starts the provider CLI.
Work Requests, step progress, logical Worker and Engine/Profile/provider CLI attribution,
timing, and final results are available to AX through the Thread history
API. The timeline reconstructs from Cloud after page reload or browser restart,
and each Run retains its original request text. Work requests use the same
assignment dispatcher and Workspace execution path as Workflow Steps.

Work lifecycle changes publish durable Cloud realtime events: `work_request`
creation/start/completion/failure/cancellation and Step
queued/running/completion/failure/cancellation.
AX subscribes to the current Thread and refreshes the persisted timeline on
each matching event. Reconnect gaps trigger a full history refresh. The Run card
shows product Step names and states such as `running`, `done`, and `waiting`;
assignment identifiers and lease details remain out of the user-facing card.

Cancellation is available for queued and running Work Requests. For an active
assignment, Cloud waits for the Workspace runtime to acknowledge cancellation
after terminating the Worker and its provider process tree. If the Workspace
does not confirm termination, cancellation fails and the Run remains active so
the user can retry. On confirmation, the current Step and queued downstream
Steps become cancelled; completed earlier Step results remain available in Run
details. The timeline identifies the interrupted Step (for example, `Cancelled
during Implement`). A Work Request is not marked cancelled while its active
Worker process may still be running.

Each Thread stores one constrained `ThreadWorkConfig`:

```ts
interface ThreadWorkConfig {
  defaultWorkflowId: WorkflowId;
  threadInstructions?: string;
  bindings: Partial<Record<
    "direct" | StepKind,
    {
      workerId?: string;
      workerLabel?: { displayName: string; workspaceName: string };
      model?: string;
      fallbackWorkerId?: string;
      fallbackWorkerLabel?: { displayName: string; workspaceName: string };
      additionalInstructions?: string;
    }
  >>;
}
```

The binding IDs are fixed to `chat`, `direct`, `research`, `plan`, `implement`,
`test`, and `verify`. AX displays them in that order as **Chat**, **Work**,
**Research**, **Plan**, **Implement**, **Test**, and **Verify**. `chat` configures
Chat independently; `direct` remains the stable internal binding for Work
(and historical Direct). Each may select its own dynamic Worker, model,
additional instructions, and fallback; neither restricts the provider. Other
IDs configure the corresponding canonical Step across built-in Workflows. A
missing binding fails closed when that Step is scheduled. Cloud considers the
selected logical Worker and, if present, its one fallback Worker. Model and
additional instructions are optional and remain attached to the selected
binding. No arbitrary role names, role-specific concurrency values, or
fallback-to-any policy are part of this contract.

Worker label fields are bounded presentation snapshots only. If a selected
Worker becomes unavailable, AX keeps its Worker ID and shows the saved label
with an explicit unavailable state and a user-controlled replacement choice.
Fallback Workers follow the same rule. Cloud may retain an unchanged stale
binding so unrelated Thread edits do not erase user intent; current
catalog, grant, and readiness checks still determine whether it can execute.

`threadInstructions` is an optional Thread-wide text field, bounded to
4,000 characters. Space instructions remain in Space settings, and each
Step may have additional instructions in its Worker binding. These three
user-editable instruction levels are appended after Syntila's immutable
StepKind guidance. The run-specific request remains a separate labeled input;
handoff data continues to be selected and supplied by Syntila.

AX may offer a one-click suggested setup using Ready Workers available through
Space Workspace grants. The mixed ChatGPT/Gemini suggestion and single-Worker
suggestions are UI conveniences only: they do not constrain the catalog or
execution model, and users may edit every binding afterward.

## Explicit non-goals for v1

- custom Workflow creation;
- drag-and-drop Workflow design;
- arbitrary step ordering;
- arbitrary macros or user-composed Workflow definitions;
- user-defined step dependencies;
- user-editable Syntila system prompts;
- custom conditional branches.

Workflow selection does not override AX-owned Step binding/model/fallback
policy, Cloud authorization, Workspace readiness, local permissions, or
Thread execution rules. The Work request text remains user input; Syntila
system prompts and the meaning of each `StepKind` remain product-owned.

## Workflow source

AX obtains current Workflow definitions from the shared built-in catalog and
must not maintain a duplicate Workflow list.


## Architecture v8 runtime note

Work v1 continues to resolve `chatgpt`, `gemini`, and future logical Worker IDs only. Workspace resolves the selected logical Worker to an admitted generic CLI Worker Engine plus official compatible Tool Profile locally. Workflow definitions and Step prompt semantics never depend on Profile IDs or provider CLI command formats.


## Chat catalog schema admission

Migration `0006_chat_workflow_admission.sql` admits `chat` in
`work_requests.workflow_id` and `workflow_tasks.step_kind`. Apply the ordered
migrations before deploying Chat execution. It rebuilds both tables atomically,
preserving snapshots, cancellation fields, task dependencies, leases and linked
runtime records with foreign keys enabled. Unrecognized schema additions abort
the migration for review. Never reset or rewrite historical Work Requests.

Discussion reads use the [versioned paging contract](DISCUSSION_PAGING.md). AX retains shared cached history across page disposal,
synchronizes on reopening, and reconciles optimistic sends and edits per message.


Work history initially loads the latest 50 Work Requests. Older requests load
on demand while scrolling upward or choosing Load older Work history, with the
viewport preserved. Shared in-memory history survives page disposal. Recent and
active refreshes merge status updates without reloading immutable older pages;
see [AX server-state ownership](../architecture/AX_SERVER_STATE.md).


Work lifecycle and Step events reconcile individual cached Work Requests.
Sufficient event state patches the cache; missing results or details use the
single-request endpoint. Healthy realtime performs no Work polling. During
outages, visible Threads use a fifteen-second active-entity fallback; restored
connections discover a bounded recent page and resynchronize known active IDs.
Immutable older history remains cached.

### Work timeline sender attribution

Preparation and queued/waiting execution notices display Syntila with its logo.
Once the current Step is running, its worker display name and worker-type icon
replace Syntila on the same response row, before final result text arrives.
Completed result rows retain their worker identity. System error notices retain
Syntila attribution. Icons use locally bundled provider assets for known worker
types; unknown types use the worker initial. Identity comes from immutable Step
metadata, never inferred from model names or response text.

### Profile-owned model and effort selection

The inventory additionally exposes version 1 `executionOptions`: generic model
selection/discovery, model-switch capability, and model-specific effort choices.
Cloud readiness/creation and the Engine validate selections independently;
provider-specific effort mappings remain signed Profile instructions. The composer prefers typed `executionOptions` and uses `modelOptions` as an
older-response fallback. See
[generic execution options](CONVERSATION_CONTINUITY_V1.md#phase-7--generic-worker-execution-options).

AX obtains `modelOptions` from the human Worker inventory projection. Cloud
spaces only model catalog and effort metadata from the published, non-revoked
Tool Profile release matching the installed worker, profile identity and version.
There are no provider/model lists hardcoded in AX. A missing catalog offers only
Default model. Effort options follow the selected model's declared supported
efforts, with profile-level efforts used only where the model inherits them.
Default model and Default effort omit overrides and let the provider CLI's local
configuration apply; catalog default effort is descriptive, not injected. Changing
model clears the prior effort override. Work uses the dedicated `direct` binding
for both picker updates and API execution; Chat uses `chat`. Thread bindings accept bounded
`reasoningEffort` strings, alongside model. Failed submissions retain the API's
specific error message so validation failures can be diagnosed.
This is an additive human API projection; no runtime schema or D1 migration is
required. Existing published profiles remain immutable; adding model catalogs
requires authoring and publishing a new signed release through Profile Lab.

Chat/Work Worker, model, and effort values sit beside Send as the effective
Space Workflow configuration. One-step Work requests can edit these controls
for the current request only; multi-step Workflows continue to use their
configured Space values. Workflow policy and signed Profile execution options gate the
values shown. See
[dynamic composer](CONVERSATION_CONTINUITY_V1.md#phase-8--dynamic-next-turn-composer).

Work creation pins the authoritative Worker/Profile release, nullable model and
effort, and Workflow identity/version in `snapshot.turnExecutionConfig`.
History exposes `executionConfig`; later default changes cannot modify it.
See [Conversation Continuity V1](CONVERSATION_CONTINUITY_V1.md) Phase 3.

Conversation-associated requests also expose ordered `turns` in history/details.
Each assignment (including retry attempts) snapshots actual selection evidence,
original user-message identity, logical session reference, base context revision,
and lifecycle timestamps. Historical turns never read current bindings/inventory
for Worker/Profile/model/effort attribution. See Conversation Continuity V1 Phase 4.


The Thread composer remembers model and effort choices per Worker and composer
binding while the form is mounted. Returning to a Worker restores its last valid
combination, including explicit Default choices. Catalog refreshes reconcile these
preferences; shared binding edits and Thread/Space/user/data-source changes
reset them. This local preference state does not change canonical Conversations or
historical turns. See [Conversation Continuity Phase 10](CONVERSATION_CONTINUITY_V1.md#phase-10--remember-next-turn-selections-per-worker).


## Conversation execution ownership

A Conversation user message owns a stable WorkflowRun, which groups Worker turns
across workflow steps and retry invocations. Existing runtime Runs are scheduler
attempts beneath that logical execution; Work Request owns lifecycle/configuration.
Chat/Work normally produce one Worker turn per initial execution without imposing
that cardinality on future workflows. The version 1 Work read model exposes
`workflowRun` separately from `turns`; see
[Conversation Continuity Phase 18](CONVERSATION_CONTINUITY_V1.md#phase-18--workflowrun-and-workerturn-ownership).


WorkflowRun now owns stable WorkflowStepRuns with distinct step identity/role,
execution selection, logical Session/context attribution, status and completed
result. Chat and Work materialize one queued StepRun atomically with acceptance.
Retries create Worker turns within that StepRun rather than new logical steps.
Work Request/task records retain lifecycle authority; run timestamps capture
first start and terminal transition evidence. See
[Phase 19](CONVERSATION_CONTINUITY_V1.md#phase-19--workflowrun-and-workflowsteprun-data-model).


## Simple conversation presentation

Chat and Work show user/Worker messages, Worker identity/icon, relevant progress
and next-turn selection. Internal WorkflowRun/StepRun records must not introduce
run headings, one-step counters, execution graphs or orchestration labels. Recovery
actions use request language; optional details lead with the Worker rather than
the internal step role. See
[Phase 20](CONVERSATION_CONTINUITY_V1.md#phase-20--simple-chatwork-presentation).


Future multi-step presentation has an explicit opt-in AX adapter, gated by pinned
workflow identity/version and the multiStep capability. It prepares definition-
ordered step labels/status, actual Worker/model/effort attribution and pending
choices from existing WorkflowRun/StepRun records. Current Chat/Work never enable
this presentation, including when metadata contains several steps. Rendering and
new workflow definitions remain deferred. See
[Phase 21](CONVERSATION_CONTINUITY_V1.md#phase-21--future-multi-step-presentation-capability).

### Thread management ownership

Space owners may rename, configure, archive, restore or delete any Thread.
Collaborators may create Threads and perform those operations only on a
Thread where they are the assigned lead. Creation sets the authenticated
creator as lead, so existing `lead_user_id` is the management-responsibility
boundary; this phase does not reinterpret or replace existing leads. Viewers
cannot create or manage Threads. View, Discuss and execution remain governed
by their existing access policy and are not reduced by hiding management actions.

Space Thread rows use the server's `canConfigureWork` result for management
menus, with an owner override. Space-wide Thread reordering is owner-only
in both UI and API, because it changes ordering for other members' Threads.
The creation response includes management/execution capabilities immediately,
without waiting for a collection refresh. Existing update/delete authorization
continues to reject cross-lead writes; UI visibility is not the security boundary.
No schema migration is required. Lead transfers are not exposed by this change.

## Global execution configuration

[User Workflow Configuration v1](USER_WORKFLOW_CONFIGURATION_V1.md) and
[ADR-019](../decisions/ADR-019-per-user-workflow-execution-configuration.md) establish
Definition → User Workflow Configuration → Execution Resolution → WorkflowRun →
StepRun. User preferences belong to neither Space nor Thread. Global defaults and
sparse fixed-step overrides resolve at acceptance, then Worker/Profile release,
model, and effort are immutable execution evidence. Reset clears the Worker and
uses `Auto` for model and effort.
Thread preference remains a future layer. A transient `executionSelection` may be
submitted only for a one-step Work request; it is capability-validated, overlaid
at acceptance, and never persisted as a preference. Apply v8 migrations 0018 and
0019; historical accepted snapshots are untouched.

Space Workflows provides shared execution overrides initialized from its owner's
global defaults. All Threads use the Space configuration. Saving forks a workflow;
resetting restores owner-global inheritance. Advanced execution controls remain
on global Workflows and this Space tab. Run snapshots retain accepted choices.

Workflow admission is restricted to the global or Space-selected Workspace.
Every Workflow step must name an explicit Worker from that Workspace; Cloud never
selects a replacement Worker. A confirmed Workspace change
resets scope preferences but leaves accepted execution snapshots and retries
unchanged. Workspace selection, grant authorization, and migration 0022 are
specified in [User Workflow Configuration v1](USER_WORKFLOW_CONFIGURATION_V1.md#workspace-selection).
