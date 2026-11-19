# ADR-013: Desktop Human Authentication and Dual Workspace Transport

> **Superseded in part (2026-10).** This record describes the earlier Flutter `Workspace.app`/`SMAppService` design. The Flutter GUI was removed; Workspace is now a headless Dart service plus the `syntila` CLI, configured by `workspace.nano`. The current contract is [WORKSPACE_ARCHITECTURE.md](../architecture/WORKSPACE_ARCHITECTURE.md). Read this document as history.

> **Also superseded in part (proposed, 2026-11-19).** The per-Workspace runtime connection and registration model is replaced by one connection per Worker: see [ADR-034](ADR-034-standalone-worker-agent-and-session-fencing.md) (session fencing, standalone Agent) and [ADR-038](ADR-038-unified-realtime-transport.md) (unified transport).

**Status:** Accepted; desktop lifecycle refined by [ADR-014](ADR-014-workspace-desktop-lifecycle.md)  
**Date:** 2026-09-27  
**Builds on:** ADR-005, ADR-012  
**Supersedes in part:** ADR-005 statement that machine-side applications never establish a human Better Auth session

## Context

The current Workspace lifecycle separates two identities:

- the human User;
- the Workspace runtime/machine identity.

The desktop needs an authenticated human API channel to inspect or repair its
registration after a runtime credential is revoked. The current registration
flow uses the desktop human session directly.

That produces poor recovery UX:

~~~text
Workspace runtime credential invalid/revoked
-> WebSocket cannot connect
-> desktop only knows transport failed
-> desktop signs in through browser-assisted auth
-> desktop verifies ownership and registers or recovers through Cloud HTTPS APIs
~~~

The product also currently treats WebSocket as the only runtime transport. A WebSocket is the preferred transport for assignments, cancellation, progress, inventory, and realtime state, but it should not be the only way a legitimate Workspace can communicate with Cloud.

The desired product model is:

~~~text
Syntila Workspace
  human session -> account/Workspace management APIs
  runtime credential -> machine execution APIs
  WebSocket -> preferred realtime runtime transport
  HTTPS long-poll -> fallback runtime transport
~~~

The desktop application becomes the primary management surface for one user's local Workspace and Workers. Syntila shows Workspace/Worker state and Space-facing execution availability, but does not own Workspace registration or local runtime recovery.

## Decision

### 1. Syntila Workspace authenticates the human User

Syntila Workspace gains a human sign-in flow backed by the same Better Auth identity system as Syntila.

The desktop must not reuse or scrape the browser's HttpOnly AX cookie. Instead, Cloud issues a desktop-specific human session after Better Auth authenticates the user.

Preferred flow:

~~~text
desktop creates desktop-auth intent
-> opens system browser
-> user authenticates with Better Auth
-> Cloud marks intent approved for that User
-> desktop exchanges one-time result
-> receives desktop human session credential
-> stores it in OS secure storage
~~~

Browser approval uses the authenticated Better Auth session and an explicit
approval action for the pending desktop intent; the user does not transcribe a
comparison code. The desktop keeps its waiting dialog open while the system
browser is used. The current desktop auth-intent contract is 1.1. This is
independent of the versioned desktop/runtime transport contract.

Each opened verification tab observes the intent's non-secret terminal status.
Canceling in Workspace cancels the intent with its poll credential; choosing
Cancel on the authenticated browser page denies the pending intent through the
Better Auth session. Tabs attempt to close automatically after approval,
cancellation, or expiry. If the system browser blocks script-initiated closing,
the tab displays a clear result and a manual **Close tab** action. The browser
status response contains only the intent ID, status, and expiry, never either
desktop credential or account identity.

This supports the same account methods as AX over time:

- email/password;
- GitHub;
- Google;
- passkey where the browser/platform supports it.

The human desktop credential is:

- scoped to human/account-management APIs;
- revocable independently;
- stored only in OS secure storage;
- never sent to the CLI Worker Engine or provider CLI;
- not used as the Workspace execution credential.

### 2. Runtime identity remains separate

Human authentication does not replace the Workspace runtime credential.

After the human signs in, the desktop may register/recover its installation and receive or rotate a runtime credential.

The runtime credential remains the only credential accepted for machine execution APIs:

- Workspace Gateway;
- HTTP runtime fallback;
- inventory synchronization;
- assignment receive/acknowledge;
- progress/result;
- heartbeat;
- runtime facts.

The two credential planes are therefore:

~~~text
Human desktop session
  -> "who is managing this Workspace?"

Workspace runtime credential
  -> "which registered Workspace installation is executing?"
~~~

Human session expiry must not automatically terminate already-authorized work. Explicit user sign-out/disconnect may revoke or stop the runtime according to product policy.

### 3. Desktop owns Workspace creation/recovery

The normal product flow becomes desktop-first.

After sign-in:

~~~text
Syntila Workspace
-> discovers persistent installation identity
-> proposes friendly computer name
-> calls authenticated register/recover API
-> Cloud verifies User + installation ownership
-> creates or restores the user's Workspace/runtime
-> returns runtime credential
-> desktop starts runtime transport
~~~

Normal users register or recover a Workspace from Syntila Workspace through
the authenticated `POST /api/workspace-runtime/register` route. AX does not
create Workspace placeholders or manage local machine registration.

Cloud must enforce:

- one active Workspace owner per installation identity;
- same-user recovery is idempotent;
- a different user cannot silently claim an installation already owned by another user;
- transfer requires an explicit disconnect/reset/release flow;
- changing display name or hostname does not change installation identity.

### 4. AX Workspaces becomes operationally read-only

The Syntila Workspaces page remains useful for:

- Workspace list;
- connected/offline state;
- transport type;
- hostname/platform/version;
- last seen;
- synchronized Workers;
- readiness/attention;
- Space-facing execution availability.

Normal AX Workspace UI does not:

- register or disconnect a local machine Workspace;
- rename the local machine Workspace;
- add/remove/authenticate Workers;
- change local Worker permissions;
- repair local credentials.

Remote operational controls such as Worker scheduling enable/disable/drain are
not part of the normal Workspace UI. Any administrative Cloud operation has
its own current authorization contract and does not expose local Worker
configuration.

Space membership, Space Workspace Grants, and Thread policy remain Cloud/AX concerns because they authorize collaborative use; they are not local machine configuration.

### 5. Runtime protocol is transport-independent

The logical Workspace protocol is independent of WebSocket.

Canonical logical messages remain concepts such as:

- workspace.hello;
- workspace.sync;
- worker inventory;
- heartbeat;
- assignment dispatch;
- assignment progress/result;
- assignment cancel;
- Workspace lifecycle and synchronization messages.

The preferred transport is WebSocket/WSS.

If WebSocket cannot become Ready after bounded connection attempts, Workspace falls back to HTTPS long-poll transport.

### 6. HTTPS long-poll fallback

Fallback uses the runtime credential, not the human desktop session.

Conceptually:

~~~text
POST /api/workspace-runtime/session
  -> establish/reconcile runtime session

GET /api/workspace-runtime/poll?cursor=...
  -> bounded long-poll for Cloud -> Workspace commands/events

POST /api/workspace-runtime/events
  -> Workspace -> Cloud hello/sync/inventory/progress/result/heartbeat/acks
~~~

The exact route shape may be implemented behind the existing Workspace Gateway Durable Object. The Durable Object should remain the authoritative live runtime coordinator regardless of transport.

Requirements:

- long-poll requests use finite server timeouts and reconnect immediately;
- cursor/event identity makes delivery idempotent;
- duplicate requests/messages are safe;
- assignment dispatch has explicit acknowledgement;
- cancellation remains timely;
- runtime heartbeat/liveness has a defined TTL;
- transition between WebSocket and fallback does not create a second runtime identity;
- the scheduler sees one logical Workspace session.

### 7. Transport state is visible

The desktop Workspace page displays the active connection mode:

~~~text
Connected · WebSocket
Connected · HTTP fallback
Reconnecting…
Offline
Authentication required
~~~

HTTP fallback is functional but may be presented as degraded:

> Connected using HTTPS fallback. Realtime WebSocket is unavailable.

Diagnostics shows the last WebSocket failure and fallback session state.

AX may display a read-only transport observation:

~~~text
Connected
WebSocket
~~~

or:

~~~text
Connected
HTTPS fallback
~~~

but does not control it.

### 8. Recovery uses the desktop human session

Recovery becomes:

~~~text
human session valid?
  yes -> inspect installation/Workspace via HTTPS API
       -> recover/rotate runtime credential if authorized
       -> reconnect using preferred transport
  no  -> sign in
       -> continue recovery
~~~

If Cloud reports that the installation belongs to another user, the desktop presents an explicit ownership conflict. It does not reset automatically.

For a pre-v8 migration inconsistency, Workspace can request explicit
ownership reconciliation after browser approval has created a fresh desktop
human session. Cloud may restore a missing v8 installation row only from the
exact local Workspace/runtime registration when the current Workspace owner
matches that session, the persistent installation ID matches, no competing
active binding exists, and Cloud has no Release record for the installation.
Cloud records the repair in the Workspace audit log. It never uses email
matching or transfers an active installation from another account; that owner
must first release it.

### 9. Security boundary

Human desktop authentication does not allow provider secrets into Cloud.

Provider CLI sign-in, local Worker permissions and state, Work Root, and local
files remain on Workspace or in the provider CLI's own local configuration.

Cloud receives only the safe projections defined by the current Workspace
runtime contract.

The desktop human session and runtime credential are distinct secrets and must be redacted independently from logs/diagnostics.

## Consequences

### Positive

- Workspace recovery is self-contained in the desktop app;
- users do not need two applications to repair one machine;
- Cloud API diagnostics remain available even when WebSocket fails;
- WebSocket becomes an optimization/preferred realtime transport rather than a single point of failure;
- runtime machine identity remains separate from human identity;
- AX Workspaces becomes simpler and safer;
- the product can survive restrictive proxies/networks with HTTPS fallback.

### Tradeoffs

- desktop authentication requires a secure native browser-assisted flow;
- Cloud needs a desktop human-session credential lifecycle;
- long-poll requires delivery cursor/idempotency semantics;
- scheduler liveness must understand both transports;
- release upgrade must preserve the local Work Root and stable installation
  identity according to the Workspace lifecycle contract;
- AX remote control behavior must be deliberately reduced rather than accidentally duplicated.

## Non-goals

This ADR does not:

- make one Workspace multi-user;
- move provider credentials to Cloud;
- use the human session for assignment execution;
- replace WebSocket with polling;
- add organization-owned shared-machine semantics;
- require a dedicated Gateway domain.

## Desktop lifecycle refinement

ADR-014 refines the product lifecycle introduced here without changing the
credential or transport separation. In particular:

- successful human sign-in establishes management identity only;
- **Connect Workspace** explicitly registers/recovers and starts runtime participation;
- signed-out users do not see Workspace/Workers management surfaces;
- connected runtimes auto-reconnect after OS login/restart using the runtime
  credential without requiring interactive human sign-in;
- management UI may be locally locked while runtime execution continues;
- explicit Disconnect, Release ownership, Sign out, Lock, and Reset have
  different semantics;
- account switching is forbidden while an installation remains owned/connected
  to another user.

See [ADR-014](ADR-014-workspace-desktop-lifecycle.md) and the
[desktop lifecycle release validation](../operations/WORKSPACE_DESKTOP_LIFECYCLE_RELEASE_VALIDATION.md).

## Acceptance

The architecture is accepted when tests prove:

1. desktop user can authenticate using the same Syntila account identity;
2. a fresh installation can register its Workspace directly from Syntila Workspace;
3. same user can recover an existing installation/runtime;
4. another user cannot claim an installation already owned by someone else;
5. WebSocket remains the preferred transport;
6. HTTP fallback can complete hello/sync/inventory and receive/complete an assignment;
7. switching transports preserves one Workspace/runtime identity;
8. AX displays Workspace and Worker state without local recovery controls;
9. provider secrets remain local;
10. a broken WebSocket never prevents the signed-in desktop from querying its Cloud Workspace state.

## Shared contract baseline

Phase 0 freezes the Cloud/desktop payloads and validators in
[`syntila.desktop-auth-transport` 1.0](../protocol/DESKTOP_AUTH_TRANSPORT_CONTRACTS.md),
exported by `@syntila/workspace-runtime-protocol`. Desktop human sessions and
Workspace runtime credentials are separate types and security boundaries;
provider CLI sign-in is outside the shared protocol. Cloud and desktop implementation
phases must consume these contracts rather than defining parallel shapes.
