# ADR-035: Worker-targeted execution and eligibility

- **Status:** Accepted and implemented
- **Date:** 2026-11-19, revised 2026-11-24
- **Depends on:** ADR-032, ADR-033, ADR-034
- **Related:** [Work v1](../specifications/WORK_V1_CONTRACT.md), [Execution lifecycle](../specifications/EXECUTION_LIFECYCLE_V9.md), ADR-042 (Space member access), ADR-043 (Person Shares)

## Context

People run AI work on a Worker they choose. Work must never run on a Worker the
requester may not use, and never silently on a different one.

## Decision

1. **Assignments target `worker_instance_id`.** Every Step of a Work Request is
   bound to one Worker ID; there is no other execution target.
2. **Eligibility**, checked on the server at admission, at dispatch of every
   Step and on every retry, never only in the picker:
   - the Worker is enabled, not revoked, and its Agent is online;
   - the requester may use it: owner, Space member access (ADR-042) or Person
     Share (ADR-043), within that grant's mode and limits;
   - the Type's Profile declares every capability the Steps need
     (`capabilities`; a Profile that declares none makes no claim);
   - the model and effort are in the catalog the Worker reported and in the
     owner's allow-list;
   - the requester may execute in the Thread.
3. **Snapshot at acceptance:** Worker, Actor, Type, Profile digest and revision,
   model, effort, permissions. Later renames or Profile changes never affect an
   accepted request.
4. **Execution stays its own domain.** Work Request → Run → Task → Assignment →
   attempt, with start permits, leases, revocation and terminal evidence.
   Transport acknowledgements are not admission.
5. **Offline: reject** with `worker_offline`. No queue, no fallback.
6. **Files.** A person's attachments are uploaded to R2 before any Step starts.
   Any Worker that runs a Step of the request may download them with its own
   session ([Input Delivery](../specifications/INPUT_DELIVERY_V1.md)).
7. **Saved configurations** store Worker IDs and are re-checked on every use; a
   configuration that points to an unusable Worker fails clearly
   (`worker_unavailable`) instead of substituting another.
8. A plain message never runs a Worker. Only Ask AI, a mention or an automation
   creates a Work Request. Reading a Thread never grants the right to execute;
   Direct Spaces never grant access to the other person's Worker.

## Provider usage

The owner asks for a Worker's provider usage (`POST /api/workers/:workerId/usage`).
The Worker's gateway asks Connect on its next heartbeat; Connect runs the
Profile's usage command through the Engine and answers with
`PUT /api/worker-agent/usage`. The report is relayed to the waiting owner from
memory and never stored.

## Failures and full access

- An Agent failure carries a Cloud error code as a label (unknown reasons are
  `execution_failed`); the provider CLI's own message travels in
  `providerFailure`, is stored encrypted, and is shown to the requester.
- Whether a Worker's provider CLI may run any command without asking is the
  owner's local choice in Connect (`fullAccess`, default off). Cloud cannot set
  it. Read-only Steps never get it, and a Person Share never does. When it is
  on, anyone who may send Work to that Worker can cause commands to run on that
  computer.
