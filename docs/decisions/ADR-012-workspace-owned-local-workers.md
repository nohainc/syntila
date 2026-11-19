# ADR-012: Workspace-Owned Local Workers

> **Superseded in part (proposed, 2026-11-19).** The Workspace-owns-Workers and Workspace-as-routing-identity parts ('Workspace owns local execution', 'Logical Worker identity', 'Authorization and usage') are replaced by [ADR-032](ADR-032-worker-instance-and-actor-identity.md) (Worker Instance identity), [ADR-034](ADR-034-standalone-worker-agent-and-session-fencing.md) (standalone Agent) and [ADR-035](ADR-035-worker-targeted-execution-and-workspace-removal.md) (Worker-targeted execution). The process boundary and security invariants remain current. Status becomes final when ADR-032 to ADR-039 are ratified; see [WORKER_FIRST_IMPLEMENTATION_PHASES.md](../roadmaps/WORKER_FIRST_IMPLEMENTATION_PHASES.md).

**Status:** Accepted; current Workspace ownership boundary. Worker identity and catalog are refined by [ADR-015](ADR-015-first-party-worker-v1-contract.md); local execution is defined by [ADR-018](ADR-018-generic-cli-worker-engine-and-tool-profiles.md).

## Context

Syntila needs a stable boundary between Cloud scheduling and machine-local execution. Provider credentials, filesystem access, installed tools, and process lifecycle belong to the machine that performs the work.

## Decision

### Workspace owns local execution

Syntila Workspace is the persistent machine runtime and security supervisor. It owns the Work Root, local Worker readiness and activation, local permissions, Profile admission/cache, Engine process supervision, cancellation, logs, and diagnostics.

A Workspace is a Cloud resource with one owner. A local Worker belongs to exactly one Workspace and is synchronized to Cloud only as safe inventory and readiness evidence.

### Logical Worker identity

The Worker Type is a stable product identity used in Thread configuration, scheduling, history, and AX. The Worker is not a provider binary or model. The supported first-party catalog and slot rules are defined by ADR-015 and [First-Party Worker Catalog v1](../specifications/FIRST_PARTY_WORKER_CATALOG_V1.md).

### Process boundary

Workspace runs the generic CLI Worker Engine as a separate process. The Engine executes an admitted signed Tool Profile and invokes the locally installed provider CLI. Workspace owns process-tree cleanup, deadlines, output bounds, cancellation, and shutdown behavior. Provider credentials remain in provider-managed local configuration.

The Engine and Profile contract is defined by [ADR-018](ADR-018-generic-cli-worker-engine-and-tool-profiles.md) and [Tool Profile v1](../specifications/TOOL_PROFILE_V1.md).

### Authorization and usage

Cloud owns Space membership, Workspace ownership, Space-to-Workspace Grants, Thread authorization, scheduling state, and concurrency ceilings. Workflow Workspace selection transitions ready local Workers into the schedulable state; AX configures authorized logical Worker use in Workflows. Workspace enforces local readiness, permissions, and concurrency limits; Cloud cannot widen those local limits.

See [ADR-016](ADR-016-ax-owned-worker-usage.md) for the AX and Cloud usage policy.

## Security invariants

- Provider credentials never enter Cloud inventory, assignments, audit events, or artifacts.
- Cloud assignments identify logical Workers and bounded execution policy; they do not choose local executable paths or issue shell commands.
- Workspace verifies Profile releases before use and supervises every Engine/provider process tree.
- Readiness, activation, Cloud scheduling, and local permissions remain separate state and authorization dimensions.

## Consequences

Workspace can continue to enforce local security and process lifecycle independently of Cloud connectivity. Cloud can schedule stable Worker identities without learning provider secrets or implementation details. New CLI integrations use the generic Engine and signed Profiles rather than adding another local execution runtime.
