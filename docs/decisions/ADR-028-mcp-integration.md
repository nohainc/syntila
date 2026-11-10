# ADR-028: MCP integration (tools and custom Workers)

**Status:** Accepted (2026-11-06, owner approval). Phases M1+ are no longer gated on it.
**Date:** 2026-11-05
**Builds on:** [ADR-018](ADR-018-generic-cli-worker-engine-and-tool-profiles.md) (anticipates an MCP Engine), [ADR-027](ADR-027-custom-worker-plugins.md)
**Plan:** [MCP integration plan](../roadmaps/MCP_INTEGRATION_PLAN.md)
**Contracts:** [MCP host v1](../specifications/MCP_HOST_V1.md), [MCP Worker profile v1](../specifications/MCP_WORKER_PROFILE_V1.md), [MCP server manifest v1](../specifications/MCP_SERVER_MANIFEST_V1.md), [Threat model](../security/MCP_THREAT_MODEL.md)

## 1. Context

Syntila has two executor kinds below the Engine: `profile` (official provider
CLIs) and `plugin` (user executables speaking the NDJSON Worker Plugin
Protocol). There is no MCP support. Users want to (a) give Workers access to
existing MCP tools, (b) call MCP tools directly from workflows, and (c) connect
local and remote custom Workers through a standard protocol rather than a
Syntila-specific one.

## 2. Decision

1. **Official Workers keep Profiles.** MCP does not replace Engine + Profile
   for Codex, Claude, Gemini or future API Profiles.
2. **MCP is the single open-integration protocol** for local/remote tools and
   local/remote custom Workers. Syntila is the MCP *host*; the Engine contains
   the MCP *client(s)*. Syntila never acts as an MCP client inside Cloud.
3. **Two classes, never conflated.** An *MCP Tool* server exposes operations. An
   *MCP Worker* additionally implements the Syntila MCP Worker profile and may
   receive whole assignments. Class is declared in the manifest and verified at
   connect time.
4. **One custom-Worker protocol long term.** The NDJSON Worker Plugin Protocol
   is frozen at v1.x and deprecated at M6; plugin packaging and trust
   (manifest, digest pin, consent-by-hash, signer recognition, limits,
   supervision, conformance) are retained and wrap a local MCP server.
5. **The Engine remains the only process host.** MCP servers are launched by
   the Engine through the existing plugin host (limits, Job Object, tree
   cleanup, redaction). Local Worker Protocol advances additively to 4.3 with
   `executor.kind = "mcp"`.
6. **No provider/server identity in Syntila code.** Servers are data
   `(serverId, version, digest|endpoint, origin)`. Per-CLI MCP configuration
   differences live in Profile data (`mcpToolConfig`), not Engine branches.
7. **Cloud never holds secrets.** OAuth tokens and server credentials stay in
   the Workspace Service's local store. Cloud receives only enablement state
   and tool-definition hashes.
8. **Safe defaults.** Official Workers receive MCP servers only for the
   Workspace owner's own work (amended, see §7); sampling, roots and
   elicitation are not offered in v1; tool output is untrusted data;
   definition drift blocks calls until re-consent.
9. **Client implementation:** an owned, small Dart package
   (`syntila_mcp_protocol`) unless M1 evaluation finds an official Dart SDK that
   passes the host vectors and pins protocol versions; the choice is recorded
   as an amendment to this ADR.
10. **Entitlement:** MCP Workers reuse `workers.custom_plugins` admission. MCP
    Tools are free on all plans in v1 (open question O1).

## 3. Why this respects the v8 exclusion

Same argument as ADR-027 §3: Syntila ships no server and no provider adapter;
the Engine host is provider-neutral; one audited process host and cancellation
path remain. `provider_specific_worker_executable: true` stays verbatim.

## 4. Alternatives

| Alternative | Verdict |
| --- | --- |
| Keep NDJSON only, MCP not supported | Rejected: no ecosystem interoperability. |
| MCP for tools only, plugins for Workers forever | Rejected: two author-facing Worker protocols to document, test and support. |
| Replace Profiles with MCP adapters for official CLIs | Rejected: adapters still need provider knowledge; loses Profile versioning/evidence. |
| Syntila as MCP *server* exposing Workspace to external hosts | Out of scope; separate ADR if wanted. |
| MCP client in Cloud | Rejected: credentials and local files are Workspace-side. |

## 5. Consequences

- New package, Engine host module, Service registry/IPC, Cloud step kind and
  inventory columns, Profile capability, SDK mode and conformance launcher.
- A second class of untrusted content (tool descriptions/results) enters model
  context; mitigations are mandatory, see the threat model.
- Spec churn risk is bounded by pinned, negotiated protocol versions.
- Transition period has two Worker protocols; bounded by M6.

## 6. Open questions

- O1: Should remote MCP Tools be a paid feature?
- O2: Official Dart MCP SDK vs owned codec (decided in M1).
- O3: Minimum MCP spec revision to pin first (decided in M1 from the then-current spec; must include progress, cancellation and Streamable HTTP).

## 7. Amendment (2026-11-11): owner-scoped servers, no per-Step selection

**Supersedes** the per-Worker bindings and the per-Step `mcpTools` selection
that §2.8 originally implied. Three places to configure one server (CLI to add,
Settings to bind, the workflow to select) proved too complicated: a server could
be added, consented and bound and still never reach a run.

1. **The Workspace app is the only place to add servers.** Local
   (`syntila mcp add`) and remote (`syntila mcp add-remote`) servers are added
   on the machine that runs them. Settings in the web app can review consent,
   test, enable, disable and remove, but cannot add servers; the Workspace
   refuses a Cloud-relayed `addRemote`.
2. **No Worker bindings, no Step selection.** Every enabled, consented server is
   given to every official Worker and every Workflow run on that Workspace.
   Consent (with its definition hash and drift re-consent) remains the single
   gate. Legacy `bindings` in the local registry and `mcpTools` in saved
   Workflow configurations are ignored; the inventory's `boundWorkerTypes` is
   optional for older Workspaces.
3. **Owner only.** The Workspace grants servers only when the assignment's
   authenticated `requestedByUserId` equals its registered `ownerUserId`. Work
   by Space members or shared-Workspace users runs without MCP servers, because
   the servers act with the owner's local files and credentials. Sharing servers
   with others is deferred to a future decision.
4. **Fewer servers, never a failed run.** A server that cannot be launched
   safely (remote for an official Worker, command changed since consent), a
   Profile without the MCP slot, or an unreadable registry leaves the server(s)
   out and is reported in the Workspace log; the run continues.

