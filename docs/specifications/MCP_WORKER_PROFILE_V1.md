# Syntila MCP Worker profile v1

**Status:** Partially implemented under accepted [ADR-028](../decisions/ADR-028-mcp-integration.md). Local Workers, SDK and partial conformance exist; remote Worker execution and complete conformance remain open.
A standard MCP server becomes a Syntila Worker only by implementing this
profile. Transport and framing are [MCP host v1](MCP_HOST_V1.md).

## 1. Advertisement

`initialize` result includes `_meta: { "syntila.worker": "1" }`. The Engine
refuses to schedule a server as a Worker without it, and requires the Worker-profile marker and consented tool pins.

## 2. Tools

### `syntila.execute` (required)

Input:

```json
{
  "protocol": "syntila.worker/1",
  "prompt": "string",
  "conversation": {
    "messages": [{ "role": "user | assistant", "text": "string" }],
    "request": "string",
    "instructions": ["string"]
  },
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

- The Engine limits output text to 768 KiB measured as UTF-8 bytes.
- `workingDirectory` is sent only to local stdio servers, inside the Thread
  directory; never to remote servers.
- A call has one terminal outcome. Conformance checks a sampled exchange; it
  does not establish enforcement of every possible duplicate response.
- `conversation` is optional and carries the same exchange as `prompt` as
  separate turns: `messages` are the earlier user and assistant turns from the
  canonical history (oldest first; empty when the Worker's own session holds
  them), `request` is the current request without the context envelope, and
  `instructions` are host instructions. `prompt` always stays complete, so a
  Worker may ignore `conversation`. A Worker that wraps a plain chat model
  should use it: such a model answers the envelope in `prompt` as if the user
  had written it.
- `access: restricted` is advisory to the server; Syntila does not claim
  enforcement (ADR-027 §3). A read-only Step is still scheduled on an External
  Worker: the Engine sends `access: restricted` and a read-only instruction, at
  the start of `prompt` and in `conversation.instructions` (simulated
  read-only, since 2026-11-11).

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
| Heartbeat | MCP `ping` is covered by conformance; periodic heartbeat enforcement is not established |
| Cancel | `notifications/cancelled`, grace, process kill |
| Sessions | `session` in input/output; stored by the Engine as today |
| Data directory | `SYNTILA_PLUGIN_DATA_DIR` in the server's environment (set by the Engine only); the working directory is `workingDirectory` when sent |
| Artifacts | Returned relative paths are validated; remote resource transfer is not implemented |
| Errors | `issue.code` from the stable plugin error set; free-form detail to diagnostics |

## 4. Conformance

Conformance runs through `syntila_external_worker_conformance`: `McpConformanceRunner`
(selected when the manifest says `kind: "mcp"`) implements the cases below
over MCP stdio; definition drift and oversize results are not covered yet. The current suite covers host-compatible version selection and fallback from an
unknown version, advertisement, required tools, tool definition shape and uniqueness, ping, probe and execute
result shapes, a single terminal result, and unknown-method errors. Execute
validation checks the returned text against the UTF-8 output limit, session
state, and bounded, safe relative artifact paths. This checks the sampled reply;
it does not prove all future replies will be within the limit. It
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
and errors onto the existing stable issue codes. MCP conformance is available through the package runner described above; it does not yet cover the full NDJSON suite.
