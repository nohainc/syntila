# ADR-015: First-party Workers

- **Status:** Accepted; Worker identity and selection are specified by [ADR-032](ADR-032-worker-instance-and-actor-identity.md) and [ADR-035](ADR-035-worker-targeted-execution.md)
- **Details:** [First-Party Worker Catalog](../specifications/FIRST_PARTY_WORKER_CATALOG_V1.md), [Tool Profile](../specifications/TOOL_PROFILE_V1.md)

## Context

People select AI Workers without exposing provider credentials or depending on provider-specific execution code in Cloud.

## Decision

Official Worker Types resolve through signed Profiles to provider CLIs under the generic CLI Worker Engine. A Worker is a user-owned instance of one Type with its own identity, credential, session and readiness. Connect owns local activation, readiness and provider sign-in; Cloud receives the safe readiness and model projection and validates Worker eligibility for each request.

A request selects a Worker by ID, not by executable path or provider credential. The accepted assignment records its Profile and execution selection. Profile or CLI changes do not silently alter an already accepted snapshot. The provider CLI starts locally through the generic Engine.

## Consequences

Cloud and the app remain provider-independent. Local readiness and provider availability can change independently of the Worker's identity. A Worker must be authorized and ready when selected and dispatched; an unavailable Worker is not silently substituted.
