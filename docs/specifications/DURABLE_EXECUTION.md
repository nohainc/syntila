# Durable Work Execution

Syntila Cloud coordinates Work Requests in the Bun backend using PostgreSQL for shared state. A Work Request records its accepted Workflow and execution snapshot, run, tasks and Worker assignments. Cloud validates transitions; realtime delivery is a notification mechanism and is not the source of truth. See [Architecture](../../ARCHITECTURE.md) and [Work v1](WORK_V1_CONTRACT.md).

## Lifecycle

A request selects a Worker. Cloud checks current authorization, readiness and capabilities at admission and dispatch, and persists commands before notifying the Worker. Connect journals an assignment before acknowledging it. An admission acknowledgement is not evidence that the provider process has started; the assignment lifecycle records the later start and terminal outcome. See [ADR-033](../decisions/ADR-033-durable-events-outbox-and-command-inbox.md) and [ADR-035](../decisions/ADR-035-worker-targeted-execution.md).

## Terminal reconciliation

Connect records terminal state before delivery and resends an unacknowledged terminal result after reconnect. Cloud validates the current Worker session fence and assignment identity and applies terminal transitions idempotently. If a crash leaves an attempt that may have started, Connect does not launch a second Engine for that attempt; it reports a retryable failure so Cloud can decide on a new attempt. See [ADR-034](../decisions/ADR-034-connect-pairing-and-session-fencing.md).

## Identity and recovery

Work Request idempotency prevents a lost response from creating duplicate work. Durable events and their outbox rows commit with domain changes; a dispatcher recovers pending notifications after a process failure. Clients replay retained events or refresh authoritative state after a gap. Session fencing prevents an older Connect session from committing a late result. See [Event Streams](EVENT_STREAMS.md).

## Execution boundary

Connect supervises the generic CLI Worker Engine on the Worker's computer; the Engine invokes a provider CLI or approved MCP package. Cloud does not execute provider CLIs or store their credentials. Request files and inter-Step handoffs use R2 and artifact identifiers, while local paths remain on the computer. Stateful work also requires a fenced Thread lease. See [ADR-037](../decisions/ADR-037-files-and-artifacts.md) and [ADR-040](../decisions/ADR-040-stateful-workflows-on-worker-agents.md).
