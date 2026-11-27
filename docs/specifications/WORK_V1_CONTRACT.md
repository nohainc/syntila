# Work v1 Contract

**Contract ID:** `work:v1`
**Scope:** Chat and Work requests, built-in Workflow semantics, prompts, handoff,
retry, attachments and request snapshots. Execution defaults are in
[User Workflow Configuration v1](USER_WORKFLOW_CONFIGURATION_V1.md); conversation
ownership, sessions and context are in
[Conversation Continuity v1](CONVERSATION_CONTINUITY_V1.md).

Work v1 binds logical Workers only. It does not depend on Profile IDs or provider
command formats; Connect resolves the Worker to the generic CLI Worker Engine and
its signed Profile ([ARCHITECTURE.md](../../ARCHITECTURE.md)).

## Authored content

Thread authored content is **GitHub-Flavored Markdown source**. Cloud stores and
forwards the original text unchanged; it never converts to HTML or plain text and
persists no rendered output or AST. Rendering is an app concern. Canonical
strings: Chat `discussion_messages.body`, human Work prompt `originalRequest`,
Worker response `finalText`, Step response `resultText`. Diagnostics and error
codes are plain text. There is no `contentFormat` field; add a versioned format
contract only if another format becomes a concrete requirement.

Chat messages and Work Requests share one Thread timeline ordered by request time.
Work Requests appear as live Work cards (requester prompt, Worker status,
activity, answer or user-facing failure); they are projections of Work history, not
editable Chat messages. A **Message | Ask AI** switch selects Chat or the Work
composer (Workflow, Worker, model, effort, attachments); Ask AI submits through the
Work Request path. The saved Thread tab state (`chat` / `work`) restores the
switch. AI History (Work timeline with execution status, retry, cancel and issue
reporting) is hidden unless the Space owner turns on **Show AI History tab**;
hiding it deletes nothing.

Send stays enabled while a request is queued, running or waiting; the app then asks
whether to cancel it before submitting. For a one-step Workflow the composer may
override Worker, model and effort for the current request only; the override is
never saved to Space or user settings.

The `work_request.created` event may carry `submissionId` (the submission's
`Idempotency-Key`) so the app can reconcile its temporary entry before the HTTP
response arrives. Prompt text is never used for correlation.

## Steps and Workflows

`StepKind` is the closed, provider-independent set below.

| `StepKind` | Meaning |
| --- | --- |
| `chat` | Respond conversationally from authorized Thread context. May inspect files and run provider-supported read-only commands; must not modify files, dependencies or repository state. |
| `research` | Gather and summarize evidence: findings, sources, constraints, uncertainties, next actions. No changes. |
| `synthesis` | Compare all independent Research reports into one attributed outcome; reports are evidence, disagreements are preserved, read-only. |
| `plan` | Turn the request and evidence into an ordered plan with completion criteria. No changes. |
| `implement` | Make the requested changes in the Thread execution context. |
| `test` | Run existing tests, builds, lint and typecheck and report results; must not edit source, tests, configuration or dependencies. |
| `verify` | Independently compare the result with the request and criteria; report outcomes, gaps and risks; no fixes. |
| `tool_call` | Call one consented MCP tool and record its result for a following `chat` Step (`chat:v2`); read-only, prompt profile `tool_call:v1`. |

`review` is not a StepKind; acceptance checking is `verify`.

`WorkflowId` is closed: `chat`, `direct`, `research`, `plan_implement`. Each definition has an immutable version written
`<id>:v<N>`; display names are labels, not identity. An existing version's steps
and semantics never change.

| Reference | Display name | Steps |
| --- | --- | --- |
| `chat:v1` | Chat | `chat` |
| `chat:v2` | Chat with tool | `tool_call` (one consented MCP tool) → `chat` |
| `direct:v1` | Direct (historical) | `implement` |
| `direct:v2` | Work (current) | `implement` |
| `research:v1` | Research (historical) | `research` |
| `research:v2` | Research (current, preview) | 2–4 independent `research` instances → `synthesis` ([ADR-026](../decisions/ADR-026-research-parallel-synthesis.md)) |
| `plan_implement:v2` | Implement (current, Plus) | `plan` (phased plan, approval, then phases queued; see [ADR-030](../decisions/ADR-030-implement-phased-workflow.md)) |

Except Research v2, steps run in order, each depending on the previous one. New
requests for the stable `direct` ID use v2; saved requests keep their accepted
snapshot. The app offers the newest version of each ID and uses the full catalog
(`GET /api/workflows/catalog`, `{ workflows: BuiltinWorkflowDefinition[] }`) to
display history. History names come from the saved snapshot, falling back to the
exact ID/version catalog entry, never from the current ID alone. The catalog is
code, not database rows, and the app keeps no second Workflow list.

```ts
type StepKind =
  | "chat" | "research" | "synthesis" | "plan" | "implement" | "test" | "verify" | "tool_call";

interface BuiltinWorkflowStep {
  id?: string;                 // instance ID; omitted for historical steps (= kind)
  kind: StepKind;
  order: number;
  executionMode: "stateless_read" | "stateful_thread";
  executionClass: "analysis" | "worker_action";
  requiredCapabilities: WorkflowCapability[];
  readWritePolicy: "read_only" | "write_thread";
  timeoutMs: number;           // 15 minutes by default
  promptProfileVersion: string;
  dependsOn: StepKind[];
  inputsFrom: StepKind[];      // exact upstream results supplied to this step
  dependsOnSteps?: string[];   // instance dependencies for repeated kinds
  inputsFromSteps?: string[];
  resultSemantics: WorkflowResultSemantics;
}
```

Capabilities are `authorized_context_read`, `thread_write`, `test_execution`,
`independent_verification`. Result semantics are `conversation_response`,
`evidence_summary`, `implementation_plan`, `thread_changes`, `test_report`,
`verification_report`.

| Step | Class | Capabilities | Read/write | Result |
| --- | --- | --- | --- | --- |
| `chat` | `analysis` | `authorized_context_read` | `read_only` | `conversation_response` |
| `research` | `analysis` | `authorized_context_read` | `read_only` | `evidence_summary` |
| `plan` | `analysis` | `authorized_context_read` | `read_only` | `implementation_plan` |
| `implement` | `worker_action` | `thread_write` | `write_thread` | `thread_changes` |
| `test` | `worker_action` | `authorized_context_read`, `test_execution` | `read_only` | `test_report` |
| `verify` | `worker_action` | `authorized_context_read`, `independent_verification` | `read_only` | `verification_report` |

Execution modes: `stateless_read` for `chat`, `research`, `plan`; `stateful_thread`
for `implement`, `test`, `verify`. Workflow selection never overrides Step binding
policy, Cloud authorization, Worker readiness, local permissions or Thread rules.
Custom Workflows, drag-and-drop design, arbitrary ordering, user macros, editable
system prompts and conditional branches are out of scope.

## Admission and authorization

- Work belongs to the shared Space and Thread. An owner or collaborator may submit
  only if the member also passes the Thread's execute policy and the Space
  permission check; viewers cannot. Thread view access allows reading the Work
  timeline and Run details, including others' requests, but grants no execution or
  configuration right. Changing a Thread's default Workflow, Step bindings or
  instructions needs Thread configuration access (`canConfigureWork`).
- Cloud stores the authenticated submitter as `requestedByUserId`; clients cannot
  set it.
- Before creating a request, Cloud resolves every Step binding and checks that each
  Worker exists, is usable by the requester, is enabled and Ready, and that the
  grant covers the Step's permissions. An explicit model must be allowed by the
  Thread execution policy. The composer's eligibility check
  (`POST /threads/:id/work-requests/validate`) is informational; Cloud repeats it on
  creation, and an ineligible Workflow creates no Work Request or Run.
- Assignment permissions derive from current Space rights, Worker eligibility and
  Step capabilities, and Connect enforces local permissions again.
- `TaskToDispatch.readOnly` comes from the snapshotted Step's `readWritePolicy`.
  The Worker maps read-only to `WorkerExecutionPolicy.providerDefault` and writable
  stateful work to `restricted`; Tool Profiles translate that policy into provider
  arguments (for ChatGPT, `--ask-for-approval never` with `--sandbox read-only` or
  `workspace-write`). Workflow names, UI labels and provider identities never
  select permissions.
- Research requires the requester's Syntila Plus (`workflow.research`).

## Sessions and mode

Durable session identities are `work-session-` plus a SHA-256 hex digest, safe for
the Engine's opaque identifier contract (`[A-Za-z0-9_-]+`, at most 256 characters).
Chat and Work share one logical scope per Thread, `thread:<threadId>:conversation`
(plus `:gen-<n>` after a reset), so switching between them keeps AI history; a
different Worker, Profile or unsupported model switch starts from the full
canonical history. Multi-step Workflows use `work-request:<workRequestId>:<stepKind>`
per Step, so Verify never resumes Implement's session, even on the same Worker.
Fresh retries get a new key. Chat requests are stateless (no Thread lease), Work is
stateful and durable, and both need an explicit retry after failure so an ambiguous
turn is never replayed automatically.

A request is stateful when its Workflow contains a `stateful_thread` Step. Cloud
takes one Thread runtime lease before it starts and holds it to a terminal state;
a stateless-only request holds none. The lease keeps stateful Steps on the Primary
Worker and stops another stateful request interleaving. Research and Plan are
stateless and may run on another eligible Worker while a lease is held. Verify
holds the lease for filesystem identity but is read-only. Test is read-only for
the filesystem but keeps shell access for validation commands.

## Prompts

Cloud renders prompts through one renderer with fixed internal profiles (for example
`chat:v1`, `research:v1`, `plan:v2`, `implement:v2`, `test:v1`, `verify:v2`,
`synthesis:v1`, `tool_call:v1`); a Step's `promptProfileVersion` selects exactly
one. Inputs are the request text, attachments, Space and Thread instructions,
Step-specific instructions, authorized upstream results and current Thread
context, all bounded. Work (`direct:v2`) is the one-step fast path: the submitted
request comes first, followed only by configured instructions and a short hidden
instruction to act in the Thread. Other Workflows begin with their fixed Step
instructions. Profiles are internal; users cannot edit them, add macros or control
handoff, and may specialize a run only through the bounded Space, Thread and
Step-specific instruction fields. `chat:v1` answers in Markdown, may inspect the
Thread directory read-only, and tells the user to use Work for modifications; the
prompt grants no access, the assignment's read-only policy does.

## Step handoff

The renderer passes only these inputs; it never appends earlier Worker messages or
conversations.

| Step | Handoff |
| --- | --- |
| `research` | Original request, attachment contents, Space and Thread instructions, Research instructions. |
| `plan` | Original request, attachment metadata, Research result if present, instructions. |
| `implement` | Original request, relevant Research and Plan results, instructions, writable Thread filesystem. |
| `test` | Original request, Plan and Implementation results, instructions, current Thread filesystem. |
| `verify` | Original request, relevant Research and Plan results, Implementation and Test results if present, instructions, current Thread filesystem, fresh request-scoped session. |

These selections are recorded in each Step's `inputsFrom`. Missing optional results
are omitted. Only Research gets attachment contents and only Test and Verify get
filesystem context.

Every Step produces a Syntila-owned `StepResult`: `text`, `status`
(`completed|failed|cancelled`), `startedAt`, `completedAt`, Worker and Engine
attribution (`workerId`, `workerTypeId`, `engineVersion`, `profileDefinitionId`,
`profileReleaseVersion`, `providerToolVersion`, `model`) and optional `artifacts`,
`changedFiles` and `testStatus`. The Worker's answer is plain text; downstream Steps
receive only the upstream `text`. A completed Workflow's final answer is the
terminal Step's text, and recognizable Test
pass/fail/skip counts are surfaced as a short summary.

## Retry

Retry is a user action on one failed Step of a failed Work Request. It reuses the
stored input, Workflow version, bindings, model selections, instructions,
attachment references and prompt profile versions. Completed upstream Steps are
reused; the failed Step and its downstream Steps run again, in a new Run, while
prior assignments are kept for diagnostics. There is no automatic Verify-to-
Implement loop. An Implement retry requires an explicit session choice: known
pre-execution failures (unavailable, auth, quota, missing CLI, unsupported
model, permission denied) recommend resuming; timeouts and unknown failures
recommend a fresh session. A fresh retry gets a new session key. Retry admission
rechecks readiness, grant, capabilities and permissions against the immutable
binding. A failed Run can be cancelled without retrying.

## Run details and provider failures

The timeline stays concise and links to Run details, built from the immutable
Work Request and Step records: Workflow ID and version, original request, and per
Step status, Worker, Worker and Engine versions, provider tool version, timing and
bounded result. Cloud stores Step start and finish times so duration excludes
queue time. Advanced details may show the latest assignment ID, session policy,
stable error code and provider failure fields. Ordinary Chat and Work show
plain-language failures only; session handles and raw codes stay in Connect/Engine
logs and Profile Lab diagnostics.

A failed assignment may carry an optional `providerFailure` (`schemaVersion: 1`)
next to the authoritative canonical error code and fallback message:

| Field | Limit | Rule |
| --- | --- | --- |
| `nativeErrorCode` | 128 bytes | Provider-supplied only, single line; never made up from an exit code. |
| `providerErrorText` | 4,096 bytes | Provider-supplied message. |
| `failedRunResponse` | 32,768 bytes | Final text returned with a failure; never promotes failure to success. |
| `source` | enum | `structured_error`, `result_message`, `stderr`, `stdout`, `plugin`. |
| `truncated`, `omitted`, `omittedFields` | — | Flags for byte truncation (on UTF-8 boundaries) and credential omission. |

The text fields total at most 40 KiB. ANSI and control characters are stripped
(except `\n` and `\t`). Provider text is arbitrary, so pattern scanning is not the
security boundary: the whole object is encrypted with authenticated encryption
before it reaches a Cloud or local table, using a 256-bit key from the
`provider-failure-key` systemd credential (`SYNTILA_PROVIDER_FAILURE_KEY` locally),
kept out of the database, source and logs. A missing or invalid key disables the
capability and received details are omitted (the canonical failure remains). Each
envelope records a non-secret `keyId`; rotate by installing the new key and listing
old ones in `provider-failure-previous-keys`. Known credential patterns cause the
whole affected field to be omitted and named in `omittedFields`. A Worker that
cannot decrypt a replayed failure sends `providerFailureUnavailable: true` (only
when Cloud advertises `assignment.provider_failure_unavailable.v1`, never alongside
`providerFailure`). Details follow ordinary Work authorization, are deleted with the
assignment record, never written to logs, activity or analytics, and are not stored
in the browser read cache. The app shows them as plain selectable text, marked when
truncated, omitted or unavailable. Local Worker Protocol 4.4 permits the field
behind the `provider_failure_details_v1` capability; older peers ignore it and keep
the canonical failure. MCP Worker fields use source `plugin`.

## Attachments and files

- A request may carry up to 10 attachments: local files (uploaded first) and
  `http`/`https` links (at most 2,048 characters, no embedded credentials). Per-file
  and total limits depend on the **uploader's** plan ([ADR-025](../decisions/ADR-025-plan-attachment-limits.md)):
  Free 10 MB and 1 GB, Syntila Plus 100 MB and 20 GB (decimal bytes). Files over
  the limit, that no longer fit, or beyond the remaining slots are skipped
  individually and reported once.
- `POST /api/threads/:id/work-request-files` stores bytes in R2 bound to the user
  and Thread and returns a server-generated `fileId`. Creation accepts only
  `fileId`s that match user, Thread and size. A `user_files` row records each upload;
  bytes are reserved atomically first, so parallel uploads cannot exceed the quota.
  Over-limit uploads get 413 with `file_too_large` or `storage_quota_exceeded`.
- `GET /api/threads/:id/files/:fileId` needs current Thread view access and a
  reference from an accepted message or request; it is served `private, no-store`
  with `nosniff`. IDs are not authorization tokens.
- The app builds a square JPEG thumbnail (at most 32,000 base64 characters) for PNG,
  JPEG, WebP and GIF; text previews hold at most 1,200 bytes of plain source. Cloud
  validates them, keeps them in a private R2 sidecar and copies the verified display
  data into the saved attachment metadata, so history needs no download. History and
  detail responses include `attachments` (`kind`, `name`, `sizeBytes`, optional
  `fileId`, `previewText`, `previewImage`). The database holds metadata, never file
  bytes.
- My Files: `GET /api/files` (newest first, 100 per page, `usage { usedBytes,
  fileCount, reservedBytes, quotaBytes, maxFileBytes }`, `inUse`),
  `GET /api/files/:fileId`, owner-only `DELETE /api/files/:fileId` (frees quota once
  storage confirms; history keeps name and size, downloads 404) and
  `POST /api/files/sync`, which recovers the caller's uploads from R2 metadata in
  bounded `storage` then `records` batches. It never deletes R2 bytes or touches
  another user's records. A daily job deletes uncited uploads older than a day (at
  most 100 per run).
- Delivery follows [Input Delivery v1](INPUT_DELIVERY_V1.md): the request is accepted
  with a manifest, files upload in parallel, the target Connect downloads and verifies
  each (SHA-256, size) and places it at `.syntila/inputs/<request>/file-NNN`, and the
  first Step dispatches only when every file is verified. `assignment.start` carries
  references, never content. Paths come from server identity and order, never the
  client, and are identical across retries.
- Media types are admitted by the Profile's declared input capabilities; until a
  release declares more than `text` and `local_file`, image, audio and video inputs
  fail eligibility.

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

## Persistence and snapshots

Each Work Request stores `workflow_id`, `workflow_version`, the complete immutable
`workflow_snapshot_json` and a versioned `snapshot_json`:

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

Assignment selection and prompt construction read these snapshots, never later
Thread bindings or instructions. Accepted execution choices
(`snapshot.turnExecutionConfig`, `stepExecutionConfigs`, exposed as
`executionConfig`) pin the Worker, Profile release, nullable model and effort and
Workflow identity, so later default changes cannot alter them. Old catalog entries
are retained so existing snapshots stay verifiable.

History loads the latest 50 requests and older ones on demand; discussion paging is
in [Discussion paging](DISCUSSION_PAGING.md), client caching and realtime in
[AX server state](../architecture/AX_SERVER_STATE.md). History responses add
`conversationId`, `workflowRun`, `turns` and nullable `executionConfig`
([Conversation Continuity v1](CONVERSATION_CONTINUITY_V1.md)).

## Execution configuration and Worker choice

Definition → User Workflow Configuration → Execution Resolution → WorkflowRun →
StepRun. User preferences belong to neither Space nor Thread; global defaults and
sparse per-step overrides resolve at acceptance, and the accepted Worker, Profile
release, model and effort are immutable evidence. A Space may override whole
Workflows (owner-edited, all Threads use it). Reset clears the Worker and uses
`Auto` for model and effort. Every Step must name an explicit Worker; Cloud never
substitutes another. A transient `executionSelection` is allowed only on a one-step
Work request and is validated, overlaid at acceptance and never saved. Thread-level
preference is a future layer. Details and Worker-selection rules:
[User Workflow Configuration v1](USER_WORKFLOW_CONFIGURATION_V1.md).

The composer reads Worker, model and effort options from the inventory's
`executionOptions` (with `modelOptions` as an older-response fallback), which Cloud
builds from the published, non-revoked Profile release matching the installed
Worker and CLI version. The app hard-codes no provider or model list; a missing
catalog offers only the default model. Default model and effort send no override,
and changing the model clears the effort override. Thread bindings accept bounded
`reasoningEffort` strings; failed submissions keep the API's specific error text.

## Thread management

Space owners may rename, configure, archive, restore or delete any Thread.
Collaborators may create Threads and manage only those where they are lead
(`lead_user_id`, set to the creator). Viewers cannot create or manage Threads.
Space-wide Thread reordering is owner-only. The UI reads the server's
`canConfigureWork`, but visibility is never the security boundary; update and delete
authorization are enforced server-side.
