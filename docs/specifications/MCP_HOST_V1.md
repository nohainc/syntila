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

Two protocol families are supported. `McpClient.connect` chooses; `initialize`
alone is the legacy handshake.

| Family | Revisions | Connection |
| --- | --- | --- |
| Stateless (modern) | 2026-07-28 | No `initialize`. Every request carries `_meta` `io.modelcontextprotocol/protocolVersion`, `.../clientCapabilities` (always `{}`) and `.../clientInfo`. `server/discover` reports `supportedVersions`, `capabilities`, `_meta` server info and `instructions`. |
| Legacy (handshake) | 2025-06-18, 2025-03-26, 2024-11-05 | `initialize` proposes 2025-06-18; if the server answers another listed legacy version the client uses it, otherwise `mcp_version_unsupported`. A stateless revision is never accepted from `initialize`. |

Auto negotiation (default, `McpServerSpec.protocolMode`):

1. Send `server/discover` proposing the newest stateless revision. A result with
   a mutually supported stateless version selects it.
2. Fall back to `initialize` **only** when the server shows it is not a modern
   server: JSON-RPC `-32601` or `-32600`, an HTTP 400 without a JSON-RPC error
   body, no answer within 5 s, an empty success carrying neither `resultType`
   nor `supportedVersions`, or a discover result listing only supported legacy
   versions.
3. A recognized modern error never falls back (no silent downgrade):
   `-32022` unsupported version, `-32020` header mismatch, `-32021` missing
   capability and `-32602` fail the connection. `-32022` becomes
   `mcp_version_unsupported` and its `supported` list is shown (bounded,
   sanitized). Other failures (auth, crash, timeout after a modern answer)
   propagate unchanged.
4. A discover result with no common version fails with `mcp_version_unsupported`.

`modern` mode refuses anything but a stateless server; `legacy` mode never sends
`server/discover`.

Stateless behavior:

- No persistent session is assumed. `ping`, `logging/setLevel` and roots
  notifications do not exist; `ping()` is a no-op and a server `ping` request is
  refused. Because we never open `subscriptions/listen`, a stateless server
  cannot push `list_changed`, so the host re-lists tools before each call.
- `resultType` is required on results (absent means complete). `complete` is
  accepted and the field is stripped before the result is used.
  `input_required` (elicitation, sampling, roots via multi-round-trip requests)
  fails with `mcp_interaction_required`; Syntila never answers `inputRequests`
  or echoes `requestState`. Any other value is `mcp_protocol_violation`.
- Cacheable-result hints (`ttlMs`, `cacheScope`) are ignored; nothing is cached.
- **Gated, not implemented:** `subscriptions/listen`, the
  `io.modelcontextprotocol/tasks` extension (no `extensions` capability is
  advertised, so servers must not return task handles), and `Mcp-Param-*`
  routing headers. A tool whose `inputSchema` uses `x-mcp-header` is refused
  over HTTP with `mcp_unsupported_feature` rather than sent without the headers.
- Client capabilities advertised: none (`sampling`, `roots`, `elicitation`,
  `extensions`). Legacy servers requesting them receive method-not-found and the
  event is recorded.
- Server capabilities are recorded per connection; calls to undeclared
  capabilities are not sent.

HTTP behavior is chosen per request:

| | Legacy (after `initialize`) | Stateless |
| --- | --- | --- |
| `Mcp-Session-Id` | stored from `initialize`, sent, `DELETE` on close | never sent, stored or deleted; a server-provided id is ignored |
| `MCP-Protocol-Version` | negotiated version | the request's `_meta` version |
| `Mcp-Method` / `Mcp-Name` | not sent | `Mcp-Method` always; `Mcp-Name` for `tools/call`, `prompts/get` (name), `resources/read` (uri); non-printable or edge-whitespace values are sent as `=?base64?...?=` |
| Cancellation | `notifications/cancelled` POST and stream abort | stream abort only |
| HTTP 400 | invalid request | JSON-RPC error body passed through so modern errors are recognised |
| HTTP 404 | session expired when a session exists | not a session event |

Not supported on either family: the server-to-client GET stream and SSE resumption.
The requests the 2026-07-28 revision removed or replaced (`resources/subscribe`,
the GET stream) are never sent.

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

The same canonicalization applies to every revision: fields are the allow-list
below, keys are sorted recursively, output has no insignificant whitespace.
Stateless-era additions (`title`, `icons`, `execution`, `_meta`) are excluded
like other cosmetic fields. Existing consent hashes are unchanged (locked by
golden vectors); `x-mcp-header` inside `inputSchema` is hashed. Numbers and
strings follow Dart `jsonEncode` (not RFC 8785), so a server whose JSON number
formatting differs between lists will show as drift, which fails closed.

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
| Server needs client input (`input_required`) | `mcp_interaction_required` | `execution_failed` (default protocol-violation mapping) |
| Feature deliberately unsupported (`x-mcp-header`) | `mcp_unsupported_feature` | `execution_failed` (default protocol-violation mapping) |

(Existing-code names must be reconciled with Cloud's enums in M1; the rule is
that no new wire enum value is introduced.)

## 7. Conformance vectors

Protocol and Engine tests cover these cases; a dedicated `mcp-vectors` directory has not been delivered. Task polling and subscriptions are not implemented.

Phase 2 coverage: `packages/syntila_mcp_protocol/test/modern_test.dart` (every
legacy revision via `initialize`; the stateless revision via `server/discover`;
fallback and no-downgrade cases; `resultType`; golden pin vectors) and
`engines/cli_worker/test/mcp_http_transport_test.dart` (per-family HTTP headers,
session handling, cancellation, 400 handling, `x-mcp-header` refusal). The
reference servers are fixtures written against the published 2026-07-28 pages,
not an independent third-party server; interoperability with real stateless
servers is unverified.
