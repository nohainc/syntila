# Custom Worker plugins: SDK, conformance, phases and open decisions

**Status:** Implementation in progress. The delivery table is current; detailed phase scopes below retain the original plan.
**Decision:** [ADR-027](../decisions/ADR-027-custom-worker-plugins.md)
**Architecture, entitlement, trust:** [Custom Worker plugins](../architecture/CUSTOM_WORKER_PLUGINS.md)
**Contracts:** [Plugin protocol](../specifications/WORKER_PLUGIN_PROTOCOL_V1.md), [Management IPC](../specifications/WORKER_PLUGIN_MANAGEMENT_IPC_V1.md)

## Delivery status (branch `feat/custom-plugins-p2`)

| Phase | State | Evidence |
| --- | --- | --- |
| P1 Protocol, ADR, entitlement contract | Done | ADR accepted; manifest/lease schemas; `workers.custom_plugins`; golden vectors |
| P2 Local execution, entitlement-gated | Execution path and resource limits implemented; platform acceptance remains open | `pnpm validate:engine` (plugin host, 4.2, plugin-mode Engine, conformance), `pnpm validate:workspace` (store, registry, IPC, CLI, runtime, end-to-end test) |
| P3 Cloud library, catalog, eligibility | Done | `pnpm validate:cloud` (library, pins, scheduler and eligibility against real SQL, atomic admission, list isolation) |
| P4 Export and multi-Workspace distribution | Done for the product path: `export` writes a credential-free bundle, `import` accepts it, each Workspace pins independently, updates show a consent diff. **Open:** per-platform isolation evidence | store and service tests |
| P5 SDK and docs | Implemented locally: `packages/syntila_plugin_sdk` (`runPlugin`, `PluginWorker`, `SessionStore`, `pack`, `init`), `examples/plugins/echo_dart` (passes all 21 conformance cases), [author guide](../specifications/WORKER_PLUGIN_AUTHOR_GUIDE.md), [operations runbook](../operations/CUSTOM_WORKER_PLUGINS_OPERATIONS.md), [user security guide](../security/CUSTOM_WORKER_PLUGINS.md), key tool. Python reference example and offline `scripts/sign-plugin.mjs` available. **Open:** package publication | SDK tests incl. standalone conformance of both examples; Engine conformance test for the Dart example; Node signing verification test |

Still open, in priority order: (1) filesystem/network isolation, Windows handle
quotas, an aggregate POSIX CPU budget, and Linux/Windows resource-limit device
acceptance. POSIX CPU/open-file limits, observed RSS/process/data quotas and
Windows job limits now exist; see [resource-limit evidence](../acceptance/PLUGIN_RESOURCE_LIMITS.md); (2) package publication;
(3) `plugins trust-signer`; (4) acceptance on a deployed Cloud and real
Windows/Linux hosts. Author tooling is local to this checkout; no packages have
been published. The "Phased implementation plan" below is the original
plan; this table is the current state.

## 1. Dart SDK plan

Goal: a Dart author writes a Worker in one file and gets handshake, framing,
heartbeats, cancellation and limits right by default. Authors in other
languages implement the language-neutral protocol directly and use the same
conformance suite.

### 1.1 Packages

| Package | Location | Depends on | Purpose |
| --- | --- | --- | --- |
| `syntila_plugin_protocol` | `packages/syntila_plugin_protocol` | `dart:core` only | Frame types, NDJSON codec, limits, manifest model and validator, error codes, canonical manifest digest. **No Syntila, Cloud, Space or Thread imports.** This is the single source for manifest validation: the Service's `plugins.validate` and the SDK call the same code, so a plugin that validates for the author validates in the Service. Mirrors the shape of `syntila_worker_protocol`. |
| `syntila_plugin_sdk` | `packages/syntila_plugin_sdk` | `syntila_plugin_protocol` | `abstract class PluginWorker { Future<Readiness> probe(ProbeMode); Future<WorkResult> execute(WorkRequest, WorkContext); }`, `runPlugin(plugin)` (stdin/stdout loop, handshake, ping/pong on its own timer, one-terminal-frame guarantee, frame-size guard, stdout purity: `print` is rerouted to stderr), `WorkContext.progress()/activity()`, `CancellationToken`, session store helper rooted at `dataDir`. |
| `syntila_plugin_conformance` | `packages/syntila_plugin_conformance` | `syntila_plugin_protocol` | The case set and a `PluginLauncher` interface. Two launchers (§3). |

The Engine's plugin host reuses `syntila_plugin_protocol` for frames, so the
host and every plugin use one codec. The Engine continues to have no Cloud,
Space, Thread, Workflow, D1 or UI dependency.

Dart caveat documented in the SDK README: Dart is single-threaded per isolate. A
CPU-bound synchronous loop stops pong replies. The SDK's heartbeat runs in a
separate isolate, and `execute` guidance is to use `await` points or compute
isolates. The conformance case `heartbeat.during_work` catches the failure.

### 1.2 Authoring flow

```text
dart create -t console my_plugin           # or: dart run syntila_plugin_sdk:init
dart compile exe bin/my_plugin.dart -o build/linux-x64/my_plugin
dart run syntila_plugin_sdk:pack            # writes plugin.json with artifact digests
dart run syntila_plugin_conformance -- ./build   # author-side check, no Syntila install needed
syntila plugins import ./build              # Plus: Service-side import, validate, test, register
```

`pack` fills `artifacts[*].sha256/size` and prints `manifestDigest`. It never
signs unless `--sign-key` is passed; signing uses a key file the author holds and
nothing about it is sent anywhere.

### 1.3 Reference plugins

1. **`examples/plugins/echo_dart`** (Dart, in-repo, Apache-2.0 or repo license):
   echoes the prompt, emits three progress frames, honours cancel, supports
   `read_only`, and optionally implements resume with a file under `dataDir`.
   Deterministic. It is the fixture for Engine, Service, Cloud e2e and
   conformance tests, and the documentation example. It is built by tests; no
   binary is committed.
2. **`examples/plugins/echo_python`** (≈ 80 lines, stdlib only): proves language
   neutrality and the `requires` flow. CI-gated on interpreter availability, not
   required for a release.
3. **`examples/plugins/misbehaving`** (test-only, never documented as an
   example): configurable faults (oversized frame, silent hang, ignore cancel,
   stdout noise, double terminal frame, crash, escape artifact path, output
   flood). Used by the Engine host's limit tests and as the negative fixture for
   the conformance suite itself.

## 2. Conformance suite cases (`suiteVersion 1.0.0`)

> **As implemented (21 cases):** `handshake.identity`, `handshake.version_negotiation`,
> `handshake.unsupported_protocol`, `probe.passive`, `execute.single_terminal_frame`,
> `execute.id_correlation`, `execute.progress_ordering`, `execute.large_prompt`,
> `frame.unknown_type_tolerated`, `frame.unknown_field_tolerated`,
> `frame.malformed_input_survives`, `frame.crlf_tolerated`, `heartbeat.pong`,
> `cancel.within_grace`, `cancel.idempotent`, `cancel.after_terminal_ignored`,
> `shutdown.within_grace`, `stdin.eof_exits`, `manifest.capabilities_subset`,
> `resume.roundtrip`, `resume.unknown_key_session_not_found`. Stdout purity is
> checked on every frame read, which replaces a separate case. Not implemented
> because they need the host or plugin cooperation: `handshake.within_timeout`
> (covered by the host's deadline tests), `probe.state_values`,
> `execute.output_limit`, `execute.artifact_paths` and `heartbeat.during_work`
> (all enforced and tested in the Engine host), `execute.read_only_request`.


Each case is a function of observed frames and timing against the protocol
document. Cases tagged *optional* run only when the manifest declares the
capability. A case result is `passed | failed | skipped` with a redacted detail.

| Area | Case IDs |
| --- | --- |
| Handshake | `handshake.identity`, `handshake.version_negotiation`, `handshake.unsupported_protocol`, `handshake.within_timeout` |
| Readiness | `probe.passive`, `probe.state_values`, `probe.within_timeout` |
| Execute | `execute.single_terminal_frame`, `execute.id_correlation`, `execute.progress_ordering`, `execute.large_prompt` (512 KiB), `execute.output_limit`, `execute.artifact_paths`, `execute.read_only_request` |
| Framing | `frame.ndjson_only_on_stdout`, `frame.unknown_type_tolerated`, `frame.unknown_field_tolerated`, `frame.malformed_input_survives`, `frame.crlf_tolerated` |
| Liveness | `heartbeat.pong`, `heartbeat.during_work` |
| Control | `cancel.within_grace`, `cancel.idempotent`, `cancel.after_terminal_ignored`, `shutdown.within_grace`, `stdin.eof_exits` |
| Manifest | `manifest.matches_hello`, `manifest.capabilities_subset` |
| Resume (*optional*) | `resume.roundtrip`, `resume.unknown_key_session_not_found` |

What it deliberately does **not** test: whether declared network/filesystem
access matches behaviour, whether the plugin leaks secrets, whether it is
malicious, output quality. The runner prints the same disclaimer as the IPC
`plugins.test` result.

## 3. Running the suite

One case set, two launchers:

| Launcher | Used by | Spawns the plugin via |
| --- | --- | --- |
| `EngineHostLauncher` | The Service for `plugins.test`, `register` and `enable` gating (`syntila plugins test`) | Service → Engine plugin host → plugin. Same isolation, limits and redaction as production. Result is stored against `manifestDigest`; only this result satisfies the `plugin_conformance_required` gate. |
| `DirectProcessLauncher` | `dart run syntila_plugin_conformance -- <path>` (standalone binary also published for non-Dart authors) | `Process.start` of the plugin directly. Author tooling only: it is a separate package, never part of the `syntila` binary, cannot register or enable anything, and does not apply Engine limits or isolation. Free (no Plus) so third parties can build and verify plugins. |

An architecture test asserts `apps/workspace` and `engines/cli_worker` do not
import `DirectProcessLauncher`, and that the `syntila` CLI package does not
import either launcher.

Golden vectors: `docs/specifications/worker-plugin-vectors/*.jsonl` (transcripts
of valid and invalid exchanges, created in P1) let non-Dart implementers test a
codec without the runner.

## 4. Phased implementation plan

Every phase is independently reviewable and shippable behind the
`workspace.worker_plugins.v1` capability, and ends with the validations named.
`pnpm check` and `pnpm validate:full` are **not** routine phase gates
(AGENTS.md); `validate:full` remains reserved for release preparation. Only the
component validations that match the touched code run, and Flutter/macOS app
builds run only when the phase touches them.

### P1: Protocol, ADR and entitlement contract

- **Scope:** accept ADR-027; apply the three normative text edits (clarifying
  note beside `provider_specific_worker_executable: true`, second branch in the
  v8 execution-path diagram, one sentence in AGENTS.md rule 5); freeze protocol
  1.0 and the manifest schema; commit golden vectors; add the paid feature
  constant `workers.custom_plugins` and its label to `PAID_FEATURES`; define
  lease and manifest/frame types and schemas in `packages/` with tests. **No
  runtime behaviour.**
- **Tests:** schema accept/reject tables; canonical-digest vectors; lease
  signature verify/reject/expiry/binding vectors; `account-plan.test.ts` extended
  (`features` lists the new name only for Plus; `requirePaidFeature` 402 code);
  the v8 architecture guard still finds its literal exclusion.
- **Validation:** `pnpm validate:cloud`, `pnpm v8:architecture-check`,
  `pnpm docs:check`, `pnpm format:check`, `pnpm protocol:boundaries-check`.
- **Status (2026-11-03):** ADR accepted; text edits applied; `workers.custom_plugins`
  added; manifest and lease schemas in
  `packages/workspace-runtime-protocol/src/worker-plugin.ts`; lease issue/verify
  reference implementation and manifest digest in
  `apps/cloud/src/plugin-entitlement-lease.ts`; golden vectors in
  `docs/specifications/worker-plugin-vectors/`. **The new tests were written
  without a Node toolchain and have not been run.** Frame schemas stay
  Dart-owned (P2, `syntila_plugin_protocol`); the vectors are their contract.
- **Exit:** ADR accepted by the owners; open decisions D1-D4 and D13 resolved;
  guards green; no code path can execute a plugin.

### P2: Local single-Workspace execution, entitlement-gated

- **Scope:** `syntila_plugin_protocol`; Engine 1.4.0 plugin host (spawn from the
  read-only store path, digest re-check, no shell, built environment, limits §4.3,
  heartbeat, cancel, redaction, tree kill, Windows Job Object); Local Worker
  Protocol 4.2; Service plugin store, registry and lock-protected writes;
  `plugins.*` IPC (`list`, `show`, `import`, `validate`, `test`, `disable`,
  `remove`, `entitlement`) and CLI display; the Cloud lease endpoint
  (`POST /api/workspace-runtime/worker-plugins/entitlement`) and the Service
  lease verifier with clock high-water mark; conformance cases and
  `EngineHostLauncher`; `echo_dart` and `misbehaving` fixtures. Plugin Workers
  are **not yet routable from Cloud** (P3), so P2 exercises execution through
  `plugins test --live` and Service-internal execute.
- **Status (2026-11-03, partial; verified with `dart analyze`/`dart test`,
  `pnpm validate:engine` and `pnpm validate:cloud`):**
  - Done: `packages/syntila_plugin_protocol` (limits, frame codec,
    `PluginHostSession`, strict manifest validator, golden-vector replay);
    Cloud lease endpoint `POST /api/workspace-runtime/worker-plugins/entitlement`
    (optional secrets `SYNTILA_ENTITLEMENT_SIGNING_KEY` and
    `SYNTILA_ENTITLEMENT_KEY_ID`; 503 until configured);
    `engines/cli_worker/lib/src/plugin_host.dart` and `plugin_redactor.dart`:
    digest re-check before spawn, built environment (no `SYNTILA_*`), handshake,
    heartbeat, cancel (including a cancel requested before `execute`), deadline,
    5 s cancel grace then tree kill, stderr and message redaction, artifact path
    containment; proven against a fault-injecting fixture plugin
    (`test/fixtures/plugin_fixture.dart`) as real child processes.
  - Also done: Local Worker Protocol 4.2 (`WorkerExecutor` on `initialize.request`
    and `execute.request`; 4.0/4.1 frames unchanged); plugin-mode Engine
    (`syntila-agent --plugin`, `plugin_engine.dart`) with probe, execute,
    progress, result and error mapping onto existing stable issue codes (no new
    wire codes); profile-mode Engine rejects an executor; Engine 1.4.0. Proven
    end to end against the compiled Engine binary and the fixture plugin.
  - **Not done:** Service plugin store,
    registry and lease verifier; `plugins.*` IPC and CLI; `EngineHostLauncher`
    and the conformance runner; OS resource limits and isolation tiers (memory,
    CPU, open files, processes are not yet enforced). P2 is not complete and its
    exit criteria are not met.
- **Tests:** Engine host: each limit and every misbehaving fault ends with the
  process tree gone and the right code; digest-mismatch refuses before spawn;
  Service: lease absent/expired/tampered/rolled-back/other-machine all block
  `import`/`test`; editing the registry grants nothing; `service stop` kills
  plugins and keeps registration; Disconnect Cloud leaves the service running;
  architecture tests: CLI spawns nothing, Engine imports no Cloud/Space code.
- **Validation:** `pnpm validate:engine`; `scripts/internal/check-workspace-service.sh`;
  focused `dart test` under `apps/workspace` and `packages/syntila_plugin_*`;
  `pnpm validate:workspace` when the environment permits; `pnpm validate:cloud`
  for the lease endpoint; `pnpm v8:architecture-check`.
- **Exit:** a Plus account imports, validates and conformance-tests `echo_dart`
  on one machine; a lapsed lease stops new spawns; limits proven by tests; process
  cleanup proven on macOS and Linux (Windows jobs by CI primitives, device
  evidence listed as outstanding); no Cloud routing yet.

### P3: Cloud library, catalog and eligibility

- **Scope:** additive numbered migration for C1, C4 and the library/enablement
  tables; catalog `origin`/`owner_user_id` and the C2 reader filters; Profile
  registry rejection of plugin rows; routes for library and enablement with
  `requirePaidFeature`; `workspace.worker_plugins.v1` capability; strict-schema
  additions (C5, C8); inventory projection from Service; scheduler plugin branch
  with the new rejection codes (C6); dispatcher snapshot, session reference and
  atomic entitlement predicate (C7); digest-pin enforcement; `register`/`enable`/
  `disable`/`trust-signer` IPC with two-step consent; AX displays plugin Workers
  via the existing descriptor (only if a display change is needed).
- **Tests:** cross-account isolation (account B never sees A's plugin in any
  catalog, inventory, thread-policy, reply or Profile Lab list); lapse between
  scheduler read and INSERT admits nothing; borrower cannot reach an unshared
  plugin Worker; digest not pinned → no dispatch; read-only Step skips unenforced
  plugin; `workers.configureWorker` refuses a `pluginRef`; official-Worker
  scheduling, Free concurrency and sharing tests unchanged and green; Work flow
  e2e with `echo_dart` through Chat/Work and resume vs. reconstruction.
- **Validation:** `pnpm validate:cloud`, `pnpm cloud:schema-check`,
  `pnpm cloud:execution-boundary-check`, `pnpm check:fixture-e2e` (the two
  targeted acceptance tests), `pnpm v8:architecture-check`,
  `scripts/internal/check-workspace-service.sh`, `pnpm validate:engine` (4.2
  negotiation), `pnpm validate:app` only if AX changed.
- **Exit:** a Plus user's plugin Worker appears in the normal Workers list and
  runs a Work step end to end on one Workspace with the digest in the frozen
  snapshot; downgrade stops new admissions and drains per §3.5 of the
  architecture; nothing in official Worker paths regressed.

### P4: Export and multi-Workspace distribution

- **Scope:** export bundle format and `plugins.export`; `import` of a bundle
  verifying `manifestDigest` against the library record; `enable` on additional
  Workspaces; update flow with diff and re-consent; shareable-Workspace flag
  (D14); isolation self-test producing `readOnlyEnforced`; per-platform device
  evidence; decision D1 revisited if user demand for cloud blob storage is
  evidenced; downgrade/renewal runbook.
- **Tests:** export contains no data dir, logs, env, lease or credentials (golden
  listing); export works offline and lapsed; tampered bundle rejected; same
  plugin on two Workspaces pinned independently; update never moves a pin
  silently; renewal restores without re-consent when the digest is unchanged;
  device-gated tests for Linux (Landlock/bwrap/cgroup availability matrix),
  macOS (`sandbox-exec`), Windows (Job Object memory limit, restricted token).
- **Validation:** `pnpm validate:cloud`, `pnpm validate:engine`,
  `scripts/internal/check-workspace-service.sh`, focused Service tests; Windows
  and macOS isolation claims need device or release-build evidence and are
  recorded in `docs/acceptance/` before any user-facing claim.
- **Exit:** the same plugin runs on two machines of one account by explicit
  user action; isolation tier is reported truthfully per host; evidence file
  committed.

### P5: SDK and documentation

- **Scope:** publish `syntila_plugin_sdk`, `syntila_plugin_conformance` (and the
  standalone runner); `pack`/`init` tools; `echo_python`; author guide, security
  guide for users, deprecation policy page, changelog; `docs/` site updates
  (`pnpm validate:site` if the public site changes).
- **Tests:** SDK unit tests; a Dart plugin built with the SDK passes the full
  suite via both launchers; documentation examples compile in CI; the golden
  vectors decode with the SDK codec.
- **Validation:** `dart analyze`/`dart test` in the new packages (via
  `scripts/check-dart-packages.sh` once registered), `pnpm docs:check`,
  `pnpm format:check`, `pnpm validate:site` only for site changes.
- **Exit:** a third party with no repo access builds, packs and conformance-tests
  a plugin from published docs alone.

## 5. Open decisions (with recommendations)

| ID | Decision | Options | Recommendation |
| --- | --- | --- | --- |
| D1 | Library storage: binary vs metadata-only | (a) Cloud stores only metadata, digests and consent; binaries stay local and travel by export bundle. (b) Cloud stores encrypted binaries in R2. | **(a) for P3-P4.** Cloud never hosts or scans user executables, cannot leak an embedded secret, and the "Cloud never runs user code" posture stays simple. Revisit (b) only on evidence that bundle transfer blocks multi-machine users; if added, content-addressed, owner-private, size-capped, never executed by Cloud. |
| D2 | Signing requirement | Required / optional / org policy | **Optional** with signer pinning. Required signing needs a key-distribution story Syntila does not run. Reserve `consent_json.signer` for a future Workspace policy "require signed plugins". |
| D3 | Downgrade behaviour | Cancel immediately / finish / finish with cap | **Finish with a 30 minute cap** (`PLUGIN_LAPSE_DRAIN_MAX_MS`), then cancel with `plugin_entitlement_lapsed`. No new spawns at once. Intent, library, enablements and files kept; exports and removal stay available. |
| D4 | Entitled principal | Workspace owner / requester | **Workspace owner** (the library owner). Matches `workspace.sharing`. A borrower never needs Plus, but a borrower's Workspace use ends when the owner lapses, as today. |
| D5 | Lease TTL and key | 24 h + Ed25519 vs longer vs no lease | **24 h, refreshed ≤ 12 h, Ed25519, `kid` rotation**, one new Cloud secret and one compiled public key set. Longer TTL widens the lapse window; no lease cannot give offline grace. |
| D6 | Free-tier author tooling | Gate everything / free authoring | **Free `validate`, SDK and standalone conformance.** Gate import, test-in-service, register and enable. |
| D7 | Interpreted plugins (node, python) | Forbid / allow with `requires` | **Allow**, show the resolved interpreter at consent, state that it is not digest-pinned. Self-contained artifacts are recommended in the author guide. |
| D8 | Import sources | Local path and bundle only / URL / registry | **Local path and export bundle only in v1.** URL fetch adds Service egress and TLS pinning questions; a public registry is a different product. |
| D9 | Read-only Steps | Always eligible / only when enforced | **Only when the host reports `readOnlyEnforced`.** Otherwise Work (writable) Steps only, stated in consent. |
| D10 | Models and effort | Discovery / static list / none | **Static list in manifest (≤ 32) or Auto.** No discovery, no effort in v1. |
| D11 | Quotas | None / fixed | **20 plugins per account, 10 enabled per Workspace, 256 MiB per package, 512 MiB data dir.** Tunable constants beside the plan limits; counted in Cloud for the first two. |
| D12 | Windows AppContainer, Linux userns sandbox | Ship / defer | **Defer.** Report tiers truthfully; revisit with P4 device evidence. |
| D13 | D1 migration style | Edit baseline / numbered additive | **Numbered additive migration** (as 0094-0100 did), with the schema-reference check updated. AGENTS.md calls the schema a fresh-start baseline; maintainers should confirm that additive numbered migrations still meet that intent. |
| D14 | Plugin Workers on shared Workspaces | Visible to borrowers by default / opt-in | **Opt-in per enablement (`shareable`, default off).** A borrower's prompt would otherwise go to an owner-chosen custom program rather than a vetted provider CLI. |
| D15 | Doc drift: "signed Tool Profiles" | Leave / correct | **Correct in a separate docs change.** AGENTS.md and `ARCHITECTURE.md` say signed; V9 (`RELEASE_TRUST_AND_ROTATION.md`) says Profiles are not signed. Outside this task; flagged so ADR-027 does not inherit the ambiguity. |

## 6. Risks

| Risk | Mitigation or honest status |
| --- | --- |
| Plugins run arbitrary code as the user | Consent, digest pin, limits, truthful tiers, no safety claims; the user's responsibility is stated in the consent text. |
| No enforced isolation on Windows, weak on macOS, environment-dependent on Linux | Tiers are computed from a host self-test; read-only scheduling requires `enforced`; device evidence required for claims. |
| Catalog filter missed in one reader leaks a plugin name across accounts | C2 enumerates every reader; cross-account tests in P3; `cloud:execution-boundary-check` extended. |
| `workflow-workspace.ts` auto-enables scheduling for ready Workers | Entitlement and pin are enforced at scheduler and at INSERT, not in the enablement toggle. |
| TOCTOU on the store path by a same-user attacker | Documented as inside the same-user trust boundary; read-only store, re-hash before spawn. |
| Conformance misread as endorsement | Disclaimer printed on every result and in docs; result wording is "protocol conformant". |
| Dart single-isolate heartbeat starvation | SDK heartbeat isolate; `heartbeat.during_work` case. |
| Engine bump to 1.4.0 and Protocol 4.2 across mixed fleets | Capability-gated; scheduler requires Engine ≥ 1.4.0 for plugin rows only; 4.0/4.1 decode unchanged. |
| Lease key compromise | `kid` rotation; short TTL; public key set rolls with Workspace release. |
| `scripts/v8-architecture-rules.mjs` forbids `/workerPlugin/i` (a retired pre-v8 concept) in every source root, so identifiers such as `WorkerPluginManifest` fail `pnpm v8:architecture-check` | Found in P1 and fixed by naming (`PluginManifest`, `PluginWorker`, `plugin_*`). P2 code under `apps/workspace/lib` and `engines/cli_worker/lib` must follow the same naming. Do not weaken the rule; if it ever must change, amend it explicitly with an ADR-027 reference. |
| Entitlement UX before billing exists (ADR-022) | Inherits manual grants; no upgrade button, same as other paid features. |
