# ADR-020: Person Grants and Workspace Access Policy

**Status:** Accepted (Cloud implemented, AX screens pending); **Date:** 2026-10-17

Extends ADR-008. It does not replace Space membership or Space roles.

## Context

ADR-008 makes the Space the collaboration boundary and lets a Space execute on
a Workspace through an explicit Space grant. Member access
(`workspace_member_access`, migration 0073) limits Workers, models and efforts
for invited Space members, but it is one policy for every member, and it cannot
express lending a Workspace to a person who owns their own Spaces. Two
different sharing situations were being treated as one.

## Decision

### Two sharing modes

| | A. Invite to my Space | B. Lend my Workspace to a person |
|---|---|---|
| Space and Threads owned by | the Workspace owner | the borrower |
| Owner sees Threads | yes (Space owner) | no |
| Owner controls | Space roles | Workspace access only |
| Runs on | the Space's Workspace | the lender's Workspace, through a Person Grant |

Mode A is unchanged. Mode B adds a **Person Grant**: a grant from a Workspace
owner to one named person.

### Three-layer rule

A request runs only if all three allow it:

1. **Space role** (what the person may do in the Space) — unchanged.
2. **Workspace access** (what the requester may run on that Workspace) — the
   requester's effective access policy.
3. **Workflow** (read-only or stateful) — bounded by the policy `mode`.

Effective permissions are the intersection. A lower layer never widens a higher
one. The check is always made on the actual requester, never on the Space owner.

### Access policy

- A Workspace has one **default policy** applied to every person without an
  override. Initial default for new people: `mode = chat`.
- A person may have an **override** that replaces the default entirely. Policies
  are never merged. "Reset to default" removes the override.
- A policy lists Workers, with optional model and effort limits (null means all),
  plus a `mode`:
  - `chat`: read-only Workflows only (Chat, Research, Plan);
  - `work`: stateful Workflows, limited by Space role permissions and the
    approved Work Root;
  - `work+shell`: additionally `shell:execute` and `network:use`.
- The Workspace owner is never restricted.

### Person Grants (lending)

- A Person Grant lets the named person's own Spaces and Threads use the
  lender's Workspace within the person's effective policy.
- **Strict:** the grant is non-transferable. Other members of the borrower's
  Spaces gain nothing from it; a request from them fails with a clear message
  unless they hold their own access. There is no delegation option.
- **No re-lending:** only a Workspace owner can create a grant on that
  Workspace.
- **Revocation** takes effect for running work at the next lease check, and
  every create, change and revoke is audited.
- `work` mode on a grant requires an explicit owner action and a chosen Work
  Root.

### Lender visibility: usage only

The lender sees usage per borrower: request counts, run time, Workers used and
last used. The lender never sees Space names, Thread titles, prompts, results
or artifacts of the borrower. Tests assert the response shapes.

### Quotas

Each grant carries a concurrent-request limit and a total run-time limit.

### Workspace invitations (amended 2026-10-17)

A Workspace owner lends a Workspace by **Workspace invitation**, sent by email.
Acceptance creates the Person Grant and nothing else.

- A Workspace invitation does **not** create a `people_relationships` row.
  `/api/people` stays automatic (shared Spaces only), read-only and
  search-free. Profile and avatar visibility, and Space-invite shortcuts that
  depend on that relationship, are unaffected by lending.
- The lender sees borrowers in a separate "People with access" list: display
  name, email, effective policy and usage. The borrower sees the Workspace name,
  its owner and what the grant allows.
- `GET /api/workspaces` lists a lent Workspace to the borrower with
  `role: "member"` and `shared: true`. The borrower's Workspaces page shows its
  info, the Workers the grant allows and workflow configuration, but not the
  Member access or sharing sections. The borrower may make it their default
  Workspace; each inheriting Space then gets a lender-made grant capped by the
  borrower's mode, exactly as when a single Space selects it.
- Invitations expire, can be revoked before acceptance, and are single-use.
  The invitee must sign in with the invited email to accept. Accepting twice,
  or after revocation or expiry, fails.
- Revoking an accepted grant ends it as described above. If the two people later
  share a Space, the normal automatic relationship appears independently.
- Per-person overrides apply to anyone with access: Space members from
  `/api/people` and borrowers from "People with access".

## Security invariant

> Running on a Workspace requires the requester's own current access. Space
> membership, the Space owner's access, and another person's grant never confer
> it.

## Consequences

- `workspace_member_access` becomes the default policy plus per-person
  overrides; enforcement stays in `resolveWorkflowExecutionBindings`.
- The v8 D1 schema is a fresh-start baseline, so schema changes edit the
  baseline rather than add a migration chain.
- Revocation latency depends on lease checks.
- Implementation follows the phases in `docs/roadmaps/PERSON_GRANTS_PHASES.md`.

## Amendment (2026-10-31): a lent Workspace runs Chat only

- A Space that runs on a lent Workspace may use it only for the borrower, who
  owns that Space, and only for the Chat workflow. Every other workflow is
  refused, whatever the policy `mode`, and the Space grant is
  `["repository:read"]`.
- Members of the borrower's Spaces never use the lent Workspace, for any
  workflow, even if they hold their own Person Grant.
- Accepting an invitation no longer seeds a per-person override. The seeded
  `{"mode":"chat","workers":{}}` listed no Workers, so it shared nothing and
  Chat could not run. Without an override, the Workspace default policy
  applies (all Workers when there is none). Migration 0096 removes untouched
  seeds and narrows existing lent Space grants.
