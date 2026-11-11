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
  "execution": { "schemaVersion": 1, "workflow": { "id": "string", "version": 1, "step": "string" }, "access": "work | restricted", "sessionPolicy": "stateless | durable_session", "context": "bootstrap | delta | none | rebuild" },
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
- `conversation` is optional and follows this profile's version 1. `messages` contains
  earlier user and assistant turns in canonical order, excluding the current
  request. `request` contains the current user text, bounded by the Work
  prompt's request limit, when Cloud supplied the separate representation.
  `instructions` contains the separately rendered
  Workflow, Space, Thread, and host instructions. When available, historical
  objective, decisions, constraints, open issues, artifacts, summary, and
  completed prerequisite results and notices about omitted or cleared history
  are included as explicitly labelled historical data in `instructions`.
  `prompt` remains the complete assembled prompt and may be used by an agent
  Worker. If the separate representation is unavailable, `request` falls back
  to the assembled request; Workers must continue to support `prompt` alone.
  On the Workspace-to-Engine connection, the extra input is sent only when the
  External Worker Engine advertises `external_conversation_v1` at initialize
  and the combined frame fits the protocol limit. Oversize frames retain the
  complete assembled prompt and use the existing request fallback.
  The Dart SDK exposes this optional view as `WorkRequest.conversation`;
  `WorkRequest.prompt` remains available for agent-style Workers.
- `execution` is optional version 1 metadata. `workflow` is optional and identifies
  the actual workflow and step; it must not be inferred from access. `access`
  mirrors the advisory top-level access. Workflow identity is unavailable if
  the optional structured input is omitted to meet frame limits. `sessionPolicy` is Syntila's logical
  session policy. `context` describes the context supplied with this call:
  `bootstrap` is available initial history, `delta` is context to synchronize
  with a resumed session, `none` supplies no historical context, and `rebuild`
  supplies available context for reconstructing a session. Context may be
  bounded or summarized; none of these values promises a complete transcript.
  A history-replay Worker consumes the available context on every call. A
  native-session Worker uses the session key and mode and applies a delta on
  resume; Syntila decides when synchronization or reconstruction is needed.
  The Engine omits `execution` when a Worker's tool schema disallows it.
  The Workspace omits workflow metadata when the Engine does not advertise
  `external_execution_v1`; older Workers retain their existing prompt.
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

The assembled prompt may differ from the prompt used by an official Worker due to session synchronization, advisory read-only instructions, or output-image guidance. Workers should choose the representation appropriate for their provider; neither representation grants extra permissions.
