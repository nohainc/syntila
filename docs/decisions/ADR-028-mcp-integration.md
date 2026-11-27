# ADR-028: MCP integration (custom Workers)

**Status:** Accepted (2026-11-06; amended 2026-11-24 to scope to MCP Workers after legacy path removal; see [ADR-041](ADR-041-mcp-workers-on-worker-agents.md)).
**Date:** 2026-11-05
**Builds on:** ADR-018 (anticipates an MCP Engine), [ADR-027](ADR-027-custom-worker-plugins.md), [ADR-041](ADR-041-mcp-workers-on-worker-agents.md)
**Contracts:** [MCP host v1](../specifications/MCP_HOST_V1.md), [MCP Worker profile v1](../specifications/MCP_WORKER_PROFILE_V1.md), [Threat model](../security/MCP_THREAT_MODEL.md)

## 1. Context

Syntila has two executor kinds below the Engine: `profile` (official provider
CLIs) and `plugin` (user-supplied executables). Users want to connect local and remote custom Workers through a
standard protocol rather than a Syntila-specific one.

MCP tool calls from Workflows (direct `tool_call` steps and attaching MCP tool
servers to official Workers) were originally scoped here against the legacy
execution path and are deferred to a future decision for Syntila Connect (see
[ROADMAP.md](../../ROADMAP.md)).

## 2. Decision

1. **Official Workers keep Profiles.** MCP does not replace Engine + Profile
   for Codex, Claude, Gemini or future API Profiles.
2. **MCP is the open-integration protocol for custom Workers.** Syntila is the
   MCP *host*; the Engine contains the MCP *client*. Syntila never acts as an
   MCP client inside Cloud.
3. **MCP Workers implement the Syntila MCP Worker profile** and receive whole
   assignments through the Engine's plugin host. Class is declared in the
   manifest and verified at connect time.
4. **One custom-Worker protocol.** The earlier NDJSON plugin protocol is removed;
   plugin packaging and trust (manifest, digest pin,
   consent-by-hash, signer recognition, limits, supervision, conformance) are
   retained and wrap a local MCP server.
5. **The Engine remains the only process host.** MCP Worker servers are
   launched by the Engine through the existing plugin host (limits, Job Object,
   tree cleanup, redaction). Local Worker Protocol uses `executor.kind = "mcp"`.
6. **No provider/server identity in Syntila code.** Servers are data
   `(serverId, version, digest|endpoint, origin)`.
7. **Cloud never holds secrets.** Server credentials stay on the user's
   computer under Syntila Connect. Cloud stores only the owner's Worker plugin
   metadata and pinned manifest digest (ADR-041).
8. **Safe defaults.** Sampling, roots and elicitation are not offered in v1;
   output is untrusted data; manifest digest drift blocks execution until
   re-pinned.
9. **Client implementation:** an owned, small Dart package
   (`syntila_mcp_protocol`).
10. **Entitlement:** MCP Workers reuse `workers.custom_plugins` admission.

## 3. Why this keeps providers out of Cloud

Same argument as ADR-027 §3: Syntila ships no server and no provider adapter;
the Engine host is provider-neutral; one audited process host and cancellation
path remain. `provider_specific_worker_executable: true` stays verbatim.

## 4. Alternatives

| Alternative | Verdict |
| --- | --- |
| Keep NDJSON only, MCP not supported | Rejected: no ecosystem interoperability. |
| Replace Profiles with MCP adapters for official CLIs | Rejected: adapters still need provider knowledge; loses Profile versioning/evidence. |
| Syntila as MCP *server* exposing Connect to external hosts | Out of scope; separate ADR if wanted. |
| MCP client in Cloud | Rejected: credentials and local files stay on the user's computer. |

## 5. Consequences

- MCP Workers run on Connect through the Engine's plugin host (ADR-041), pinned
  per Worker Instance by `(pluginId, version, manifestDigest)`.
- Spec churn risk is bounded by pinned, negotiated protocol versions.
- Workflow `tool_call` step definitions remain in `@syntila/core` for future
  Connect support, and Cloud refuses `input.toolCall` requests until MCP tool
  calls on Connect are designed and shipped.

