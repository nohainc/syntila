# Worker Activity Protocol V1

Worker Activity is the provider-neutral live execution event contract carried
by the Local Worker Protocol. It supplements, rather than replaces, the
existing `progress` frame while consumers migrate. A Worker Engine may emit
both frames for the same provider output.

## Frame

An activity frame is one JSON object per protocol line with `type: "activity"`.
It contains `requestId`, `assignmentId`, `executionId`, `workerId`, `eventId`,
positive `sequence`, an ISO-8601 `timestamp`, normalized `eventType`,
`status`, and a safe bounded `title`. It may contain `activityId`,
`percentage`, and bounded `details`.

Normalized event types are `execution.started`, `model.started`,
`message.updated`, `tool.started`, `tool.completed`, `tool.failed`,
`model.status`, `execution.completed`, `execution.failed` and
`execution.cancelled`. Status values are `running`, `updated`, `completed`,
`failed` and `cancelled`.

The protocol enforces a 1 MiB frame limit. Activity details are limited to
16 KiB, four nested levels and 32 fields/items per object or array. Detail
keys are safe ASCII names and values are bounded JSON scalars, arrays or
objects only. Content-bearing selectors such as prompts, text, output,
commands, arguments, stdout/stderr and environment values are rejected for
activity details. Executable values, provider credentials and arbitrary
transformation code are not permitted.

## Ordering and terminal behavior

The Engine assigns a new sequence to every emitted activity, including
repeated tool calls that have the same type or percentage. Consumers should
deduplicate by `eventId`, ignore duplicate or late events, and buffer or mark
out-of-order events using `sequence`; they must not manufacture a new activity
from an old sequence. Every admitted execution emits `execution.started` and
exactly one terminal activity before its result/error frame. A terminal event
is not inferred from percentage.

## Profile mapping

Profiles may contain an optional `activity.mappings` array. Each mapping has a
bounded declarative `when` condition list, normalized `type`, `status`, static
`title`, and optional selectors for `activityId`, message and safe detail
fields. A mapping may include an optional percentage. Selectors use the same
bounded JSON selector grammar as existing Profile mappings. Unknown provider
events simply match no rule and are ignored; no provider-specific Engine branch
or executable Profile script is allowed.

The Codex and agy fixtures use the same mapping shape and produce equivalent
`tool.started`/`tool.completed` activity pairs even though their native event
names and nesting differ.

## Provider normalization

Profiles for the current Codex JSONL, agy stream-JSON, Claude Code
stream-JSON and Grok Build streaming-JSON formats may declare
`activity.adapter` (`codex-jsonl`, `agy-stream-json`, `claude-stream-json` or
`grok-streaming-json`) with
`activity.schemaVersion: 1`. The generic Engine uses the adapter only for
provider lifecycle families that the bounded selector grammar cannot represent:
tool failures, intermediate tool updates, missing provider identifiers,
malformed JSONL, and unsupported event shapes. Ordinary mapped events remain
owned by the declarative Profile mapping, so custom Profiles do not acquire a
provider branch.

Adapter output is safe status metadata only. It never forwards prompts,
messages, commands, arguments, stdout/stderr, tool output, credentials, or
provider error text. Missing tool identifiers receive a deterministic,
execution-local identifier and repeated invocations remain separate. The
Engine emits a bounded diagnostic activity once per diagnostic class for
malformed JSON, unsupported event shapes, and provider errors. Unsupported CLI
versions fail through the existing Profile compatibility gate before execution;
they are not silently normalized as a compatible stream.

The `grok-streaming-json` adapter reads Grok Build `--output-format
streaming-json`. It reports `Thinking` once per stretch of `thought` chunks
(thought text is never read), joins `text` chunks into one narration row per
segment between tool calls (re-reported at most every two seconds), and pairs
`tool_call` with the `tool_call_update` whose `status` is `completed` or
`failed` by `toolCallId`. Tool titles come from the tool name; the summary
reads only `command`, `pattern`, `query`, `url`, a file or directory name, or
`description` from `rawInput`, masked and bounded. Tool output is never read.
The final answer is built by the Profile's `append_final_text` /
`clear_final_text` actions, not by the adapter.

The `claude-stream-json` adapter reads Claude Code `--output-format
stream-json` messages. Tool calls live inside the `content` array of whole
`assistant` and `user` messages, which the selector grammar cannot index, so
the adapter inspects only block types, tool names and identifiers: an
`assistant` `tool_use` block becomes `tool.started` keyed by its `id`, a
`user` `tool_result` block becomes `tool.completed` (or `tool.failed` when
`is_error` is true) keyed by `tool_use_id`, and `thinking` and `text` blocks
become `model.status` and `message.updated`. Text, thinking, tool input and
tool results are never read into activity. The session `system`/`init` message
becomes `model.started`, so the Claude Profile declares the adapter with an
empty `mappings` list. Titles come from a fixed table keyed
by tool name. Messages arrive per completed assistant message; token-level
partial messages (`--include-partial-messages`) are intentionally not enabled
because they would multiply provider output against the Engine's output limit.

The official Codex Profile (`apps/profile_lab/assets/profiles/chatgpt.json`)
declares `activity.adapter: codex-jsonl` and maps the Codex `exec --json` item
types to user-facing activity titles: `reasoning` and `todo_list` to
`model.status` ("Thinking", "Updating the plan"), `command_execution`,
`mcp_tool_call`, `web_search`, `file_change` and `collab_tool_call` to
`tool.started`/`tool.completed` pairs keyed by `item.id`, `agent_message` to
`message.updated`, and an `item.completed` whose `item.status` is `failed` to
`tool.failed`. Codex reports a failed tool as a completed item with a failed
status, not as a separate event, so the failure mapping follows the completion
mapping for the same activity identifier. A Profile without an `activity`
block emits no activity at all, only coarse `progress` milestones.

The sanitized replay streams in
`packages/tool-profile/test/fixtures/{codex-events,antigravity-events}` cover
normal tool pairs, repeated calls, missing identifiers, provider failures, and
malformed lines. Real-provider acceptance remains opt-in because it requires a
locally authenticated provider account.

Profile Lab replays a bounded, sanitized Codex or agy JSONL fixture against the
candidate mapping before publication evidence is eligible for Cloud. The replay
is bound to the candidate digest and verifies normalized event types, statuses,
activity identifiers, safe scalar details, and repeated tool lifecycle pairs.
Unknown provider events are ignored. JSONL Profiles with declared activity
mappings and no passing fixture replay cannot publish; plain-text Profiles are
explicitly not applicable. Arbitrary transforms, scripts, prompts, model
content, terminal output, environment values, and credentials are rejected by
Profile validation.

Existing `progress` frames remain available for milestone consumers. Connect forwards normalized activity as `assignment.activity`; the assignment result or error remains the authoritative completion record.

## Integration evidence and diagnostics

The Engine integration harness runs the real Engine process against a
deterministic JSONL fixture CLI. It covers successful, failed, missing-terminal,
delayed, high-frequency repeated-tool, large-response, and concurrent Worker
executions. The fixture is intentionally provider-shaped rather than a second
adapter implementation, so the test exercises Profile discovery, process
supervision, JSONL normalization, activity emission, and terminal reconciliation
at the same boundary used by packaged Workers.

The Engine records a `missing_terminal_event` diagnostic whenever a JSONL
execution exits without a mapped terminal success, failure, or provider-error
event. A terminal result remains authoritative; the diagnostic explains why a
normal provider response was unavailable. Duplicate and reordered realtime
events are handled by event identity and monotonic stream/activity sequences.

## Cloud delivery and recovery

Cloud validates the Worker session fence and assignment identity before publishing an activity. The
payload is normalized and size-limited; provider JSON, terminal output,
reasoning and arbitrary tool output are not stored.

Lifecycle and tool events are replayable. Cloud persists their sanitized
envelopes in the existing realtime event stream and a bounded
assignment-scoped history projection. `model.status` and `message.updated`
remain ephemeral. The event identity is derived from assignment, attempt and
source event identity, so retries are idempotent.

Realtime clients report their applied durable stream positions when subscribing. On subscription or reconnect, the realtime Gateway replays
events after the acknowledged sequence, suppresses duplicates, and emits a
gap signal when retained history cannot fill a sequence gap. The assignment
result/error remains the authoritative completion record; activity is
diagnostic and timeline state only.

The Work Request detail projection also returns the most recent bounded activity
history for assignments whose `worker_assignments.work_request_id` matches that
request. The projection carries the same sanitized identity, attempt, execution,
sequence, type, status, title, scalar details and timestamp fields as realtime
activity. AX merges this history with live events by event identity, so opening a
Work tab or reconnecting does not depend on receiving the original live event.
Activities from assignments that are not joined to the request's workflow task or
conversation turn are rejected at the Cloud gateway and are never projected.

## AX Work presentation

Syntila shows live Worker progress inside the normal Work response, with no
separate activity widget and no list of events. Three parts of the response
follow the live flow:

1. The sender (icon, name and model info) switches to the Worker as soon as the
   flow reports an execution in progress, without waiting for the step status.
2. The elapsed time next to the workflow name ticks from the execution start
   while the request is unfinished. Once the request is terminal, the
   server-reported duration replaces it.
3. The message body shows the current status from the flow (the latest
   unfinished tool or status title, "Starting worker…", "Working…" or
   "Wrapping up…") and is replaced by the real response, error or cancellation
   when the request finishes.

Progress combines three sources, resolved by `AxWorkProgress`:

1. The Work Request status is authoritative for every terminal state
   (Completed, Failed, Cancelled, Timed out, Lost). Activity never marks a
   request terminal.
2. Worker Activity is the fast signal. It supplies the current action, the
   execution start time and liveness. Only the latest attempt is used, so a
   retry does not inherit the failed attempt's action or start time.
3. Local submission progress and the step start time cover the phases before
   any activity exists and Workers that emit none.

A terminal execution activity freezes the elapsed time and shows "Wrapping
up…" while the request status is still unfinished. The client also re-reads
the Work Request once, shortly afterwards, if it is still unfinished; the
result and status remain the authoritative completion record.

Event timestamps are shifted by an estimated clock offset (the least-delayed
live event; offsets over two minutes are treated as late delivery and
ignored) and elapsed time is never negative. A running execution silent for 45
seconds appends "no recent updates" to the status line.

AX keeps activity state separate from Work messages and result text and never
renders raw provider JSON, chain of thought, terminal output or unrestricted
tool output. Activity state is bounded per assignment, replayed events are
deduplicated by event identity and attempt, and history from the Work Request
projection is merged with live events. Notifications are per assignment, so
only the affected response rebuilds, and bursts of replaceable `model.status`
and `message.updated` events are coalesced to a few updates per second.

## Engine ownership of unidentified tool events

When a provider adapter is present, a declarative tool mapping that yields no
activity identifier is dropped by the Engine. The adapter then assigns a stable
fallback identifier, so one provider invocation is reported once and pairs with
its completion. Diagnostic observations (`details.diagnostic`) describe the
adapter, not the Worker's work, and the AX Work tab never shows them as the
current action.

## AGY adapter

The `agy-stream-json` adapter follows the documented AGY `stream-json` output:
`init`, `step_update` (with `step_type` of `user_input`, `agent_response`,
`tool` or `checkpoint`, and `state` of `ACTIVE` or `DONE`) and `result`. A tool
step starts as `ACTIVE` and ends with `DONE` carrying `tool_info.error` on
failure. Start and end events share `step_index` within a conversation, which
is used as the pairing key when no `tool_id` is present. Older captures using
`tool_execution` and `COMPLETED` remain accepted. Text arrives as `text_delta`
fragments; the Work tab shows status only and never renders them.
