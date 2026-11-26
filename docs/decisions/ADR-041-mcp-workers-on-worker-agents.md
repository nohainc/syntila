# ADR-041: MCP Workers on Worker Agents

- **Status:** Accepted and implemented
- **Date:** 2026-11-20
- **Depends on:** ADR-027, ADR-034, ADR-035

## Context

MCP Worker packages run local code. The owner must choose and approve the exact
package on the computer running Connect. Cloud stores catalog and pin metadata;
it must not install a package or obtain provider credentials for the Worker.

## Decision

Connect imports MCP Worker packages locally and records approval of their exact
ID, version and manifest digest. It inspects the package through the generic
CLI Worker Engine's MCP probe and records tool pins. Connect admits an MCP
assignment only when the installed package, approval and recorded pins match.
The generic CLI Worker Engine runs the package through its plugin host; there
is no provider-specific Worker executable.

Connect reports runnable approved pins in Worker readiness. Cloud checks the
Worker's pinned package and the owner's entitlement during eligibility and
snapshots the selected pin into an assignment. A changed package requires a new
local approval. Tool output remains untrusted input, and failure to approve or
inspect a package prevents execution.

Stored Type identifiers and protocol fields use `plugin` where specified by
the existing contract; the product calls these MCP Workers. The package store,
Connect runner, Engine host and Cloud eligibility tests cover their respective
boundaries. Platform-specific isolation claims require tests on each platform.
