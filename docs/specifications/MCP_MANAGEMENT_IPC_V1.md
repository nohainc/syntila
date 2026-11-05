# MCP management IPC v1

**Status:** Implemented for MCP Tools (ADR-028, plan phase M2). Same transport,
authentication and error envelope as the
[plugin management IPC](WORKER_PLUGIN_MANAGEMENT_IPC_V1.md). The CLI never
starts an MCP server; every server is started by the Engine.

## Commands

| Command | Payload | Result |
| --- | --- | --- |
| `mcp.list` | none | `{servers: [{serverId, displayName, command, consented, enabled, tools}], bindings: {workerTypeId: [serverId]}}` |
| `mcp.add` | `serverId` (`[a-z0-9][a-z0-9_-]{0,63}`), `displayName`, `command` (existing absolute path), `arguments` (<=32 strings), `environmentNames` (<=16, no `SYNTILA_*`) | `{serverId, next}` |
| `mcp.consent` | `serverId`, optional `acceptHash` | without hash: `{consentRequired: true, document, documentHash}`; with the matching hash: `{serverId, consented: true, documentHash}` |
| `mcp.bind` / `mcp.unbind` | `serverId`, `workerTypeId` | `{workerTypeId, serverId, bound}` |
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

## Bindings: which Worker types receive which servers

A server is offered to an official Worker only if it is **bound** to that Worker
type (`mcp.bind`), and, at launch time, consented, enabled and byte-identical to
what was consented. The default is no binding, so no execution receives any MCP
server. Binding never bypasses consent: if any bound server fails those checks the
execution fails with `worker_not_ready` and a local diagnostic carrying the
`mcp_*` code, never running with a silent subset. If the Worker's Profile has no
`mcpConfigArguments` slot (TOOL_PROFILE_V1 section 11.1) the execution fails with
`mcp_unsupported` instead of running without the servers. Removing a server drops
it from every binding. Bindings live in the Workspace's `Mcp/servers.json` and are
never sent to Cloud.

**Deviation from the plan:** ADR-028 and the plan describe a per-Step `mcpTools`
list in the workflow configuration, decided by Cloud policy. That is not built.
Worker-type bindings are a coarser, local-only stand-in; a later per-Step list
should intersect with them, not replace the consent checks.

## Not yet defined

The per-Step `mcpTools` list and its Cloud policy.
