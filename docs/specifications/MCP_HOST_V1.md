# MCP host v1 (draft)

**Status:** Draft, gated on [ADR-028](../decisions/ADR-028-mcp-integration.md).
Defines what Syntila's MCP client (in the Engine) does and refuses.

## 1. Roles and transports

- Host: Workspace Service (policy, consent, credentials). Client: Engine
  (`mcp_host.dart`), one client session per server connection.
- Transports: `stdio` (local, Engine-launched, digest-pinned) and Streamable
  HTTP (remote, allowlisted, TLS required). No other transport in v1.
- stdout of a stdio server carries protocol messages only; stderr is captured,
  size-capped, redacted and surfaced as diagnostics.

## 2. Version and capability negotiation

- Syntila keeps an explicit list `supportedProtocolVersions` (newest first).
  `initialize` proposes the newest; if the server answers another listed
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
| Tool result (text + structured) | 1 MiB; larger is truncated with a marker or rejected per tool setting |
| Tools per server | 128 |
| Call timeout | min(assignment deadline, 10 min) |
| Concurrent calls per server | manifest `limits.maxConcurrent` (default 1) |
| Idle server TTL (warm pool) | 5 min |

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
- Long-running: use MCP tasks only when the negotiated version defines them.
- Idempotency: write-capable tools (annotation `readOnlyHint != true`) are
  never retried automatically.
- Arguments and results pass through the redactor before logging; neither is
  stored in diagnostics by default.

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

Golden vectors live in `docs/specifications/mcp-vectors/` (created in M1):
initialize/version negotiation, unsupported capability request, oversize frame,
cancel, crash/restart, definition drift.
