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
- Long-running: use MCP tasks only when the negotiated version defines them.
- Idempotency: write-capable tools (annotation `readOnlyHint != true`) are
  never retried automatically.
- Arguments and results pass through the redactor before logging; neither is
  stored in diagnostics by default.

The Engine also has an experimental internal `--mcp-tool-call` one-shot mode.
It accepts one bounded JSON request over stdin containing a local launch or
remote target, consented tool hashes, tool name, arguments and deadline. It
returns one JSON outcome (`completed`, `toolError`, `rejected`, or `unknown`)
over stdout. The caller may send a second line, `{"cancel":true}`, to request
cancellation; closing stdin alone does not cancel. Cancellation after dispatch
does not prove that the server stopped and may result in an unknown outcome.
The result is untrusted and is not a diagnostic. The caller must
perform Workspace admission and consent checks and must durably track uncertain
outcomes; the mode does not provide workflow scheduling, crash recovery, or a
user-facing cancellation channel. It must not be treated as an authorized
workflow execution path until those controls are connected.

The internal Workspace executor resolves the enabled, consented server and
frozen tool pin after acquiring a shared Engine slot. The supervisor writes an
Engine ownership record before sending the request, bounds the response, and
classifies missing results after sending as unknown. The internal executor also
creates an exclusive persistent claim keyed by logical workflow step before
sending. Markers are retained even after success and partial markers count as
claimed. This prevents duplicate dispatch on the same Workspace when the same
key is used; it is not distributed or sufficient for power-loss guarantees
without platform-specific filesystem durability evidence. Cloud must allocate
a stable logical-step key, prevent cross-Workspace replay and reconcile
unknown outcomes before this becomes an assignment endpoint.

The Cloud prompt renderer can render explicitly declared tool-output instance
inputs as attributed, JSON-encoded untrusted data and refuses inputs that do
not fit rather than silently truncating them. The workflow data path does not
yet populate these inputs, and this label is not a security boundary against
prompt injection; execution permissions remain independently enforced.

Cloud migration 0104 provides a persistent, unique claim per task; its internal
claim operation selects only a `tool_call` task and its matching assignment and
Workspace. A duplicate claim, including one from another Workspace, is denied.
No existing workflow exposes that task kind, and the claim is not yet used by
the dispatcher or delivery path. A successful claim is not proof of execution;
losing its acknowledgement must not lead to a second dispatch.

The internal tool-call request v1 contains `schemaVersion`, `taskId`,
`dispatchKey`, `serverId`, `tool`, `toolDefinitionHash`, `arguments`, and
`timeoutMs`. Its key must equal `mcp-tool-v1:<taskId>`; arguments are bounded
to 64 KiB of UTF-8 encoded JSON. TypeScript and Workspace validators reject
unknown fields and mismatched keys. The Workspace deep-copies and freezes arguments before
admission. This is a payload contract only: it is not an advertised transport
capability or an authorization to execute a tool.

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
