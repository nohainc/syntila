# MCP host v1

**Status:** Partially implemented; [ADR-028](../decisions/ADR-028-mcp-integration.md) is accepted. The roadmap and baseline inventory distinguish implemented behavior from targets.
Defines what Syntila's MCP client (in the Engine) does and refuses.

## 1. Roles and transports

- Host: Workspace Service (policy, consent, credentials). Client: Engine
  (`mcp_host.dart`), one client session per server connection.
- Transports: `stdio` (local, Engine-launched, digest-pinned) and Streamable
  HTTP (remote, HTTPS required outside local test allowances). A separate endpoint allowlist and OAuth are not implemented. No other transport in v1.
- stdout of a stdio server carries protocol messages only; stderr is captured,
  size-capped, redacted and surfaced as diagnostics.

## 2. Version and capability negotiation

- Syntila keeps an explicit list `supportedProtocolVersions` (newest first).
  `initialize` proposes the newest (2025-06-18, 2025-03-26, 2024-11-05); if the server answers another listed
  version the client uses it, otherwise the connection fails with
  `mcp_version_unsupported`.
- Client capabilities advertised in v1: none of `sampling`, `roots`,
  `elicitation`. Servers requesting them receive a JSON-RPC method-not-found
  error and the event is recorded.
- Server capabilities are recorded per connection; calls to undeclared
  capabilities are not sent.

## 3. Limits (defaults; manifest may lower, never raise)

| Limit | Default |
| --- | --- |
| Frame size | 4 MiB |
| Tool result (text + structured) | 1 MiB; larger is rejected |
| Tools per server | 128 |
| Call timeout | min(assignment deadline, 10 min) |
| Concurrent calls per server | manifest `limits.maxConcurrent` (default 1) |
| Idle server TTL (warm pool) | 5 min; the pool lives in the Engine process, which the supervisor starts per assignment, so it spans calls within one assignment only (see `docs/acceptance/MCP_LATENCY.md`) |

## 4. Tool definition pinning

At consent the client stores `sha256(canonical_json(tool))` for every tool
(name, description, inputSchema, outputSchema, annotations). On every
reconnect or `notifications/tools/list_changed` the hashes are recomputed. Any
change sets server state `definition_changed`; calls are refused with
`mcp_definition_changed` until the user re-consents to the diff. Added tools
are not callable until consented.

## 5. Calls

- Cancellation: `notifications/cancelled`, grace (default 5 s), then process
  tree kill for stdio / connection close for HTTP.
- Progress: `notifications/progress` forwarded as Engine `progress`/`activity`.
- Long-running MCP tasks are not implemented.
- Idempotency: write-capable tools (annotation `readOnlyHint != true`) are
  never retried automatically.
- Arguments and results pass through the redactor before logging; neither is
  stored in diagnostics by default.

The Engine's `--mcp-tool-call` mode is used by the Workspace handler for
admitted direct workflow calls. Cloud creates a durable claim before dispatch;
the Workspace resolves local consent and pins and maintains a persistent fence.
Uncertain outcomes are not replayed. The `chat:v2` workflow supplies recorded
output to the next step as labelled untrusted data. Power-loss durability and
Cloud-to-Workspace remote acceptance remain unverified; see the baseline
inventory. Labels do not enforce permissions or prevent prompt injection.

The internal tool-call request v1 contains `schemaVersion`, `taskId`,
`dispatchKey`, `serverId`, `tool`, `toolDefinitionHash`, `arguments`, and
`timeoutMs`. Its key must equal `mcp-tool-v1:<taskId>`; arguments are bounded
to 64 KiB of UTF-8 encoded JSON. TypeScript and Workspace validators reject
unknown fields and mismatched keys. The Workspace deep-copies and freezes arguments before
admission. The Workspace advertises `workspace.mcp_tool_call.v1`; the payload alone does not authorize execution.

## 6. Error mapping

| Condition | Stable code (diagnostic `mcp_*`) | Maps to existing issue code |
| --- | --- | --- |
| Version unsupported | `mcp_version_unsupported` | `profile_identity_mismatch` |
| Server crashed / EOF | `mcp_server_crashed` | `provider_unavailable` |
| Auth needed/expired (remote) | `mcp_auth_required` | `provider_authentication_required` |
| Definition drift | `mcp_definition_changed` | `permission_denied` |
| Result too large | `mcp_result_too_large` | `execution_failed` |
| Timeout | `mcp_timeout` | `execution_timeout` |

(Existing-code names must be reconciled with Cloud's enums in M1; the rule is
that no new wire enum value is introduced.)

## 7. Conformance vectors

Protocol and Engine tests cover these cases; a dedicated `mcp-vectors` directory has not been delivered. Task polling is not implemented.
