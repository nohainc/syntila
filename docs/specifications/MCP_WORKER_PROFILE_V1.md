# Syntila MCP Worker profile v1 (draft)

**Status:** Draft, gated on [ADR-028](../decisions/ADR-028-mcp-integration.md).
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
  "session": { "key": "string", "mode": "new | resume" },
  "deadline": "RFC3339",
  "attachments": [{ "name": "", "mimeType": "", "resource": "uri" }]
}
```

Output (`structuredContent`; text content mirrors `text`):

```json
{ "text": "string", "artifacts": [], "usage": {}, "session": { "key": "" }, "issue": { "code": "", "message": "" } }
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

Input `{ "mode": "quick | full" }`; output readiness identical to plugin
protocol §4 (`ready`, `authentication_required`, `unavailable`, with message).

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
| Artifacts | `resource_link`/embedded resources; Engine validates path, size, type |
| Errors | `issue.code` from the stable plugin error set; free-form detail to diagnostics |

## 4. Conformance

Conformance runs through `syntila_plugin_conformance` with an MCP launcher
(M4). The 21 plugin cases are re-expressed 1:1 where meaningful; MCP-specific
additions: version negotiation, definition drift, missing profile
advertisement, second terminal result, oversize result.
