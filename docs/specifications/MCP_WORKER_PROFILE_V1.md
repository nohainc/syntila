# Syntila MCP Worker profile v1 (draft)

**Status:** Draft; the Engine runner and a reference server implement sections 1-3 (see `examples/mcp/echo_worker`). Gated on [ADR-028](../decisions/ADR-028-mcp-integration.md).
A standard MCP server becomes a Syntila Worker only by implementing this
profile. Transport and framing are [MCP host v1](MCP_HOST_V1.md).

## 1. Advertisement

`initialize` result includes `_meta: { "syntila.worker": "1" }`. The Engine
refuses to schedule a server as a Worker without it, and refuses any server
whose manifest says `class: "tool"`.

## 2. Tools

### `syntila.execute` (required)

Input:

```json
{
  "protocol": "syntila.worker/1",
  "prompt": "string",
  "workingDirectory": "string?",
  "access": "work | restricted",
  "model": "string?",
  "effort": "string?",
  "session": { "key": "string", "mode": "new | resume | rebuild" },
  "deadline": "RFC3339",
  "attachments": [{ "name": "", "mimeType": "", "resource": "uri" }]
}
```

Output (`structuredContent`; text content mirrors `text`):

```json
{ "text": "string", "artifacts": ["relative/path"], "session": { "state": "created | resumed | unavailable" }, "issue": { "code": "", "message": "", "retryable": false } }
```

- `workingDirectory` is sent only to local stdio servers, inside the Thread
  directory; never to remote servers.
- Exactly one terminal outcome per call: a result or a JSON-RPC error. The
  Engine treats a second completion as a protocol violation and kills the
  server.
- `access: restricted` is advisory to the server; Syntila does not claim
  enforcement (ADR-027 §3). Read-only scheduling is allowed only where the host
  reports an enforced isolation tier (none today).

### `syntila.probe` (required)

Input `{ "mode": "passive | live" }`; `structuredContent` is
`{ state, issueCode?, checks?, capabilities? }` exactly as in plugin protocol §4:
`state` is `ready`, `setup_required`, `sign_in_required`, `unavailable` or
`failed`, and each of at most 32 checks is `{ code, ok, message }` with a
message of 1-1,024 characters. A malformed check is a protocol violation. The
Engine redacts check, progress and error messages like the NDJSON host.

### `syntila.models` (optional)

Output model list in the shape of plugin protocol 1.1 model discovery
(`MODEL_DISCOVERY_NORMALIZATION.md`).

## 3. Lifecycle mapping

| Worker concept | MCP mechanism |
| --- | --- |
| Readiness | `initialize` then `syntila.probe` |
| Progress / activity | `notifications/progress`; message payload `{ "activity": {...} }` |
| Heartbeat | MCP `ping` (host sends; no reply within 3 intervals = unhealthy) |
| Cancel | `notifications/cancelled`, grace, process kill |
| Sessions | `session` in input/output; stored by the Engine as today |
| Data directory | `SYNTILA_PLUGIN_DATA_DIR` in the server's environment (set by the Engine only); the working directory is `workingDirectory` when sent |
| Artifacts | `resource_link`/embedded resources; Engine validates path, size, type |
| Errors | `issue.code` from the stable plugin error set; free-form detail to diagnostics |

## 4. Conformance

Conformance runs through `syntila_plugin_conformance`: `McpConformanceRunner`
(selected when the manifest says `kind: "mcp"`) implements the cases below
over MCP stdio; definition drift and oversize results are not covered yet. The current suite covers host-compatible version selection and fallback from an
unknown version, advertisement, required tools, ping, probe and execute
result shapes, a single terminal result, and unknown-method errors. Execute
validation checks session state and bounded, safe relative artifact paths. It
does not yet re-express all 21 NDJSON plugin cases.

## Local Worker Protocol 4.3: how the Engine receives an MCP Worker

An MCP Worker is a plugin package whose executor says `"protocol": "mcp"`. On
`initialize` and `execute.request` the `executor` object then carries
`toolPins` (tool name -> SHA-256 of the consented definition, 1-128 entries) and
the frame must name protocol `4.3`; a 4.2 peer rejects it. NDJSON executors omit
both keys and keep protocol `4.2`. The Service, not Cloud, supplies the pins from
the consent record. The Engine launches the server with the same digest pin,
limits and tree cleanup as an NDJSON plugin, requires the Worker-profile
marker, refuses any tool whose definition differs from its pin, and maps results
and errors onto the existing stable issue codes. Conformance for MCP Workers
is not available yet (the Engine answers with `profile_schema_incompatible`).
