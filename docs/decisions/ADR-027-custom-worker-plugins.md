# ADR-027: Custom Worker plugins

- **Status:** Accepted; MCP Worker execution is specified by [ADR-041](ADR-041-mcp-workers-on-worker-agents.md)
- **Date:** 2026-11-03
- **Details:** [Architecture](../architecture/CUSTOM_WORKER_PLUGINS.md), [Worker Plugin Protocol](../specifications/WORKER_PLUGIN_PROTOCOL_V1.md)

## Context

Owners need to run a locally approved custom Worker while keeping the generic CLI Worker Engine and Cloud independent of provider and plugin identities. A plugin is executable local code and requires an explicit trust boundary.

## Decision

1. Custom Workers are MCP Worker packages. Connect imports and approves an exact package identity and digest on the owner's computer. The generic CLI Worker Engine hosts the package as a child process; Connect supervises the Engine, and no provider-specific Worker executable is added to Syntila.
2. Cloud stores account library metadata and Worker pins. A dispatched assignment freezes the selected pin. Connect independently verifies local approval and tool pins before execution. A changed package requires fresh approval. The detailed admission and readiness rules are in ADR-041.
3. Cloud gates custom Worker execution on the owner's `workers.custom_plugins` entitlement. Library management is available on all plans; local approval does not grant entitlement.
4. A process boundary is not a sandbox. Plugin code runs with the local user's permissions, and outputs are untrusted. Resource limits do not establish filesystem or network isolation. Claims about enforcement require platform evidence.
5. Plugin identifiers and pinned digests are data. The Engine, Connect and Cloud do not branch on individual plugin or provider identities. The existing `plugin` wire identifiers remain part of the contract.

## Consequences

The owner is responsible for trusting a package and its local access. Signed Profile execution and MCP Worker execution share the generic Engine boundary. Installed release, device and real-provider acceptance remain separate from automated unit and integration tests.
