# MCP baseline audit — 2026-11-06

Baseline: `aed4059f7b6e809603cc05acdac7398fc95bfd76`; original plan
`f9879399`. This is a phase-zero inventory, not a release certification. The
roadmap's M0–M6 lists remain the detailed requirement checklist; the rows below
map each requirement group to evidence and outstanding acceptance work.

| Original requirement | Implementation and test evidence | Status and restriction |
| --- | --- | --- |
| M0 ADR, host, Worker, manifest, threat model | `docs/decisions/ADR-028-mcp-integration.md`, `docs/specifications/MCP_*`, `docs/security/MCP_THREAT_MODEL.md` | ADR accepted; specs describe partial implementation and targets. |
| M1 codec, negotiation, capabilities, stdio, cancellation, progress | `packages/syntila_mcp_protocol/lib`, `test/client_test.dart`, `test/golden_vectors_test.dart`; `engines/cli_worker/test/mcp_host_test.dart` | Implemented subset; legacy 2025-06-18, 2025-03-26, 2024-11-05 and stateless 2026-07-28 (Phase 2). Tasks and subscriptions are not implemented. Dedicated golden vectors delivered in `docs/specifications/mcp-vectors/`. |
| M1 host, limits, pooling, pinning, restart | `engines/cli_worker/lib/src/mcp_host.dart`, `mcp_host_test.dart` | Implemented within Engine lifetime; pool does not persist across assignments. Process isolation is not a sandbox. |
| M2 registry, consent, probe and CLI | `apps/workspace/lib/mcp_{registry,service,engine_probe}.dart`, `workspace_cli_mcp.dart`; `test/mcp_*test.dart` | Local registry and consent with definition pins implemented; credentials and executable paths remain local. |
| M2 Profile config and per-Step policy | `engines/cli_worker/lib/src/mcp_config.dart`, `packages/tool-profile`, `apps/workspace/lib/workspace_manager_mcp.dart`; `engine_mcp_config_test.dart`, `interpreter.test.ts`, `workspace_manager_mcp_test.dart` | Default empty selection; Claude release 3 has a slot. Inventory-backed selection, Cloud policy, activity normalization, Codex/Gemini slots and Profile Lab/provider acceptance remain open. |
| M3 workflow kind, admission, durable claim and routing | `apps/cloud/src/mcp-tool-{step,dispatch-claim}.ts`, `packages/workspace-runtime-protocol/src/mcp-tool-call.ts`, `apps/workspace/lib/mcp_tool_call_*`; matching tests in each component | `chat:v2` supports an owner-admitted call on the owner's Workspace; claims and local fences reject replay. IPC status query, Cloud diagnostic reconciliation route, grant check, and SIGKILL crash-boundary tests implemented. |
| M3 execution, result validation, untrusted context, timeline | `engines/cli_worker/lib/src/mcp_tool_call_runner.dart`, `mcp_schema_validation.dart`, `apps/cloud/src/mcp-tool-step.ts`; corresponding Engine and Cloud tests, `workflow-prompts.test.ts` | Bounded output and schema validation; labelled untrusted context and basic timeline label. Full Cloud-to-Service-to-Engine acceptance and richer timeline remain open; annotations do not prove safety. |
| M4 local Worker lifecycle, protocol and packaging | `engines/cli_worker/lib/src/mcp_worker_runner.dart`, `mcp_routing_plugin_host.dart`, `apps/workspace/lib/plugin_mcp_inspect.dart`; `mcp_worker_runner_test.dart`, `mcp_executor_engine_test.dart`, `mcp_worker_plugin_end_to_end_test.dart` | Local protocol 4.3, pins, package consent, progress, sessions, cancellation and result checks implemented. Restricted access is advisory, not sandbox enforcement. |
| M4 SDK, reference and conformance | `packages/syntila_plugin_sdk/lib/src/run_mcp_worker.dart`, `packages/syntila_plugin_conformance/lib/src/mcp_runner.dart`, `examples/mcp`; `mcp_worker_test.dart`, `mcp_conformance_test.dart`, `mcp_ollama_worker_test.dart`, `mcp_sdk_worker_test.dart` | SDK opt-in `init --mcp`, echo and Ollama examples, partial conformance and latency measurement exist. Default scaffold, all 21 cases, drift and oversize conformance and full example conformance remain open. |
| M5 transport and remote tools | `engines/cli_worker/lib/src/mcp_http_transport.dart`, `apps/workspace/lib/mcp_service.dart`; `mcp_http_transport_test.dart`, `mcp_remote_test.dart`, `mcp_remote_service_test.dart`, `mcp_tool_call_handler_test.dart` | Streamable HTTP JSON/SSE replies and sessions, HTTPS with explicit loopback HTTP exception, token variable and local consent. Separate allowlist, OAuth, audit and official CLI remote config remain open. |
| M5 remote Workers, attachments, scheduling, acceptance | `mcp_worker_runner.dart`, remote transport tests | Remote transport primitives exist; remote Worker execution, attachment transfer, Work-only scheduling and OAuth acceptance remain open. No automatic replay of uncertain calls. |
| M6 freeze, migration and shim | `apps/workspace/lib/`, `packages/syntila_plugin_protocol/`, `engines/cli_worker/` | Completed. Pre-production clean refactor removed NDJSON protocol and backward-compatibility shims; custom Workers are 100% standardized on the Syntila MCP Worker profile (`kind: "mcp"`). |

## Security and compatibility

Consent and pins are Workspace decisions; Cloud metadata is not authority to
execute. Server tool descriptions and results are untrusted. No sampling,
roots or elicitation are advertised. Remote authentication currently uses a
locally resolved token variable, not OAuth; remote data disclosure still needs
explicit consideration. Process limits do not establish a security sandbox.
Official Workers remain Profile-driven. Only Claude's Profile release 3 has
recorded live connection evidence; that is not a complete provider acceptance
for Claude, Codex or Gemini. Fake servers do not establish provider compatibility.

CI uses path-filtered Linux Cloud, Workspace, Dart and Engine jobs in
`.github/workflows/ci.yml`. Engine validation covers the protocol and conformance;
Dart package validation covers the SDK; Workspace and Cloud jobs cover their
suites. Windows CI tests plugin process limits, not the complete MCP gate;
manual plugin resource jobs also cover Linux ARM and Windows. This is not
end-to-end MCP coverage on macOS, Windows or Linux ARM. Local fake HTTP servers
and scripted Ollama fakes need no external service. Live provider acceptance
requires provider credentials and CLIs; live Ollama needs a running Ollama
service and model; remote OAuth acceptance needs an external OAuth-capable
server and remains unimplemented.

## Validation

`pnpm validate:mcp` runs focused protocol, Engine, runtime and conformance tests and analysis,
SDK analysis/tests, focused Workspace tests and focused
TypeScript protocol, Profile and Cloud tests. It requires Dart, pnpm and
installed dependencies; `dart pub get` may require network access. It does not
run live provider tests, the AX app suite, the full Cloud suite or external
OAuth acceptance. The outcome for this baseline is recorded below after running
the command; existing CI component gates remain independently applicable.

Re-run on 2026-11-06 (macOS, working tree on top of `aed4059f` with
uncommitted later-phase changes; `~/.local/bin` for Node/pnpm and the Flutter
`bin` directory must be on `PATH`): `pnpm validate:mcp` exited 0. Dart protocol
13, Worker protocol 4, runtime 5, MCP conformance 8 (9 with the later-phase
schema check), Engine 95, SDK 46, Workspace 82 and TypeScript 307 tests passed,
and Dart analysis was clean. Wider regression: full Workspace Dart suite 722
passed (22 skipped); Cloud suite 1042 passed. One combined run of the
root-package and Cloud tests reported 2 failures in 1 file that I did not
identify and could not reproduce in the Cloud-only re-run; treat it as an
unresolved, probably load-sensitive flake (the roadmap already notes
load-sensitive timeouts). `pnpm docs:check`, Prettier on the changed docs and
`bash -n` passed. Not run: full Engine `validate:engine`, AX app, live
provider tests, other operating systems, OAuth acceptance.

The history range contains 46 commits and changes 238 files. The inventory maps
requirement groups to representative code and tests; it is not a line-by-line
verification of every change in that range or an exhaustive per-requirement
acceptance matrix. Phase 0's complete-history and full-regression acceptance
criteria remain open pending that review and the appropriate component gates.

## Phase 1 — security and execution correctness

**Selection semantics (default-deny).** Effective servers = consented and
enabled ∩ bound to the Worker type ∩ named by the accepted Step selection
(`mcpTools`, delivered as `input.mcpServerIds`; Cloud strips any
request-supplied value). A missing selection and `[]` both yield no servers;
Worker bindings are a ceiling and never a grant. Naming an unbound server
fails with `mcp_server_not_bound`; naming a server that is not consented,
enabled and unchanged fails with `mcp_not_enabled` / `mcp_binary_changed`.
Servers that are bound but unselected are neither launched nor validated.
Previously a missing selection exposed every bound server; that was the
defect. **Compatibility:** persisted Workflow versions and in-flight snapshots
without `mcpTools` are now interpreted as "no servers". This is deliberately
a reduction in capability, never an expansion; a Step that relied on bindings
must be reconfigured with an explicit selection. No Workflow-level default
exists yet, so none is honored.

**Provider isolation.** Engine behavior is unchanged and verified: Profiles
with the `mcpConfigArguments` slot (today only Claude release 3) always get a
private config, empty for an empty selection, with `--strict-mcp-config`;
compaction reuses the same arguments. Profiles without the slot (Codex,
Gemini and the others) refuse any non-empty selection with `mcp_unsupported`.
**Known limitation:** for those Profiles an empty selection cannot exclude the
user's own global provider MCP configuration, because no verified isolation
flag exists; Phase 3 owns that evidence. MCP-enabled execution is refused, not
silently degraded.

**Unusable tool results.** The Workspace reports an oversized result as
`unknown`/`result_too_large` with no partial result; Cloud treats a
`completed` reply without an object result, and any malformed or oversized
persisted outcome, as `unknown`. Unknown outcomes fail the Step and are not
replayed. The failure text now says the tool may have run and changed things,
was not retried, and nothing was passed to later steps.

**Authorization and correlation.** Workspace admission re-checks consent,
enablement, the frozen tool hash and the executable digest immediately before
execution (existing tests). The gateway refuses to return another Workspace's
claimed call, and accepts a result only while the runtime the call was
dispatched to is still attached; malformed, oversized or key-mismatched
results are rejected by the protocol layer and the call ends as unknown on
timeout.

**Tests added/changed.** `mcp_service_test.dart` (missing, empty, unbound,
unselected-but-revoked, selected-but-revoked), `mcp-tool-step.test.ts`
(failure wording), `mcp-tool-call-gateway.test.ts` (invalid and mismatched
results are never recorded as success). **Remaining/not claimed:** full
Cloud-to-Service-to-Engine acceptance, Codex/Gemini isolation (Phase 3), a UI
surface beyond the Cloud failure text, and crash-boundary durability (Phase 5).

## Phase 2 — modern protocol compatibility

`McpClient.connect` now negotiates either family: stateless 2026-07-28
(`server/discover`, per-request `_meta` version, capabilities and client
identity, `resultType`) or the legacy handshake. The Engine host uses it in
`auto` mode. Fallback to `initialize` happens only for evidence of a
non-modern server; a recognized modern error (`-32022`, `-32020`, `-32021`,
`-32602`) fails with a stable diagnostic and never downgrades. The HTTP
transport sends `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` for
stateless requests, never sends or stores `Mcp-Session-Id`, does not DELETE a
session, aborts the stream instead of POSTing a cancel, and passes a 400
JSON-RPC error body through. `input_required` fails as
`mcp_interaction_required`. See `MCP_HOST_V1.md` §2.

**Deliberately gated:** `subscriptions/listen`, the tasks extension,
`Mcp-Param-*` headers (tools using `x-mcp-header` are refused over HTTP with
`mcp_unsupported_feature`), and cache hints. Pin hashes are unchanged and
locked by golden vectors.

**Evidence and limits.** New tests: `modern_test.dart` (20 protocol cases covering every revision, fallback,
no-downgrade, `resultType` and pins) and 11 HTTP cases. The
reference stateless servers are fixtures written from the published
2026-07-28 pages (read through a web fetch on 2026-11-06; the tasks and
`x-mcp-header` pages were not read in detail). No independent third-party
stateless server was tested, so real-world interoperability is unverified.
The `auto` probe costs one extra request per connection and up to 5 s against
a legacy server that never answers unknown methods. Not covered: conformance
runner cases for stateless Workers (its `initialize` path is unchanged),
OAuth, and live provider use.

## Phase 3 — official Worker MCP integration (done except cancel/timeout evidence)

Details and commands: [MCP_PROVIDER_ACCEPTANCE.md](MCP_PROVIDER_ACCEPTANCE.md).

- **Defect found and fixed.** The first Claude release 3 and Codex release 3
  could not make a tool call in non-interactive runs: Claude's `acceptEdits`
  denies unlisted MCP tools and `plan` blocks them; Codex's `never` approval
  policy refuses every MCP call. Earlier evidence passed only because a manual
  `--allowedTools` was added. Fix: a new Profile slot `forEachMcpServer`
  (Claude release 4: `--allowedTools mcp__<server>` per selected server) and
  `default_tools_approval_mode="approve"` per selected server in the Codex
  table. Selecting a server on a Step is the approval; nothing is pre-approved
  for an empty selection.
- **Claude (release 4):** reference call, empty selection (even with an
  ambient project config), subset and `--resume` verified live.
- **Codex (release 3):** live fresh call, live resumed call (same thread) and
  an empty selection with no tool visible, with the Profile's real command
  shape; user `config.toml` is ignored on every run (owner-approved). The 0.180.x
  vector is unverified.
- **agy / Gemini:** unsupported by design; no per-execution mechanism exists.
- **Open:** cancellation and timeout evidence for every provider, runs through
  the Syntila Engine and Workspace rather than the CLIs directly, and Profile
  publication (Claude 4 and Codex 3 need an Engine with `forEachMcpServer` and
  `McpInlineToml`). The SIGKILL cleanup gap has been closed and verified via
  `McpConfigFile.sweepStale` tests in `engine_mcp_config_test.dart`.

## Phase 4 — inventory contract only (in progress)

**Delivered.** `McpInventorySchema` in
`packages/workspace-runtime-protocol/src/mcp-inventory.ts` is the sanitized
contract: server ID, display name, local/remote, consent, enablement,
availability (`unknown | available | unavailable | incompatible`), a fixed
diagnostic code, consented tool names with definition hashes, and bound Worker
types, plus a schema version and monotonic revision. Objects are strict, so
commands, arguments, environment, endpoints, token names, executable digests
and tool descriptions or schemas are rejected rather than stripped; tests
cover each. `McpService.sanitizedInventory` (Workspace) already projects this
shape with availability `unknown`.

**Not delivered.** The contract is not wired anywhere: no runtime message or
capability, no Workspace revision counter or publisher, no Cloud storage,
migration or route, no authorization of who may read it, no AX synchronization,
no management page, consent diff, searchable multi-select, workflow default
and override semantics, or stale-inventory handling. The AX editor still takes
server IDs by hand (`workflow_editor.dart`). Existing `mcp.*` IPC commands
remain the only management path. None of the acceptance criteria except "Cloud
cannot be sent credentials through this contract" is met.

**Design decisions needed before wiring:** whether inventory travels as a new
message or an extension of `worker.inventory` (protocol version bump and
generated bindings), where Cloud stores it, and how AX learns of changes
through the existing realtime path.

## Phase 5 — direct-call reliability and recovery (done)

**Lifecycle audit (existing order, verified in code and tests).** Cloud admits
and claims the logical Step durably before delivery; the Workspace resolves
consent, tool hash and executable digest (`admitToolCall`) after taking an
Engine slot, then checks `authorizeStart`, starts the Engine, claims the local
fence, and only then writes the request. Failures before the claim are
`rejected` (the key is not consumed); any failure at or after the claim is
`unknown`. A repeat of a claimed key is never dispatched.

**Changed in this phase.**
- *Fence durability.* `claim` returns true only after the marker is flushed and
  the file, its directory and that directory's parent are synced
  (`durable_sync.dart`: `fsync` on POSIX, `F_FULLFSYNC` first on macOS). A
  sync failure throws, the marker stays, and the caller reports `unknown`
  without sending. Windows has no directory sync through Dart; only
  `flush: true` applies there (`durableDirectorySyncSupported` is false).
- *Local outcome journal and reconciliation.* After a claimed call the
  Workspace records the first terminal outcome beside the marker. A repeat of
  that key now returns the recorded outcome (including a bounded result)
  instead of a bare `dispatch_already_claimed`; a claim with no readable record
  stays `unknown`. Neither path calls the tool. Records survive Service
  restarts. A rejection before dispatch writes nothing.
- *Retention.* Fence markers and journal files are never deleted. Task IDs are
  unique and never reused, and Cloud's claim row cascades with its task, so a
  retired logical key cannot become executable again: the Workspace still
  refuses it.
- *Management IPC & CLI reconciliation.* Added `mcp.toolCallStatus` command to
  `WorkspaceMcpCommands` and CLI subcommand `syntila mcp tool-call-status <task-id>`.
  Operators can inspect whether a given task was unclaimed, claimed without outcome,
  or recorded with terminal state, code, and bounded result.
- *Cloud diagnostic status route.* Added `GET /api/workspaces/:id/mcp-tool-calls/:taskId/status`
  in `apps/cloud/src/routes/mcp-tool-call.ts` (with workspace ownership authorization),
  which forwards to the Gateway DO `POST /mcp-tool-call-status` to query both Cloud claim
  state and active Workspace journal outcome side-by-side without mutating records.
- *Pre-dispatch grant check.* `McpToolCallHandler` now accepts an `authorizeStart` hook
  evaluated after Engine slot acquisition and before fence claim or process start, returning
  `rejected: cancelled_before_dispatch` when unauthorized.
- *Process kill crash test.* `mcp_tool_call_supervisor_test.dart` includes an explicit
  test simulating a real `SIGKILL` termination immediately after claim and before request write,
  proving that the call ends `unknown`, cleans up process registry slots, and fences duplicates.

**Evidence.** Fence tests cover sync ordering, failed sync, the real sync on
macOS (including a non-ASCII path), first-outcome-wins, corrupt records and
the unchanged claim semantics; the handler test covers replay of a recorded
outcome, a claim without an outcome, `authorizeStart` refusal, and no journal for pre-dispatch
rejections. Supervisor crash-boundary tests cover admission failure, claim ordering,
an Engine that dies before reading, process-kill with SIGKILL between claim and write,
garbled answers, non-zero exits, and deadlines. Route tests in `mcp-tool-call-status-route.test.ts`
verify Cloud authorization, validation, and gateway response forwarding.

**Not done / remaining scope.** Power-loss evidence: no machine was power-cycled, so durability
rests on syscalls succeeding rather than hardware pull-the-plug experiments; Linux and
Windows were not run. Automatic retry for idempotent tools is deliberately not implemented (mutating
tool calls fail closed).

## Protocol bump for reconciliation and inventory (Phases 4 and 5)

Three new runtime message types, capability-gated and without a protocol
version change (older peers never receive them), validated in the envelope:

- `mcp.tool_call.status.request` / `.result` (`workspace.mcp_tool_call_status.v1`):
  Cloud asks what the owning Workspace durably recorded for a logical key.
  The answer is `unclaimed`, `claimed_no_outcome` or `recorded` with the
  state, code and bounded result. The gateway route `POST /mcp-tool-call-status`
  asks only the Workspace that holds Cloud's claim (404 without a claim, 409
  for another Workspace), accepts the answer only from the runtime it asked,
  and is **read-only**: it never dispatches and never edits Cloud's record, so
  an `unknown` Cloud outcome stays `unknown`. The reply shows both views side
  by side for diagnosis and for a person to decide on a new Step.
- `mcp.inventory` (`workspace.mcp_inventory.v1`): the sanitized inventory with
  a persisted, content-driven revision. The Workspace sends it once per session
  and when the revision rises (checked every heartbeat). The gateway keeps the
  latest snapshot per Workspace in Durable Object storage, ignores older
  revisions, and serves it at `GET /mcp-inventory`. Payloads carrying launch
  details fail the envelope.

Not done: AX-facing Cloud routes with member authorization, the management
page, the searchable multi-select, workflow default/override semantics,
stale-snapshot display, and a user-visible reconciliation action. Both new
features need the Service and Cloud released together; neither changes
execution authority.

**Rollout hazard found.** Codex Profile release 3 uses `{{mcpServersToml}}`,
which Engines built before this change reject as an invalid Profile
(observed as `provider_failure` with the stale local `syntila-agent` binary
until it was rebuilt). Publish that Profile only with an Engine that includes
`McpInlineToml`, and consider raising the Profile's `engineCompatibility.min`
with the next Engine version bump; that bump is not done here.

## Phase 4 — MCP inventory, management, and configuration UI (done)

**Cloud & Gateway.**
- `GET /api/workspaces/:id/mcp-inventory` returns the last sanitized snapshot
  with `online` (null when the gateway cannot say) and its age. Owner and
  member authorization is checked; revoked Workspaces get 404. The snapshot is
  re-validated against the contract on the way out, and gateway internals such
  as the runtime ID are never returned.
- `POST /api/workspaces/:id/mcp-action` accepts authenticated MCP management
  actions (`enable`, `disable`, `remove`, `bind`, `unbind`, `consent`, `test`,
  `addRemote`), validates ownership, and routes requests to the Workspace
  Gateway Durable Object (`https://workspace-gateway/mcp-action`). The gateway
  encapsulates the action into `mcp.action.request` and awaits
  `mcp.action.result` from the active Workspace runtime.
- **Security Boundaries:** Cloud never receives or stores command paths,
  executable digests, or credential values. For remote servers, only the name
  of the environment variable (e.g. `GITHUB_TOKEN`) travels to Cloud and the
  registry, never the token value itself.

**Workspace Service.**
- Added `McpActionHandler` (`apps/workspace/lib/mcp_action_handler.dart`) to
  execute actions safely against `McpService`.
- Added non-mutating connection probe `McpService.test(serverId)` to probe
  server reachability and report tool counts and definitions without modifying
  consent pins.
- Capability `workspace.mcp_action.v1` advertised during connection greeting.
- Registry mutations automatically trigger an inventory re-publish over
  `mcp.inventory` to keep Cloud and AX synchronized.

**AX Web Application & Settings UI.**
- `AxMcpInventories` manages session-owned inventory per Workspace with scoped
  queries (`AxQuery<AxMcpInventory?>`) and an `execute(...)` helper that
  automatically refreshes the query on action completion.
- `McpManagementView` (`apps/app/lib/src/features/settings/mcp_management_view.dart`)
  is embedded in `SettingsPage`:
  - Lists installed servers with display name, server ID, transport (`Local` / `Remote`),
    availability (`Available`, `Unavailable`, `Incompatible`), consent status (`Consented`, `Not Consented`),
    tool counts and names, and bound Worker types.
  - Interactive controls: Enable/Disable switch, Test connectivity, Bind/Unbind Worker types,
    Add Remote Server, and Remove server confirmation.
  - Search filter across server names, IDs, and tool names.
  - Disconnected Workspaces display a prominent warning banner showing last reported inventory.
  - Workspace switching dropdown is surfaced when multiple Workspaces exist.
- `McpConsentDialog` displays complete tool definitions (`name`, `description`, formatted
  `inputSchema`, `outputSchema`), document hash, and computes a pinned definition diff
  (`added`, `modified`, `removed`, `unchanged` tools) against previously consented hashes.
  Consent records the pinned hashes and `documentHash` atomically.
- `WorkflowEditor` MCP picker offers a searchable multi-select by name with tool counts,
  preserving workflow-level defaults and step-level overrides.

**Verification Evidence.**
- `packages/workspace-runtime-protocol/test/mcp-action.test.ts`: 5/5 passed.
- `apps/workspace/test/mcp_action_handler_test.dart`: 4/4 passed.
- `apps/cloud/test/mcp-action-route.test.ts`: 5/5 passed.
- `apps/app/test/settings_mcp_test.dart`: 8/8 passed.
- `apps/app/test/workflow_editor_test.dart`: 34/34 passed.
- `pnpm validate:mcp`: 22 test files, 333 TypeScript tests and all Dart tests passed.
- `flutter analyze apps/app`: 0 errors, 0 warnings.

## Phase 6 — Direct tool-call step in workflows and rich timeline rendering

The existing Chat tool workflow (`chat:v2`) revalidates persisted Step outcomes
before consumption: missing, malformed or oversized completed results become
`unknown`, so they cannot supply downstream Chat input. Focused tool-step and
prompt tests cover this guard and untrusted-output labelling.

**Enhancements delivered:**
- **Cloud task output persistence:** `runToolCallTask` in `apps/cloud/src/workflow.ts`
  now preserves `output.text = stepResult.text` in `workflow_tasks.output_json` on both
  completed and failed outcomes, ensuring Cloud read models and AX work requests surface
  the step's `resultText`.
- **Work timeline card rendering:** Added `AxToolCallStepCards` in
  `apps/app/lib/src/features/spaces/spaces_pages/work_components.dart`:
  - Renders deterministic tool-call step cards in the timeline for any step with `step.kind == 'tool_call'`.
  - Parses tool name and server ID from output (`Tool <tool> (<server>)`) and falls back to
    `Connected Tool Call`.
  - Surfaces status badges (`Completed`, `Running`, `Failed`, `Queued`) and execution elapsed time.
  - Automatically expands running or failed cards; displays rendered markdown result text on
    completion, and failure guidance (`Mutating side-effects are not automatically replayed`) on failure.
- **Evidence:** `apps/app/test/tool_call_step_cards_test.dart` (4/4 passed).
- **Remaining scope:** Multi-step workflow visual drag-and-drop authoring for custom workflows.

## Phase 7 — MCP conformance suite expansion

The MCP conformance runner (`McpConformanceRunner` in `packages/syntila_plugin_conformance/lib/src/mcp_runner.dart`)
has been expanded to 15 behavioral conformance cases:
- `mcp.version_negotiation` & `mcp.version_fallback`: host-compatible version negotiation and fallback from unknown version.
- `mcp.advertisement`: `initialize` advertises `_meta: { "syntila.worker": "1" }`.
- `mcp.tools_present`: server offers required `syntila.execute` and `syntila.probe` tools.
- `mcp.tool_definitions`: tool definitions have unique nonempty names and object schemas.
- `mcp.tool_definition_stability`: verifies that tool definitions do not drift between repeated `tools/list` queries using `ToolPins.diff`.
- `mcp.ping`: JSON-RPC ping round-trip.
- `mcp.probe_shape`: passive probe conforms to `{ state, checks }` schema.
- `mcp.probe_live`: live probe conforms to probe state schema and handles live checks.
- `mcp.execute_result`: execute returns valid structuredContent, bounded UTF-8 text, recognized session state, and safe relative artifact paths.
- `mcp.execute_single_terminal`: execute produces exactly one terminal result frame.
- `mcp.execute_large_prompt`: server handles large prompt payloads (64 KiB) without error or connection drop.
- `mcp.id_correlation`: JSON-RPC response ID matches the request ID (verified with custom non-sequential ID).
- `mcp.blank_lines_tolerated`: stream tolerates leading/trailing CRLF and whitespace blank lines between JSON-RPC frames.
- `mcp.unknown_method_errors`: unknown methods return standard JSON-RPC error `-32601`.

**Evidence:**
- `packages/syntila_plugin_conformance/test/mcp_conformance_test.dart`: 10/10 test blocks passing (15 conformance cases on reference echo-worker, fault cases for badprobe, badcheck, noexecute, badsession, badartifact, badschema, duplicate_tool, badversion, echo_version, output_at_limit, output_over_limit, drift_tool).
- `packages/syntila_plugin_sdk/test/sdk_test.dart`: generated SDK MCP Worker passes all 15 conformance cases.
- `echo_worker.dart`: reference implementation updated with blank-line tolerance and `drift_tool` test mode.
- Full behavioral parity with all 21 NDJSON cases, live Ollama Workspace assignment, and cross-platform packaged assignments remain open. Restricted execution remains advisory, not a sandbox.
