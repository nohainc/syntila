# MCP management IPC v1

**Status:** Implemented for MCP Tools (ADR-028, plan phase M2). Same transport,
authentication and error envelope as the
[plugin management IPC](WORKER_PLUGIN_MANAGEMENT_IPC_V1.md). The CLI never
starts an MCP server; every server is started by the Engine.

## Commands

| Command | Payload | Result |
| --- | --- | --- |
| `mcp.list` | none | `{servers: [{serverId, displayName, command, consented, enabled, tools}]}` |
| `mcp.add` | `serverId` (`[a-z0-9][a-z0-9_-]{0,63}`), `displayName`, `command` (existing absolute path), `arguments` (<=32 strings), `environmentNames` (<=16, no `SYNTILA_*`) | `{serverId, next}` |
| `mcp.consent` | `serverId`, optional `acceptHash` | without hash: `{consentRequired: true, document, documentHash}`; with the matching hash: `{serverId, consented: true, documentHash}` |
| `mcp.enable` / `mcp.disable` / `mcp.remove` | `serverId` | `{serverId, enabled}` / `{serverId, removed}` |

`mcp.add` records the SHA-256 of the command's bytes and starts nothing. Only
environment variable **names** are stored; values are read from the Service's own
environment when a server is launched, and never persisted.

## Consent

`mcp.consent` asks the Engine (`--mcp-probe`, one-shot) to start the server and
list its tools, then returns a document with the command, its digest, arguments,
environment names and the **full definition of every tool**. `documentHash` is
the SHA-256 of its canonical JSON. Accepting means repeating the command with
`acceptHash`. If the tools changed since the document was shown the hash no
longer matches and the call fails with `mcp_consent_mismatch`; nothing is pinned.
The CLI exits 3 while consent is pending, like `plugins.*`.

Tool descriptions come from the server and are untrusted; the CLI says so.
At every later launch the Service re-checks the command digest, and the Engine
host refuses calls to any tool whose definition differs from the consented
pin (`mcp_definition_changed`).

## Errors

`invalid_request`, `unsupported_command`, `mcp_exists`, `mcp_not_found`,
`mcp_not_consented`, `mcp_not_enabled`, `mcp_consent_mismatch`,
`mcp_binary_changed`, `mcp_probe_failed`, plus the Engine's `mcp_*` and
`plugin_digest_mismatch` codes surfaced from the probe.

## Not yet defined

Selecting which enabled servers a Step may use (`mcpTools`) and the Cloud policy
for it; the `mcpServers` field of `execute.request` is populated only by
`McpService.resolveLaunches`, which refuses any server that is not consented,
enabled and unchanged.
