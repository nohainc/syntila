# Syntila Execution Activity V9

Provider observations form one normalized activity stream.
`assignment.activity` is the sole external activity transport; the Engine's private milestone frame is not forwarded as a second
timeline.

## Contract

An activity has a stable source event ID and a strictly increasing per-execution
sequence. The assignment envelope supplies Cloud correlation (`workerId`,
`threadId`, `workRequestId`, `runId`, `taskId`, `attemptId`, and
`assignmentId`); the Engine frame supplies `executionId`, `workerId`, and the
provider observation identity. Cloud assigns the realtime stream cursor.

The supported event types are:

`execution.started`, `model.started`, `model.status`, `message.updated`,
`tool.started`, `tool.completed`, `tool.failed`, `execution.completed`,
`execution.failed`, and `execution.cancelled`.

Activities may contain a title, safe scalar details, an activity/tool ID,
tool name, duration, and an explicit provider/profile percentage. Percentages
are never inferred from tool counts. Terminal lifecycle state remains owned by
the assignment result/error/cancellation path; terminal activity is an
informational mirror.

## Safety and delivery

Provider adapters and Profile mappings reduce provider JSONL before it reaches
the runtime protocol. Content-bearing fields (prompts, model text, tool
arguments, command output, file contents, environment values, credentials and
internal reasoning) are rejected or removed. Unknown provider events are
ignored or produce one bounded diagnostic activity.

`model.status` and `message.updated` are replaceable cosmetic updates. Tool
lifecycle and execution lifecycle events are never coalesced away. Cloud
persists a bounded replayable subset and deduplicates by assignment/attempt,
source event ID and provider sequence. AX merges live and historical activity
by event identity and never treats activity as the terminal result authority.

## Adapter boundary and fixtures

Declarative Profile mappings handle stable scalar provider events. Stateful
interpretation belongs to the generic Engine adapter boundary. The current
adapters are `codex-jsonl`, `agy-stream-json`, `claude-stream-json` and
`grok-streaming-json`;
adding a provider adapter does not change Cloud, Service or AX. Replay fixtures must be sanitized and may contain only provider event
shapes and safe identifiers, not prompts, output, credentials or file data.
