# ADR-041: Plugin Types on Worker Agents

- **Status:** Proposed. Needs an owner decision between options A and B.
- **Date:** 2026-11-20
- **Depends on:** ADR-027 (custom plugins, MCP Worker packages), ADR-034 (Agent), ADR-035
- **Closes:** the P5 gap "plugin Types" in `WORKER_FIRST_IMPLEMENTATION_PHASES.md`

## Context
ADR-027 plugins are External Workers: MCP Worker packages identified by `(pluginId, version, digest, origin)`, imported by the Service into its own storage, executed by the Engine, and available only to Syntila Plus owners (`plugin_entitlement_required`). Their Type ids are `plugin-<12 hex>`; the inventory ties each to the owner's own library. `worker-eligibility.ts` refuses `origin = "plugin"` Workers on the Worker path, and the Agent has no plugin import, storage or runner. Running a plugin means running a program the owner chose, so the rule is that the owner approves the exact digest on the machine that runs it, never the Cloud.

## Options

**A. The Agent runs plugins, approved locally by digest.**
- The Agent keeps a plugin store (`<data>/plugins/<digest>/`) filled only by a local command (`syntila-worker plugin import FILE`), never by a Cloud download. Import verifies the package and records `(pluginId, version, digest)` in a local allow list the owner can list and remove.
- The Agent reports installed plugins in its inventory as Types `plugin-…` with the digest. The Cloud accepts a plugin Type only if the owner's library names that `pluginId` and the Plus entitlement is active (existing rules).
- An assignment names the Type and the pinned digest; the Agent refuses a digest not in its allow list (`plugin_not_approved`) and never fetches one.
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
_Pending._
