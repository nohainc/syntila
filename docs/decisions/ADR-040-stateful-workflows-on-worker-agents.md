# ADR-040: Stateful Workflows on Worker Agents

- **Status:** Accepted (option A) and implemented.
- **Date:** 2026-11-20
- **Depends on:** ADR-034 (Agent session fencing), ADR-035 (Worker-targeted execution), ADR-037 (local files)
- **Closes:** the P5 gap "stateful Workflows" in `WORKER_FIRST_IMPLEMENTATION_PHASES.md`

## Context

A `stateful_thread` step (Work, Implement) modifies a local repository and must have at most one writer per Thread. Syntila enforces single-writer exclusivity using `thread_runtime_leases` keyed to a Worker Instance (`worker_instance_id`), a fencing token tied to the Agent session epoch (ADR-034), and an expiry.

## Options

**A. Lease on a Worker Instance and its Space folder.** One Worker Instance holds the Thread lease; the checkout is the Space folder on that Worker's Agent (`WorkRoot.spaceDirectory`).
- Migration: `thread_runtime_leases.workspace_id` becomes nullable, add `worker_instance_id` (FK) with `CHECK (num_nonnulls(workspace_id, worker_instance_id) = 1)`; the partial unique index "one active lease per Thread" stays.
- Fencing: the lease stores the Agent session epoch (ADR-034). Every stateful assignment carries the fencing token; the Agent refuses a token lower than one it has seen for that Thread; a new Agent session for the same Worker supersedes the lease only after the old epoch is fenced.
- Admission: a stateful step is admitted only to the lease holder. A Thread already leased to another Worker is refused with `thread_leased_elsewhere` (the owner may release it).
- Write rights: the Space folder must be an Allowed Folder with write access (already required by `WorkRoot.spaceDirectory`). Two Workers never share one folder because only the holder is admitted.
- Cost: one migration, scheduler and coordinator changes, Agent-side token check, new tests. Reuses the existing lease expiry and release paths.

**B. Stateful Work stays Workspace-only.** Keep the refusal. Worker Agents run stateless Workflows only. No code change. The Worker-first goal "remove the Workspace" (ADR-035) is not met for Work and Implement, so the Workspace Service cannot be retired while those Workflows are offered.

## Recommendation
Option A, in two stages: (1) lease table change plus admission and fencing, behind a new flag `worker_stateful_work`, off by default; (2) enable only after a two-Agent conflict test (two Workers, one Thread) passes against a real Agent.

## Consequences of A
- Anyone who may execute in a Space can start stateful Work on a Worker they own; the lease prevents a second writer, not a second reader.
- A crashed Agent holds the lease until expiry; the owner can release it from the Thread.
- The checkout lives only on the leased Worker's machine; moving Work to another Worker starts from the Git remote (ADR-037 Git references), not from the old folder.

## Decision
Option A accepted (2026-11-20, owner). Implemented in two stages behind `worker_stateful_work`.

## Implementation status (2026-11-20)
Stage 1 is in code behind `worker_stateful_work` (requires `worker_target_dispatch`): migration 0037 (lease holder column, `work_requests.primary_worker_instance_id`), single-Worker rule for stateful requests (`stateful_single_worker`), lease start for a Worker holder, dispatch refusal `lease_not_active` / `thread_leased_elsewhere`, Agent refusal `stale_fence` (highest token per Thread persisted in `thread-fences.json`). Not yet verified: the full stateful Workflow run end to end on a real Agent, owner-initiated lease release from the Thread, and the two-Agent conflict test that gates enabling the flag.
