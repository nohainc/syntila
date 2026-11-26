# Connect and Engine startup

Connect runs each Worker's service under the current OS user. A paired Worker has an independent credential, journal and lock. Connect authenticates a session, completes hello and journal reconciliation, then accepts assignments. Automatic startup is optional; see the [Connect CLI and services](CONNECT_CLI_AND_SERVICES.md) guide.

Connect records an assignment in its journal before acknowledging it. It supervises the generic CLI Worker Engine as a separate child and does not start an Engine twice for an attempt. If a crash leaves an attempt that may have started, the attempt is failed for retry instead of being launched again. The Engine resolves the pinned Profile or approved MCP package and invokes the local provider process as needed. See [ADR-034](../decisions/ADR-034-connect-pairing-and-session-fencing.md) and [ADR-041](../decisions/ADR-041-mcp-workers-on-worker-agents.md).

Platform service and credential-store behavior requires device evidence; local tests alone do not establish installed-release behavior.
