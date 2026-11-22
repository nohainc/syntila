# ADR-035: Worker-targeted Execution, Eligibility and Workspace Removal

- **Status:** Proposed
- **Date:** 2026-11-19
- **Split from:** ADR-031 (D3, D4 execution parts, product UX, sharing policy)
- **Order:** 4 of 8. Depends on ADR-032, ADR-033 and ADR-034.
- **Related:** `WORK_V1_CONTRACT.md`, `EXECUTION_LIFECYCLE_V9.md`, ADR-029, `WORKSPACES_UX_CONTRACT.md`

## Context

Today Work Requests resolve a Workspace through Space-to-Workspace grants, and assignments require `execution_workspace_id` and `runtime_identity_id` (both NOT NULL). That forces users through Workspace setup and grants just to run their own Worker.

## Decision

1. **Assignments target `worker_instance_id`.** The Workspace columns become nullable and are kept as legacy metadata on historical attempts.
2. **Eligibility (v1):** `worker.owner = requester`, the Worker is enabled, its Type and capabilities fit the request, **and** the requester has execute rights in the Thread. It is checked at admission on the server, never only in the UI picker.
3. **Snapshot at acceptance:** Worker ID, Actor, Type, Profile digest/revision, model, effort, permissions and attempt. Later renames or Profile changes never affect an accepted request.
4. **Execution stays a separate domain.** Work Request → Run → Task → Assignment → attempt, with admission, start permits, leases, revocation and terminal evidence as in V9. Transport acknowledgements are not admission.
5. **Offline policy (v1): reject** with `worker_offline`. No queueing and no silent switch to another Worker. Queueing with a timeout can be added later in its own ADR, together with its UX.
6. **Sharing (v1): owner-only.** The `worker_sharing_grants` table may be created but stays unused. Reading a Thread never grants the right to execute. Direct Spaces never grant access to the other person's Worker.
7. **Workspace leaves the product.** The Workers page replaces Workspaces. Space- and Workflow-level Workspace selectors and grants are removed. Saved configurations store Worker IDs and are re-checked on every invocation. A configuration that points to an inaccessible Worker fails clearly instead of falling back.
8. **Workflows with several Workers** bind each step to a Worker ID. Every step goes through the same eligibility check.
9. A plain human message never runs a Worker. Only an explicit Ask AI, mention or automation intent creates a Work Request.

## Consequences

- New users go from adding a Worker to asking from a Thread without ever seeing a Workspace.
- `assignment-dispatcher.ts`, `workspace-gateway.ts` and `routes/work-creation.ts` are refactored. The old Workspace path stays behind a flag until parity is shown. **A given assignment runs on only one path at a time.**
- ADR-012, ADR-029 and the Workspaces UX contract are partly superseded. Those docs are marked with links; their historical text is not rewritten.

## Addendum: provider usage for a Worker Agent

A Worker with no Workspace (a Syntila Connect Worker) reads the provider's usage report through its own Agent, not through a Workspace. The Agent protocol is unchanged: the owner calls `POST /api/workers/:workerId/usage`; the Worker's gateway object pushes a `usageRequestId` in a `workspace.heartbeat.ack` payload (repeated on heartbeats until answered, like `refreshModels`); the Agent runs the Profile's usage command through the Engine and answers with `PUT /api/worker-agent/usage` (session-authenticated). The gateway relays the report to the waiting owner from memory. It is owner-only, shown live and never stored. Agents older than this change never answer, and the owner sees a timeout message asking to update and restart Connect.

## Addendum: failures and full access on a Worker Agent

- **Failure text.** An Agent failure carries a Cloud execution error code only as a label (unknown reasons are `execution_failed`); the provider CLI's own message travels unmodified in `providerFailure` (stderr first, then the structured error as plain lines) and the Cloud stores it encrypted. The web app shows that text in the error color instead of the generic message.
- **Full access.** Whether a Worker's provider CLI may run any command without asking is the owner's local choice, kept in the Worker's `config.json` (`fullAccess`, default false), set with `syntila-connect full-access [on|off]` or the Connect app. The Cloud cannot set it, and it is read at the start of every assignment. When on, Connect runs the Engine with `full_access` (read-only assignments stay `provider_default`); otherwise `restricted`. Anyone who can send Work to that Worker, including Space members, can then cause commands to run on that computer.
