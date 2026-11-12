# Cloud Workspace Runtime Cleanup — Phase 3

> **Historical implementation record.** The current architecture is defined
> in [WORKSPACE_ARCHITECTURE.md](WORKSPACE_ARCHITECTURE.md). Cloud route and
> D1 details remain here as an implementation audit.

This phase records the Cloud/D1 ownership map and the runtime boundary cleanup.

## Ownership map

| Data | Primary writer | Readers | Purpose | Decision |
| --- | --- | --- | --- | --- |
| `execution_workspaces` | Workspace registration and management routes | AX workspace APIs, scheduling, eligibility, grants | Stable user-owned Workspace record | Keep; lifecycle compatibility remains in `status` |
| `workspace_installations` | Registration/release routes | Registration and ownership checks | Stable installation ownership across credential rotation | Keep |
| `workspace_runtime_identities` | Registration/rotation routes | Runtime authentication service, ownership routes | Revocable hashed runtime credential | Keep |
| `workspace_sessions` | `WorkspaceRuntimeSessionStore` | Runtime authenticator and Gateway status | Connection audit/history and heartbeat timestamps | Keep; never live socket state |
| `workspace_worker_inventory` | Gateway inventory projection | Profiles, eligibility, scheduling, AX workspace views | Latest Workspace-owned Worker snapshot | Keep; revisions are Workspace-owned |
| `worker_scheduling` and audit | Scheduling/grant routes | Dispatcher and eligibility | Cloud admission state and audit | Keep |
| `workspace_space_grants` | Space/workspace grant routes | Eligibility and workspace APIs | Space authorization for a Workspace | Keep |
| `worker_assignments` and run tables | Dispatcher/scheduler | Gateway acknowledgements, Work history | Durable execution lifecycle and idempotency | Keep |
| Profile/catalog tables | Tool Profile registry | Workspace catalog routes, eligibility | Approved logical Workers and signed Profile releases | Keep |

Identity columns are stable and use the API vocabulary `workspaceId`,
`workspaceRuntimeId`, `installationId`, `workerId`, `workerTypeId`, `spaceId`,
`threadId`, `workflowId`, `runId`, and `assignmentId`.

## Runtime authentication

`WorkspaceRuntimeAuthenticator` is the single credential-authentication
service. It owns the query joining `workspace_runtime_identities` to
`execution_workspaces`, rejects revoked credentials and revoked Workspaces, and
compares the stored token hash. It exposes:

```text
authenticateRuntime(runtimeId, credential)
authenticateRuntimeHash(runtimeId, tokenHash)
resolveRuntimeBySession(sessionId)
authenticateSession(sessionId, credential)
assertRuntimeOwnsWorkspace(runtimeId, credential, workspaceId)
```

The WebSocket route, HTTP long-poll route, Gateway Durable Object, and
Workspace Profile catalog routes all use this service. They no longer carry
independent credential-token SQL. Registration routes still query identity
history for ownership transfer and rotation; those queries are lifecycle
operations rather than runtime authentication.

## Session ownership

The Durable Object owns live transport state:

```text
current socket or long-poll queue
cursor and pending acknowledgements
in-memory session binding
```

`workspace_sessions` is an audit/history projection. `WorkspaceRuntimeSessionStore`
owns opening, closing, and heartbeat updates. The heartbeat column is written
at most every five minutes and is never read for liveness: the Gateway derives
it from the last heartbeat kept in the socket attachment and the time the
runtime last answered an idle ping. D1 is not used
as the live socket queue or transport authority. The Gateway remains the
authority for fencing the current socket/session and for live event delivery.

## Connectivity status review

`execution_workspaces.status` currently exists in the v8 schema and is read by
older management, registration, scheduling, and eligibility paths. It is
therefore retained in this phase as the compatibility lifecycle/presence
projection. Runtime authentication treats only `revoked` as lifecycle
invalidation, while the Gateway owns current live transport state and session
heartbeat freshness. A future schema baseline can split this into an explicit
Workspace lifecycle column and a `runtime_presence` projection after the
remaining consumers are migrated together; no partial column cutover is safe
for existing development databases.

## Cleanup boundary

Routes remain organized by product surface, but runtime identity and session
SQL now live below them in the Gateway services. This keeps route handlers
responsible for HTTP validation and response shaping while the service classes
own D1 access and security invariants.
