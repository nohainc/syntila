# Connect supervision

Connect runs one Agent per Worker. Each Agent has a separate credential, journal and lock and supervises the generic CLI Worker Engine as a child process. The provider CLI or approved MCP package runs through the Engine. See [ADR-034](../decisions/ADR-034-connect-pairing-and-session-fencing.md) and [ADR-041](../decisions/ADR-041-mcp-workers-on-worker-agents.md).

## Local assignment lifecycle

Connect records an assignment in its journal before acknowledgement. Journal transitions are forward-only: `received → accepted → starting → running → terminal → acknowledged`. Replayed delivery reconciles with the recorded attempt and never starts a second Engine for it. Terminal state is recorded before delivery and remains available for retry until acknowledged.

## Process ownership and recovery

Connect fences local use of a Worker's data directory with a lock. After a crash, an attempt that may already have started is not launched again; Connect reports a retryable failure and Cloud can create a new attempt. Orphaned processes are handled by the Engine supervisor. Session fencing separately prevents an old session from committing a late result. Cancellation and failure paths must settle local execution and retain terminal evidence for reconciliation.

Platform service behavior, process cleanup and credential stores require device evidence. Automated tests do not establish installed-release behavior on every operating system.
