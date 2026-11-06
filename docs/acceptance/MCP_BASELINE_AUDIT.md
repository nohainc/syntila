# MCP baseline audit — 2026-11-06

Baseline: `aed4059f7b6e809603cc05acdac7398fc95bfd76`; original plan
`f9879399`. This is a phase-zero inventory, not a release certification. The
roadmap's M0–M6 lists remain the detailed requirement checklist; the rows below
map each requirement group to evidence and outstanding acceptance work.

| Original requirement | Implementation and test evidence | Status and restriction |
| --- | --- | --- |
| M0 ADR, host, Worker, manifest, threat model | `docs/decisions/ADR-028-mcp-integration.md`, `docs/specifications/MCP_*`, `docs/security/MCP_THREAT_MODEL.md` | ADR accepted; specs describe partial implementation and targets. |
| M1 codec, negotiation, capabilities, stdio, cancellation, progress | `packages/syntila_mcp_protocol/lib`, `test/client_test.dart`; `engines/cli_worker/test/mcp_host_test.dart` | Implemented subset; legacy 2025-06-18, 2025-03-26, 2024-11-05 and stateless 2026-07-28 (Phase 2). Tasks and subscriptions are not implemented. Dedicated golden vectors are missing. |
| M1 host, limits, pooling, pinning, restart | `engines/cli_worker/lib/src/mcp_host.dart`, `mcp_host_test.dart` | Implemented within Engine lifetime; pool does not persist across assignments. Process isolation is not a sandbox. |
| M2 registry, consent, probe and CLI | `apps/workspace/lib/mcp_{registry,service,engine_probe}.dart`, `workspace_cli_mcp.dart`; `test/mcp_*test.dart` | Local registry and consent with definition pins implemented; credentials and executable paths remain local. |
| M2 Profile config and per-Step policy | `engines/cli_worker/lib/src/mcp_config.dart`, `packages/tool-profile`, `apps/workspace/lib/workspace_manager_mcp.dart`; `engine_mcp_config_test.dart`, `interpreter.test.ts`, `workspace_manager_mcp_test.dart` | Default empty selection; Claude release 3 has a slot. Inventory-backed selection, Cloud policy, activity normalization, Codex/Gemini slots and Profile Lab/provider acceptance remain open. |
| M3 workflow kind, admission, durable claim and routing | `apps/cloud/src/mcp-tool-{step,dispatch-claim}.ts`, `packages/workspace-runtime-protocol/src/mcp-tool-call.ts`, `apps/workspace/lib/mcp_tool_call_*`; matching tests in each component | `chat:v2` supports an owner-admitted call on the owner's Workspace; claims and local fences reject replay. General inventory-based scheduling and power-loss durability evidence are open. |
| M3 execution, result validation, untrusted context, timeline | `engines/cli_worker/lib/src/mcp_tool_call_runner.dart`, `mcp_schema_validation.dart`, `apps/cloud/src/mcp-tool-step.ts`; corresponding Engine and Cloud tests, `workflow-prompts.test.ts` | Bounded output and schema validation; labelled untrusted context and basic timeline label. Full Cloud-to-Service-to-Engine acceptance and richer timeline remain open; annotations do not prove safety. |
| M4 local Worker lifecycle, protocol and packaging | `engines/cli_worker/lib/src/mcp_worker_runner.dart`, `mcp_routing_plugin_host.dart`, `apps/workspace/lib/plugin_mcp_inspect.dart`; `mcp_worker_runner_test.dart`, `mcp_executor_engine_test.dart`, `mcp_worker_plugin_end_to_end_test.dart` | Local protocol 4.3, pins, package consent, progress, sessions, cancellation and result checks implemented. Restricted access is advisory, not sandbox enforcement. |
| M4 SDK, reference and conformance | `packages/syntila_plugin_sdk/lib/src/run_mcp_worker.dart`, `packages/syntila_plugin_conformance/lib/src/mcp_runner.dart`, `examples/mcp`; `mcp_worker_test.dart`, `mcp_conformance_test.dart`, `mcp_ollama_worker_test.dart`, `mcp_sdk_worker_test.dart` | SDK opt-in `init --mcp`, echo and Ollama examples, partial conformance and latency measurement exist. Default scaffold, all 21 cases, drift and oversize conformance and full example conformance remain open. |
| M5 transport and remote tools | `engines/cli_worker/lib/src/mcp_http_transport.dart`, `apps/workspace/lib/mcp_service.dart`; `mcp_http_transport_test.dart`, `mcp_remote_test.dart`, `mcp_remote_service_test.dart`, `mcp_tool_call_handler_test.dart` | Streamable HTTP JSON/SSE replies and sessions, HTTPS with explicit loopback HTTP exception, token variable and local consent. Separate allowlist, OAuth, audit and official CLI remote config remain open. |
| M5 remote Workers, attachments, scheduling, acceptance | `mcp_worker_runner.dart`, remote transport tests | Remote transport primitives exist; remote Worker execution, attachment transfer, Work-only scheduling and OAuth acceptance remain open. No automatic replay of uncertain calls. |
| M6 freeze, migration and shim | `apps/workspace/lib/workspace_cli_plugins.dart`, `WORKER_PLUGIN_PROTOCOL_V1.md`; plugin migration tests | `migrate-check` and non-binding freeze note exist. Formal deprecation, shim, telemetry and removal remain open; NDJSON remains supported. |

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

## Phase 3 — official Worker provider inspection (not complete)

Findings from the CLIs installed on 2026-11-06, observed without any model call
or credential use. **No Profile was changed and no Worker is certified.**

**Codex (`codex-cli 0.160.0`; the Profile's 0.180.x override binary is not
installed and was not inspected).** MCP servers come from `[mcp_servers.*]` in
`$CODEX_HOME/config.toml`, and `-c mcp_servers.<name>.command=...` overrides
add servers per execution without writing files. Measured with a temporary
`CODEX_HOME`: `-c 'mcp_servers={}'` does **not** remove a server defined in
`config.toml` (overrides merge), so an empty selection cannot be isolated that
way. The only mechanism seen is `exec --ignore-user-config` (also on
`exec resume`; absent from `codex mcp list` and unverified for `app-server`),
which discards the whole user `config.toml`, not just MCP. Emitting it from
`mcpConfigArguments` would run every Codex execution without the user's
model-provider, sandbox and notification settings, and the slot is emitted even
for empty selections. Project-level `.codex` configuration was not tested.
Conclusion: a per-execution slot is feasible only with a deliberate decision
to ignore user config, plus a live check that selected servers load, an empty
selection exposes none, resume works and the real `config.toml` is untouched.

**agy 1.5.2.** `agy mcp add/remove/enable/disable` writes persistent
configuration. The session-only `--settings` flag **rejects** `mcpServers`
("unknown setting"), so there is no per-execution MCP mechanism. Per the
phase rule the capability stays unsupported: the Profile has no slot, so any
non-empty selection fails with `mcp_unsupported`. Ambient servers a user added
with `agy mcp add` cannot be excluded by Syntila.

**Claude Code 2.1.308.** `--mcp-config` and `--strict-mcp-config` ("only use
MCP servers from --mcp-config, ignoring all other MCP configurations") exist as
the release 3 slot assumes. The Engine deletes the private config directory in
a `finally`, which covers completion, error and cancellation; an Engine process
killed outright (SIGKILL) would leave the owner-only temp directory behind, and
that case has no test. Existing fixture-provider tests cover selected and empty
configurations; no live Claude run has been made.

**Not done:** Codex slot and tests, Profile Lab live reference-tool evidence
for any provider, subset-selection and resume checks against real CLIs, MCP
tool-activity normalisation in `provider_activity_adapter.dart`, and
cancellation/timeout evidence. Live runs use the user's provider accounts and
were not made without approval.

## Phase 4 work in progress

`McpService.sanitizedInventory` projects server identity, transport,
enablement, consent, consented tool hashes and Worker bindings without launch
configuration, endpoints or token details. Availability is `unknown`: no
fresh diagnostic or compatible-Profile assessment is implied. It is a local
projection only and is not wired to Cloud, realtime synchronization, IPC or UI;
it is not an authorization decision. Focused local and remote tests cover the
projection. Phase 4 remains incomplete: inventory contract integration,
management UI and consent diff, selectable inventory, synchronization, and
Phase 1 default-deny authorization remain open.

## Phase 5 work in progress

The gateway now refuses to return a previously claimed outcome from a
different Workspace, including when a concurrent claim loses the insert race.
A regression test checks the refusal, prevents result disclosure and confirms
no dispatch. Existing claim and fence tests pass. A completed but oversized
result was separately changed in Phase 1 work to unknown without replay.

The Workspace fence uses exclusive marker creation and file flush, but has no
verified parent-directory synchronization or operating-system interruption
coverage. Cloud's claim row currently cascades on task deletion, so permanent
logical-key retention is not established. Crash-boundary coverage,
authorization and runtime correlation review, reconciliation and controlled
manual recovery remain open. Phase 1's security acceptance and the broader
Chat/Worker regression suites have not passed; Phase 5 is not accepted.

## Phase 6 work in progress

The existing Chat tool workflow now revalidates persisted Step outcomes before
consumption. Missing, malformed or oversized completed results become unknown,
so they cannot supply downstream Chat input. Focused tool-step and prompt tests
cover this guard and existing untrusted-output labelling. This does not create
an authorable tool Step or a rich timeline. Versioned authoring, bindings,
consent and side-effect confirmation, cancellation UX and timeline data remain
open, as do the Phase 4 and Phase 5 dependencies. No Phase 6 acceptance is
claimed.

## Phase 7 work in progress

The partial MCP conformance runner now checks that the sampled tool list has
unique nonempty names and object input/output schemas. Reference Worker fault
fixtures exercise malformed schemas and duplicate names; the SDK-generated
Worker passes this same partial conformance runner. On macOS, the focused MCP
conformance suite (9 tests), generated SDK test, real-Engine SDK/Worker and
scripted Ollama suite (29 tests), and Workspace MCP Worker assignment test
passed. The Ollama suite uses a fake service; it does not establish a live
Ollama Workspace assignment. Analysis and documentation-link checks passed.

The existing NDJSON conformance test file passed 12 tests. Full behavioral
MCP conformance, broader NDJSON regression, Phase 1 and 2,
cross-platform packaged assignments, process-tree and resource-limit evidence,
symlink escapes, live Ollama and several requested fault cases remain open.
The new case checks sampled tool definitions, not general JSON Schema validity.
Restricted execution remains advisory, not a sandbox. Phase 7 is not accepted.
