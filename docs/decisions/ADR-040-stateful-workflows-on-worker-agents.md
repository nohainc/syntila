# ADR-040: Stateful Workflows on Worker Agents

- **Status:** Accepted and implemented
- **Date:** 2026-11-20
- **Depends on:** ADR-034, ADR-035, ADR-037

## Context

Stateful Work modifies a local folder and needs one authorized writer for a
Thread. Workers run through Connect on different computers, so Cloud must
coordinate ownership while Connect independently fences stale assignments.

## Decision

Cloud assigns a Thread lease to a Worker Instance in `thread_runtime_leases`.
A Thread has at most one active lease. Cloud issues a monotonically increasing
fencing token and validates the lease when admitting and dispatching stateful
work. Connect records the highest accepted token for the Thread locally and
refuses stale tokens. Worker session fencing independently prevents an old
session from acting after a newer one takes over.

Connect resolves the Space folder on the Worker's computer and enforces local
folder permissions. Cloud uses opaque folder identifiers; it does not receive
local paths. A lease expires or is released through the coordinator; a different
Worker cannot write under a lease held by another Worker.

## Consequences

A disconnected Worker can retain a lease until the coordinator releases it or
it expires. A Worker change does not transfer local files: any shared source or
handoff must be made available through the authorized product workflow. Tests
of the coordinator and Connect fencing protect these boundaries; operating
system and real-device behavior requires device evidence.
