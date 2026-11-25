# ADR-041: MCP Workers on Worker Agents

> Terminology: ADR-027 calls these "plugins". They are MCP Worker packages (`kind: "mcp"`), not MCP servers (ADR-028). Stored identifiers keep the old name (`plugin-<12 hex>` Type ids, `origin = 'plugin'`, `plugin_entitlement_required`); new surfaces say "MCP Worker".

- **Status:** Accepted (option A) and implemented.
- **Date:** 2026-11-20
- **Depends on:** ADR-027 (custom plugins, MCP Worker packages), ADR-034 (Agent), ADR-035
- **Closes:** the P5 gap "MCP Worker Types" in `WORKER_FIRST_IMPLEMENTATION_PHASES.md`

## Context

ADR-027 MCP Workers are External Workers identified by `(pluginId, version, digest, origin)`, imported locally into Syntila Connect's store (`packages/syntila_mcp_worker_store`), executed by the generic CLI Worker Engine's plugin host, and available to Syntila Plus owners (`plugin_entitlement_required`). Running an MCP Worker executes local code chosen by the owner, so the owner approves the exact manifest digest on the machine running Connect — never via Cloud download.

## Options

**A. The Agent runs plugins, approved locally by digest.**
- The Agent keeps a plugin store (`<data>/plugins/<digest>/`) filled only by a local command (`syntila-worker plugin import FILE`), never by a Cloud download. Import verifies the package and records `(pluginId, version, digest)` in a local allow list the owner can list and remove.
- The Agent reports installed plugins in its inventory as Types `plugin-…` with the digest. The Cloud accepts a plugin Type only if the owner's library names that `pluginId` and the Plus entitlement is active (existing rules).
- An assignment names the Type and the pinned digest; the Agent refuses a digest not in its allow list (`mcp_worker_not_approved`) and never fetches one.
- Execution reuses the Engine's process supervision, environment builder, cancellation and redaction (ADR-027 decision 1); plugin processes get only the folders the step was granted.
- Cost: Agent plugin store and runner, inventory extension, eligibility change (allow `origin = "plugin"` when the entitlement and digest match), conformance and escape tests on all three OSes.

**B. Plugins stay on the Workspace Service.** No Agent work; Plus users keep the Workspace for plugins, which keeps the Workspace alive for them.

## Recommendation
Option A, after stateless Workflows on the Agent are proven on real machines, behind a new flag `worker_plugins`, off by default. The plugin runner is the same code path as the Workspace's, so it should be shared in `packages/syntila_cli_worker_runtime` rather than copied.

## Security notes for A
- The Cloud never ships plugin bytes to an Agent; a compromised Cloud can therefore not make an Agent run new code.
- The allow list is keyed by digest, so an updated plugin needs a new local approval.
- Plugin output is untrusted data, like any Engine output.

## Decision
Option A accepted (2026-11-20, owner). Implemented behind `worker_plugins`.

## Implementation status (2026-11-20)
Stage 1 (Agent side, in code): the local allow list (`mcp-worker list | approve | remove`, file `registry/approved-mcp-workers.json`) and the admission rule: an assignment carrying a `plugin` pin runs only if its exact id, version and manifest digest are approved on this machine (`mcp_worker_not_approved` otherwise); an approved pin currently ends with `mcp_worker_runner_unavailable`.

Stage 2 (not started, each needs running code on real machines): (1) extract the plugin store and runner from `apps/workspace` (`external_worker_store.dart`, `external_worker_executor.dart`, runtime) into a shared package used by both the Workspace and the Agent; (2) an Agent inventory report so the Cloud knows which `plugin-…` Types a Worker Instance can run, and a per-Instance pin (version, manifest digest); (3) Cloud eligibility: allow `origin = plugin` under flag `worker_plugins` when the owner is entitled (`paidOwner`) and the pin is set, and put the pin in the assignment payload; (4) the flag itself and conformance/escape tests on all three OSes.

Stage 2a/2b (in code, unverified until Dart runs): the store, registry and executor description moved from `apps/workspace` to `packages/syntila_mcp_worker_store`, used by the Workspace and the Agent. `syntila-worker mcp-worker import PATH` imports a package into `<data>/mcp-workers`, verifies it, and approves its exact (pluginId, version, manifest digest). The allow list is keyed by the manifest `pluginId` (kebab-case), not by the Cloud's `plugin-<hex>` Type id.

Stage 2c (not done): running one. The Engine supervisor already accepts a plugin executor target; the Agent still needs (1) tool pins: the one-shot `--mcp-probe` inspection and consent that `external_worker_service.dart` performs (it depends on `mcp_engine_probe.dart`, `mcp_registry.dart` and parts of `mcp_service.dart`, about 1,100 lines to extract), (2) `McpWorkerRunner` in `cli_engine.dart` that loads the pinned install from the store and calls the supervisor with the executor. Stage 2d (Cloud inventory, per-Instance pin, eligibility, flag `worker_plugins`) follows.

Stage 2c (in code, uncommitted until Dart runs): tool-pin inspection moved to `packages/syntila_mcp_worker_store` (`McpEngineInspection`, `workerToolPins`), used by both the Workspace probe and the Agent. `syntila-worker mcp-worker test ID` inspects an imported package through the Engine's `--mcp-probe` and records tool pins in `registry/mcp-worker-tool-pins.json`. `McpWorkerRunner.prepare` runs only an exact approved pin with recorded pins and a digest-verified install, and `CliEngineLauncher` passes the executor to the Engine supervisor. `AgentRuntime` admission now returns `mcp_worker_not_approved`, `plugin_conformance_required` or `plugin_digest_mismatch` from the runner instead of `mcp_worker_runner_unavailable`. Remaining: stage 2d (Cloud inventory, per-Instance pin, eligibility, flag `worker_plugins`).

Stage 2d (Cloud, in code, not run): flag `worker_plugins` (requires `worker_target_dispatch`); migration `0038_worker_mcp_pins.sql` (`worker_instance_mcp_pins`, one pin per Instance, tied to a library version); owner route `GET|PUT|DELETE /api/workers/:workerId/mcp-pin` (only a version and digest in the owner's own library); `acceptWorkerTarget` accepts a `plugin-…` Type without a Profile when the flag is on, the owner is entitled (`paidOwner`) and the pin is still in the library, and puts `mcpWorker {id, version, manifestDigest}` in the snapshot; the assignment payload carries it as `plugin`. Not done: the Agent inventory report (today the owner sets the pin by hand and the Agent checks its own allow list), the Worker-picker UI for MCP Worker Types, and the conformance/escape tests on all three OSes.

Agent inventory report (in code, not run): the Agent's `hello` readiness carries `mcpWorkers [{id, version, manifestDigest}]` (approved and tool-pinned on that machine, `McpWorkerRunner.runnable`). Cloud validates and stores it in the session's `readiness_json`; `GET /api/workers/:workerId/mcp-pin` returns it as `available` so the owner can pin one. Still not done: the Worker-picker UI (Flutter, cannot be compiled here) and the conformance/escape tests on all three OSes.

Worker-picker UI (in code, Flutter not compiled): Settings > Workers shows "MCP Worker version" for a Worker of a `plugin-…` Type. It lists the versions the connected Agent reports and pins one (`PUT /api/workers/:id/mcp-pin`) or clears the pin. The request picker itself needed no change: Cloud eligibility already decides which Workers can take a request. Still not done: conformance/escape tests on all three OSes.
