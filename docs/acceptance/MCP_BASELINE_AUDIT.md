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

## Phase 3 — official Worker MCP integration (mostly done)

Details and commands: [MCP_PROVIDER_ACCEPTANCE.md](MCP_PROVIDER_ACCEPTANCE.md).

- **Claude (release 3):** live reference-tool call, empty selection (with an
  ambient project config), subset and `--resume` all behaved as required, and
  the user's permanent configuration was untouched.
- **Codex (release 3, new):** `--ignore-user-config -c mcp_servers={{mcpServersToml}}`
  through the existing `mcpConfigArguments` slot, in the base and the 0.180.x
  vectors. Measured: servers load, subsets and empty selections isolate,
  secrets travel by `env_vars` name only. **No live tool call or resume was
  possible** (usage limit), and the 0.180.x vector is unverified.
  Side effect, approved: the user's whole `config.toml` is ignored.
- **agy / Gemini:** unsupported by design; no per-execution mechanism exists.
- **Engine/Profile changes:** `McpInlineToml`, `{{mcpServersToml}}` in the TS
  and Dart Profile validators and interpreter, Codex Profile release 3,
  conflicting server variables refused, stale temp config sweep.
- **Open:** Codex live call and resume; cancellation/timeout evidence for
  every provider; Profile publication; a crash test for the SIGKILL gap
  (mitigated by the sweep, not tested at kill time).

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

## Phase 5 — direct-call reliability (partly done)

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

**Evidence.** Fence tests cover sync ordering, failed sync, the real sync on
macOS (including a non-ASCII path), first-outcome-wins, corrupt records and
the unchanged claim semantics; the handler test covers replay of a recorded
outcome, a claim without an outcome, and no journal for pre-dispatch
rejections. Cloud first-outcome and cross-Workspace tests exist from earlier
work and Phase 1.

**Crash-boundary tests (added later).** `mcp_tool_call_supervisor_test.dart` now
covers each boundary: admission failure (rejected, no claim, no Engine), claim
ordering (after admission, before any byte reaches the Engine), an Engine that
dies before reading, garbled or out-of-contract answers, a valid answer with a
non-zero exit, and no answer before the deadline. All but pre-dispatch
rejections end `unknown`, free the slot, and never carry a result.

**Not done.** Power-loss evidence: no machine was power-cycled, so durability
rests on the syscalls succeeding, not on a failure experiment; Linux and
Windows were not run. A real process-kill test between claim and write is still missing (the
boundaries are simulated with shell stand-ins). Cloud cannot yet ask
a Workspace for its journal after a lost reply, so Cloud still records
`unknown` for those; the journal is visible only locally. There is no IPC
status command or UI, and no manual-recovery command: the only recovery is to
run a new Step with a new key after a person inspects the outcome. Automatic
retry for idempotent tools is not implemented. Re-checking Cloud grants at the
Workspace is not done (`authorizeStart` is still constant true; Cloud checks
grants before dispatch).

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
