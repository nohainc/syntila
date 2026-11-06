# MCP integration: one protocol for tools and custom Workers

**Status:** M0 specifications drafted (2026-11-05); ADR-028 awaits owner acceptance. M1 done; M2 partly done (see delivery status).
**Builds on:** [ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md) (anticipates "MCP Engine → MCP Profiles"), [ADR-027](../decisions/ADR-027-custom-worker-plugins.md), [Custom Worker plugins](../architecture/CUSTOM_WORKER_PLUGINS.md), [Plugin plan](CUSTOM_WORKER_PLUGINS_PLAN.md)
**Would supersede (at M6):** [Worker Plugin Protocol v1](../specifications/WORKER_PLUGIN_PROTOCOL_V1.md) as the wire protocol for custom Workers

## 1. Context and decisions taken in-thread

Syntila currently has two execution paths below the Engine (ADR-027):
`executor=profile` for official provider CLIs and `executor=plugin` for
user-imported executables speaking the NDJSON Worker Plugin Protocol. Syntila
has no MCP support.

Owner decisions from the design discussion:

1. **Official Workers keep Profiles.** Codex, Claude, Gemini (and future cloud
   API Profiles) stay on Engine + Profile for controlled, tested updates.
2. **MCP is the single open-integration protocol** for local tools, remote
   tools, local custom Workers and remote custom Workers.
3. **One custom-Worker protocol, not two.** The Syntila MCP Worker profile
   replaces the NDJSON plugin wire protocol long term. Plugin *packaging and
   trust* (manifest, digest pin, consent, signer recognition, limits,
   supervision, conformance) are kept and wrap a local MCP server.
4. **Local performance is acceptable.** stdio JSON-RPC adds sub-millisecond
   per-message overhead; the cost that matters is process start, so servers are
   kept warm and progress is streamed.

Two integration classes are kept strictly separate:

| Class | Meaning | Who produces the final answer |
| --- | --- | --- |
| **MCP Tool** | Any standard MCP server (tools/resources/prompts) | A workflow step (direct call) or an AI Worker that calls it |
| **MCP Worker** | MCP server that also implements the Syntila MCP Worker profile (`syntila.execute`, …) | The MCP Worker itself |

## 2. Target architecture

```text
AX → Cloud (schedule, policy, entitlement; never credentials)
      → Workspace Service (MCP registry, consent, credentials, OAuth tokens)
         → CLI Worker Engine (single supervised host)
            ├─ executor=profile    → Profile → provider CLI                 (unchanged)
            │                         └─ optional: Service-provided MCP tool config (M2)
            ├─ executor=mcp        → MCP client
            │     ├─ stdio  → packaged local MCP server (digest-pinned)    (M4)
            │     └─ https  → remote MCP server (allowlisted, OAuth)       (M5)
            ├─ step=tool_call      → MCP client → MCP Tool                 (M3)
            └─ executor=plugin     → NDJSON plugin (frozen, then shimmed)  (M6)
```

Invariants carried forward from ADR-027 / Architecture v8:

- The Service spawns only the Engine; the Engine hosts every MCP server
  process (reuses `plugin_host.dart`, `plugin_process_limits.dart`,
  `plugin_resource_monitor.dart`, `plugin_windows_handles.dart`,
  `plugin_redactor.dart`).
- No Syntila code branches on a server's or provider's identity. MCP servers
  are data: `(serverId, version, digest|endpoint, origin)`.
- Cloud never sees secrets, tokens or local paths beyond what it sees today.
- The `syntila` CLI never executes a server; all management is Service IPC.
- A process boundary is not a sandbox; isolation is reported honestly.

## Delivery status

| Phase | State |
| --- | --- |
| M0 specs | Done (ADR-028 still Proposed) |
| M1 protocol package + Engine host | Done; tests pass (`syntila_mcp_protocol`, `mcp_host_test`) |
| M2 MCP tools for official Workers | **Partly done.** Done: Profile slot `mcpConfigArguments` (Dart validator, Engine, TS validator/interpreter), `execute.request.mcpServers`, private per-execution config file, spec and authorization text. TS changes are untested (no Node on the authoring host). Also done: Workspace `McpRegistry`/`McpService` (consent with full tool definitions, definition pinning, binary-digest check, `resolveLaunches` as the only route to `mcpServers`; env names stored, never values). Also done: Engine one-shot `--mcp-probe`, `EngineMcpProbe`, `mcp.*` IPC ([spec](../specifications/MCP_MANAGEMENT_IPC_V1.md)) and `syntila mcp` CLI group. Also done: per-Worker-type bindings, `launchesForWorker`, supervisor `mcpServers` and the execution-path wiring (Workspace-local; the per-Step Cloud list is still open). **Open:** per-Step `mcpTools` selection and Cloud policy, activity normalisation, adopting the slot in official Profile releases (Claude `--mcp-config` is the only verified mechanism; Codex and Gemini unverified), Profile Lab evidence, real-provider acceptance |
| M4 MCP Workers | **Started.** Done: Engine `McpWorkerRunner` (`syntila.execute`/`syntila.probe` through `McpHost`, same outcome types as the plugin host; access/model/session mapping, progress, cooperative cancel then kill, deadline, code normalisation, artifact path checks, output limit, consent pins required) and the reference server `examples/mcp/echo_worker`; 11 tests. Also done: Local Worker Protocol 4.3 (`executor.protocol = "mcp"` + `toolPins`; an MCP executor must name 4.3, NDJSON executors unchanged), supervisor identity, and the plugin-mode Engine's `McpRoutingPluginHost` (MCP launches go to the runner; probe/models/continuity/failure mapping shared with NDJSON); end-to-end test through the real Engine process. **Open:** Workspace side (store/registry/runtime producing an MCP executor and pins), manifest `kind: mcp` packaging in the plugin store, Cloud catalog `executorKind`, SDK `runMcpWorker`, conformance launcher, Ollama reference Worker, latency comparison |
| M3, M5, M6 | Not started |

## 3. Phases

Each phase is independently shippable and has its own exit criteria.

### M0 — Decision and specifications (docs only)

Deliverables:

- `docs/decisions/ADR-028-mcp-integration.md`: decisions in §1, how this keeps
  the v8 exclusion (same argument as ADR-027 §3), alternatives (NDJSON only;
  MCP for tools only; MCP replaces Profiles — rejected).
- `docs/specifications/MCP_HOST_V1.md`: supported MCP protocol versions
  (pinned list, negotiated in `initialize`), transports (stdio, Streamable
  HTTP), client capabilities Syntila advertises (roots: no by default;
  sampling: **no**; elicitation: no in v1), limits (frame size, result size,
  tool count, call timeout), redaction, error mapping onto existing stable
  issue codes.
- `docs/specifications/MCP_WORKER_PROFILE_V1.md`: the Syntila Worker contract
  over MCP — see §4.
- `docs/specifications/MCP_SERVER_MANIFEST_V1.md`: extends `plugin.json` with
  `kind: "mcp"` and `class: "tool" | "worker"`; same digest canonicalisation.
- `docs/security/MCP_THREAT_MODEL.md`: tool poisoning, description drift,
  result-borne prompt injection, confused deputy on remote OAuth, token
  storage, exfiltration via tool arguments.

Exit: ADR-028 accepted by owner; spec drafts reviewed.

### M1 — MCP client core in the Engine

- New Dart package `packages/syntila_mcp_protocol` (no Syntila/Cloud imports,
  mirroring `syntila_plugin_protocol`): JSON-RPC 2.0 codec, MCP message types,
  version negotiation, capability model, stdio transport, Streamable HTTP
  transport, cancellation (`notifications/cancelled`), progress
  (`notifications/progress`), tasks (long-running) where the negotiated
  version supports them.
- Evaluate the official MCP Dart SDK if one is mature; otherwise own codec
  (protocol surface is small). Decision recorded in ADR-028.
- Engine: `engines/cli_worker/lib/src/mcp_host.dart` — launches a stdio server
  through the existing plugin host (limits, Job Object, process-tree cleanup,
  redaction), keeps a **warm pool** keyed by `(serverId, digest, workspace)`
  with idle timeout and max-concurrency, restarts on crash with backoff.
- Tool-definition pinning: hash of each `tools/list` entry; a changed
  definition after consent marks the server `definition_changed` and blocks
  calls until re-consent.
- Golden vectors under `docs/specifications/mcp-vectors/` (like
  `worker-plugin-vectors`).

Exit: `pnpm validate:engine` covers handshake, version mismatch, cancel,
crash/restart, oversize frame, definition drift, against a reference echo MCP
server (`examples/mcp/echo_dart`).

### M2 — MCP Tools for official Workers (highest value, lowest cost)

Official CLIs are already MCP clients; Syntila manages configuration, not
calls.

- Service: MCP server registry (`apps/workspace/lib/mcp_service.dart`,
  `mcp_store.dart`), import/consent/enable/remove via new Management IPC
  commands (`mcp.import`, `mcp.list`, `mcp.consent`, `mcp.enable`,
  `mcp.disable`, `mcp.remove`, `mcp.test`) — extend
  `WORKER_PLUGIN_MANAGEMENT_IPC_V1.md` or add `MCP_MANAGEMENT_IPC_V1.md`.
- Tool Profile schema (`packages/tool_profile_v1`): optional capability
  `mcpToolConfig` describing how the CLI accepts MCP config (config file path,
  CLI flag, env var, format). Profiles stay Cloud-published; the capability is
  data, no provider branch in Engine code.
- Engine writes a per-execution, Thread-scoped MCP config into the execution's
  private temp dir and passes it per the Profile capability; never mutates the
  user's global CLI config.
- Per-Step policy: which enabled MCP Tools a Step may expose
  (`USER_WORKFLOW_CONFIGURATION_V1.md` gains `mcpTools: [serverId]`). Default:
  none.
- Activity: tool calls reported by the CLI's event stream are normalised into
  existing `WORKER_ACTIVITY_V1` activity kinds where the Profile adapter
  (`provider_activity_adapter.dart`) can recognise them.
- Profile Lab: evidence cases proving each official Profile loads a supplied
  MCP config and calls a reference tool (`TOOL_PROFILE_EVIDENCE_CONTRACT.md`).

Exit: real-provider acceptance for Codex, Claude, Gemini calling the reference
tool; config never leaks outside the execution dir; Step without `mcpTools`
sees no servers.

### M3 — Direct tool calls in workflows

- New workflow step kind `tool_call` (deterministic, no model):
  `{ serverId, tool, arguments, resultBinding }`. Arguments may reference
  earlier step outputs via existing binding rules.
- Cloud: step kind in workflow schema, scheduler routes it to a Workspace
  with the server enabled (inventory reports enabled MCP servers and their
  tool-definition hashes, not their configs).
- Engine executes via `mcp_host.dart`; result is validated against the tool's
  `outputSchema` when present, size-capped, stored as a structured artifact.
- Next AI Step receives the result as a rendered, labelled context section
  ("tool output from <server>/<tool>; untrusted data") rather than raw
  concatenation.
- AX: render tool-call steps in the Work timeline (`AX_WORK_RENDERING_V1`).

Exit: end-to-end test `tool_call → chat` through Cloud, Service, Engine;
untrusted-content labelling verified; idempotency per
`MUTATION_IDEMPOTENCY.md` for write tools (calls with side effects require
`destructiveHint`-aware per-tool consent).

### M4 — Local MCP Workers (Syntila MCP Worker profile)

- Engine: `executor=mcp` in Local Worker Protocol **4.3** (additive optional
  `executor.kind = "mcp"`); translator `mcp_worker_executor.dart` mapping:

  | Syntila lifecycle | MCP |
  | --- | --- |
  | readiness probe | `initialize` + `syntila.probe` tool |
  | execute | `tools/call syntila.execute` (task-augmented when supported) |
  | progress / activity | `notifications/progress` + structured progress payload |
  | cancel | `notifications/cancelled`, then grace period, then process-tree kill |
  | heartbeat | MCP `ping` |
  | exactly one terminal result | Engine guarantees; second result is a protocol violation |
  | models | `syntila.models` tool (optional) |
  | sessions | `session` object in execute input/output, persisted as today |
  | artifacts | `resource_link` / embedded resources, validated by Engine |

- Packaging: the plugin store gains `kind: "mcp"`; import, consent-by-hash,
  signer recognition, export bundles, per-Workspace pins all reused unchanged.
- Cloud: catalog `origin = "plugin"` rows gain `executorKind`; no new
  entitlement (same `workers.custom_plugins` admission SQL).
- SDK: `packages/syntila_plugin_sdk` gains `runMcpWorker(PluginWorker)` so the
  **same `PluginWorker` class** runs over either protocol; `init` template
  defaults to MCP. Python reference example ported to MCP.
- Conformance: `syntila_plugin_conformance` gets an MCP launcher; the 21 cases
  are re-expressed against the MCP Worker profile plus MCP-specific cases
  (version negotiation, definition drift, task polling).
- Reference: `examples/mcp/ollama_worker` (HTTP API to local Ollama) as the
  canonical non-trivial example.

Exit: echo and Ollama examples pass full conformance; full-path acceptance
test like the plugin one; latency trace (`LATENCY_TRACE_V1`) shows MCP
overhead vs NDJSON plugin < 5 ms per execution with a warm server.

### M5 — Remote MCP Tools and Workers

- Streamable HTTP transport in production; TLS required; endpoint allowlist
  per Workspace; consent document includes endpoint, auth method and declared
  data scope.
- OAuth per MCP authorization spec, tokens stored only in the Service's local
  credential store; Cloud receives only "remote server enabled: yes/no" and
  tool hashes.
- Retries only for idempotent operations; reconnect/resume for tasks;
  deadlines from the assignment.
- File transfer: remote Workers never receive local paths. v1 supports only
  explicitly attached files sent as embedded resources (size-capped) and
  artifacts returned as resources; whole-directory access is out of scope.
- Audit: each call records endpoint, negotiated version, tool hash, duration,
  outcome (no arguments/results stored by default).
- Remote Workers are scheduled as `Work` only and `restricted` by default.

Exit: acceptance against a test remote server with OAuth; token never in
Cloud logs/DB (verified by test); allowlist enforcement test.

### M6 — Converge on one protocol

- Freeze Worker Plugin Protocol v1 (no new versions); mark deprecated in its
  spec and author guide.
- Engine-side shim: an NDJSON plugin is hosted behind an internal adapter that
  presents it to the Engine as an MCP Worker, so the Engine has one Worker
  executor code path (`executor=mcp`); `executor=plugin` remains a manifest
  value only.
- Migration tooling: `syntila plugins migrate-check <id>` (Service IPC) reports
  whether a plugin can be repackaged; SDK users switch `runPlugin` →
  `runMcpWorker` with no other change.
- Removal of the NDJSON host only after a published deprecation window (policy
  in `WORKER_PLUGIN_PROTOCOL_V1.md` §11) and zero active NDJSON plugins in
  Cloud inventory telemetry.

Exit: all examples and conformance run on MCP; NDJSON path covered only by
shim tests.

## 4. Syntila MCP Worker profile v1 (summary for the spec)

Required tools:

- `syntila.execute` — input: `{ protocol: "syntila.worker/1", prompt,
  workingDirectory?, access: "work" | "restricted", model?, effort?,
  session?: { key, mode: "new" | "resume" }, deadline, attachments? }`;
  output (`structuredContent`): `{ text, artifacts[], usage?, session?,
  issue? }`.
- `syntila.probe` — input `{ mode: "quick" | "full" }`; output readiness
  states identical to plugin protocol §4.

Optional: `syntila.models`. Server advertises the profile via
`serverInfo`/`_meta: { "syntila.worker": "1" }`; Engine refuses to schedule a
server as a Worker without it. `workingDirectory` is only sent to local stdio
servers.

## 5. Cross-cutting work

| Area | Work |
| --- | --- |
| Security | Per-tool consent; definition pinning; untrusted-output labelling; secret redaction on arguments/results; no sampling/roots by default; threat-model tests |
| Cloud data | Migrations: `mcp_servers` library (metadata only), inventory columns for enabled servers/tool hashes, step kind `tool_call`, catalog `executorKind` |
| AX / GUI | MCP servers list, consent and drift banners, per-Step tool selection, tool-call timeline rendering |
| Observability | `DIAGNOSTIC_EVENTS_V1` events for connect, call, drift, crash; latency spans |
| Docs | Author guide for MCP Workers, user security guide, operations runbook updates |
| Performance | Warm pool; streaming progress; budget: warm-call overhead < 5 ms, cold start reported separately |

## 6. Risks

- **MCP spec churn** — pin versions, negotiate, vector tests per version.
- **CLI MCP config differences** — isolated in Profile capability data;
  Profile Lab evidence per release.
- **Prompt injection via tools** — default-off exposure per Step, labelling,
  consent, write-tool confirmation.
- **Two protocols during transition** — bounded by M6 shim and deprecation
  window.
- **Remote trust boundary** — allowlist, OAuth, no implicit files, Work-only.

## 7. Suggested order and sizing

| Phase | Depends on | Relative size |
| --- | --- | --- |
| M0 | — | S |
| M1 | M0 | M |
| M2 | M1 (registry/consent only) | M |
| M3 | M1 | M |
| M4 | M1 | L |
| M5 | M3, M4 | L |
| M6 | M4 + deprecation window | M |

M2 and M3 can proceed in parallel after M1.
