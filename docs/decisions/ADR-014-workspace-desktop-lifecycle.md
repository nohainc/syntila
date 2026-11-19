# ADR-014: Syntila Workspace Desktop Lifecycle, Locking, and Background Runtime

> **Superseded in part (2026-10).** This record describes the earlier Flutter `Workspace.app`/`SMAppService` design. The Flutter GUI was removed; Workspace is now a headless Dart service plus the `syntila` CLI, configured by `workspace.nano`. The current contract is [WORKSPACE_ARCHITECTURE.md](../architecture/WORKSPACE_ARCHITECTURE.md). Read this document as history.

> **Also superseded in part (proposed, 2026-11-19).** The per-Workspace runtime connection and registration model is replaced by one connection per Worker: see [ADR-034](ADR-034-standalone-worker-agent-and-session-fencing.md) (session fencing, standalone Agent) and [ADR-038](ADR-038-unified-realtime-transport.md) (unified transport).

**Status:** Accepted for implementation  
**Date:** 2026-09-27  
**Builds on:** ADR-012, ADR-013  
**Refines:** ADR-013 desktop onboarding and recovery lifecycle

## Context

ADR-013 introduced two separate Cloud identities in Syntila Workspace:

- a human desktop management session;
- a Workspace runtime credential.

The first implementation correctly added browser-assisted desktop authentication,
authenticated Workspace registration/recovery, WebSocket primary transport, and
HTTPS fallback.

However, the initial implementation still couples several product states too
closely:

~~~text
Sign in
-> immediately register/recover Workspace
-> immediately issue runtime credential
-> immediately start runtime
~~~

The desktop also renders most Workspace/Worker controls even when no valid human
management session exists.

That creates several UX and security problems:

- authentication and runtime participation are difficult to reason about;
- signed-out users can still see controls that should require management access;
- changing accounts is ambiguous while the installation is connected;
- normal computer restart behavior is not explicitly defined;
- the background runtime should reconnect automatically without requiring a
  fresh interactive login;
- a local user may want the runtime to keep working while preventing someone at
  the unlocked computer from changing Worker or Workspace settings;
- "sign out", "disconnect", "lock", and "reset" currently risk being conflated.

Syntila Workspace is a background execution runtime and a local management
application. Those responsibilities need an explicit lifecycle.

## Decision

### 1. Use separate lifecycle dimensions

The application tracks at least these independent concepts:

1. **Human management authentication**
2. **Workspace runtime participation**
3. **Local management UI lock state**
4. **Runtime transport state**

Do not collapse them into one "connected" boolean.

The primary product states are:

~~~text
SIGNED OUT
  -> human management session absent

SIGNED IN / DISCONNECTED
  -> valid human management session
  -> installation not participating as an active Workspace runtime

CONNECTED / UNLOCKED
  -> Workspace runtime is registered/authorized
  -> runtime credential available
  -> management UI unlocked

CONNECTED / LOCKED
  -> runtime continues
  -> management UI hidden/protected locally

CONNECTED / REAUTH REQUIRED
  -> runtime may continue
  -> human management session expired/revoked
  -> management actions require same-owner reauthentication
~~~

Transport state is orthogonal:

~~~text
websocket
http_long_poll
reconnecting
offline
~~~

### 2. Sign in does not automatically connect the Workspace

Human sign-in answers:

> Which Syntila user is allowed to manage this local installation?

Successful sign-in establishes only the desktop human management session.

After sign-in, a disconnected installation shows an explicit action:

~~~text
Signed in as Vitalii Noha

This computer is not connected as a Workspace.

[ Connect Workspace ]
~~~

**Connect Workspace** performs registration/recovery, obtains the runtime
credential, and starts the runtime transport.

This separation makes onboarding and recovery explicit and reversible.

### 3. Signed-out UI is a separate shell

When there is no valid human management session, the desktop does not show the
normal Workspace or Workers tabs.

Signed-out UI exposes only low-risk application functions:

- Sign in;
- app version/About;
- basic diagnostic/log access where safe;
- Quit.

It does not expose:

- Worker list/configuration;
- provider/auth state;
- Work Root mutation;
- disconnect/reset;
- runtime credential recovery;
- Worker, Engine, and Profile runtime diagnostics;
- local permission management.

The implementation should use a dedicated signed-out shell rather than rendering
the normal dashboard with selectively disabled controls.

### 4. Workers remain visible while Workspace is disconnected

Normal product onboarding becomes:

~~~text
Install
-> Sign in
-> Add/configure Workers from local/catalog state
-> Connect Workspace when runtime participation is needed
~~~

When signed in but disconnected, the app shows Workspace and Workers tabs.
Workspace contains the connection/setup surface. Workers loads the last cached
logical catalog and local Worker registry without restoring runtime identity or
connecting Cloud. Worker details and local configuration remain available;
Signed-in users may refresh the stable Worker catalog while disconnected
through the human product session. Profile synchronization, inventory upload,
and runtime operations still wait until reconnection because they require a
Workspace runtime identity.

The Workspace tab places **Sign out** in Account and **Disconnect Workspace**
in the Connection section. Worker details live in the Workers tab, so the
Workspace tab does not repeat a Worker summary. Version and update information
belong in the application menu/About surface rather than a separate Application
section in the Workspace tab.

This is a product simplification, not a limitation of the local Worker model.

### 5. One connected installation is bound to one Syntila owner

While a Workspace installation is connected/owned by User A, another user
cannot become its active management owner.

A browser-auth attempt that resolves to User B must be rejected for management
of that connected installation.

Changing account requires an explicit ownership transition.

The normal sequence is:

~~~text
Disconnect Workspace
-> optionally Release Workspace from account
-> Sign out User A
-> Sign in User B
-> Connect Workspace
~~~

There is no silent account switch.

### 6. Disconnect and release are different

**Disconnect Workspace** means:

- stop accepting new assignments;
- drain active work according to runtime policy;
- close logical runtime session;
- revoke/delete the active runtime credential;
- mark runtime participation disconnected;
- preserve installation identity;
- preserve owner binding;
- preserve local Worker slots, provider CLI sign-in state, Profile cache, and
  Work Root;
- keep the human management session signed in.

The same owner can later press **Connect Workspace** and recover a fresh runtime
credential.

Disconnect does **not** make the installation available to a different account.

A separate advanced operation, conceptually **Remove Workspace from account** or
**Release ownership**, is required before another Syntila user can claim the
installation.

That operation must require strong confirmation and local reauthentication.

### 7. Sign out while connected is not a normal operation

If the user explicitly chooses Sign out while the Workspace is connected, the
app does not silently leave a running runtime under an apparently signed-out
management UI.

Offer:

~~~text
This Workspace is connected.

[ Cancel ]
[ Disconnect and sign out ]
~~~

Human session expiry is different from an explicit Sign out. Expiry does not
stop the runtime.

### 8. Runtime survives human-session expiry

The Workspace runtime credential remains independent from the human management
session.

If the human session expires or is revoked while the runtime credential remains
valid:

- active work continues;
- new authorized work may continue;
- WebSocket/HTTP fallback continues;
- the app may run in the background;
- opening the management UI requires reauthentication.

Reauthentication must resolve to the existing owner. A different user receives
an ownership conflict and cannot access management controls.

### 9. Connected Workspace reconnects automatically after reboot/login

A connected Workspace is intended to behave like a local execution service.

After the user connects the Workspace, the app should offer/enable **Start
Syntila Workspace at login**.

On a normal OS-user login/restart:

~~~text
Syntila Workspace starts in background
-> load installation identity
-> load runtime credential from secure storage
-> start runtime
-> try WebSocket
-> use HTTPS fallback if required
-> publish menu-bar status
~~~

No interactive human login is required for runtime reconnection while the
runtime credential remains valid.

The main window should not automatically open during background startup.

On macOS, use the supported Service Management login-item mechanism
(`SMAppService`) rather than legacy launch techniques.

### 10. Desired runtime participation is explicit local state

Automatic startup must distinguish:

- previously connected and expected to reconnect;
- deliberately disconnected;
- runtime credential temporarily unavailable/revoked.

Persist a small non-secret local lifecycle preference such as:

~~~text
desiredRuntimeState = connected | disconnected
launchAtLogin = true | false
~~~

Do not infer user intent solely from whether a credential file/key happens to
exist.

### 11. Add a local management lock

A connected Workspace may continue working while its management UI is locked.

Locking:

- does not stop the runtime;
- does not disconnect Cloud;
- does not pause Workers;
- hides Workspace/Worker management data;
- blocks sensitive actions;
- shows only minimal runtime status.

Locked UI:

~~~text
Syntila Workspace

Workspace is locked.
Runtime is still connected.

[ Unlock ]
~~~

Use platform-native local authentication where available. On macOS use
LocalAuthentication/Touch ID/device password.

Do not create a separate Syntila PIN/password.

### 12. Lock is local protection, not the primary machine security boundary

The operating-system account, Keychain, filesystem permissions, and device
security remain the real local security boundary.

App lock protects against casual/unauthorized use of the management UI on an
already-unlocked machine.

The product should not claim that Workspace Lock protects against an attacker
who controls the OS account.

### 13. Sensitive actions require local reauthentication

Even when the UI is unlocked, selected high-impact actions should require a
fresh local-auth challenge or recent-unlock window:

- Disconnect Workspace;
- Release/remove Workspace ownership;
- Reset local Workspace;
- remove a Worker;
- replace Worker/provider credentials;
- change local execution permissions;
- destructive Work Root changes;
- account ownership transition.

Low-risk read operations do not require repeated prompts.

### 14. Recommended lock behavior

Initial product defaults:

- manual **Lock Workspace** available from app/menu-bar;
- auto-lock management UI when the OS screen/session locks;
- optional idle auto-lock preference;
- do not stop the runtime when locking;
- do not require unlocking merely because the main window was closed;
- when reopening after a protected state, require native local auth.

Avoid aggressive lock prompts that make the background app annoying to use.

### 15. Menu-bar/background behavior

When the Workspace is connected, the menu-bar item is the primary background
runtime surface.

It may expose safe operational information/actions:

~~~text
Syntila Workspace
Connected · WebSocket
0 assignments

Open Syntila Workspace
Lock Workspace
Pause new work
Diagnostics
Quit
~~~

Sensitive actions must route through the full app and local-auth checks where
required.

### 16. Authentication flow remains browser-assisted

The browser-assisted, explicit approval flow remains the baseline. The desktop
does not display or ask the user to enter a comparison code.

It has desirable properties:

- provider/password credentials remain in the system browser;
- Better Auth remains the single human identity system;
- the desktop never receives the browser HttpOnly cookie;
- the user explicitly approves the desktop session.

A future native-app OAuth/OIDC flow using external browser redirect + PKCE may
replace this flow, but that is not required for this lifecycle change.

### 17. Connection-mode UI remains explicit

When connected, the Workspace surface shows the active runtime transport:

~~~text
Connected · WebSocket
~~~

or:

~~~text
Connected · HTTPS fallback
WebSocket is unavailable. Work can continue.
~~~

Locking and human reauthentication state must not be confused with transport
health.

## State transitions

### First installation

~~~text
SIGNED OUT
-> Sign in
SIGNED IN / DISCONNECTED
-> Connect Workspace
CONNECTED / UNLOCKED
-> Add Workers
~~~

### Normal restart

~~~text
OS user logs in
-> app starts in background
-> desiredRuntimeState == connected
-> runtime credential loaded
-> runtime reconnects
-> management UI remains closed/locked as configured
~~~

### Manual disconnect

~~~text
CONNECTED
-> Disconnect Workspace
-> drain
-> revoke runtime credential
SIGNED IN / DISCONNECTED
~~~

### Human session expiry

~~~text
CONNECTED
-> human session expires
CONNECTED / REAUTH REQUIRED
-> runtime continues
-> same owner authenticates
CONNECTED / UNLOCKED
~~~

### Account change

~~~text
CONNECTED
-> Disconnect
SIGNED IN / DISCONNECTED
-> Release ownership (explicit)
-> Sign out
SIGNED OUT
-> Sign in as another User
-> Connect Workspace
~~~

### Lock

~~~text
CONNECTED / UNLOCKED
-> Lock
CONNECTED / LOCKED
-> Touch ID / device authentication
CONNECTED / UNLOCKED
~~~

## Consequences

### Positive

- authentication and runtime participation become understandable;
- signed-out users cannot access Worker/Workspace controls;
- reboot behavior matches a real background execution service;
- runtime availability does not depend on frequent human login;
- accidental account switching is prevented;
- local management controls can be protected without stopping work;
- Connect/Disconnect become explicit product actions;
- security boundaries remain clear.

### Tradeoffs

- more explicit lifecycle state must be modeled/tested;
- native startup-at-login integration is platform-specific;
- native local-auth integration is platform-specific;
- Cloud needs explicit disconnect/release semantics;
- account/session and runtime/session recovery must be tested independently;
- release upgrades preserve the Work Root and stable installation identity as
  specified by the Workspace lifecycle contract.

## Non-goals

This ADR does not:

- make a Workspace multi-user;
- require human login on every restart;
- use the human session as a runtime credential;
- stop work when the UI locks;
- allow arbitrary account switching;
- replace WebSocket/HTTPS fallback transport design;
- make app lock a substitute for OS security.

## Acceptance

The lifecycle is complete when:

1. signed-out app shows no Workspace/Workers management tabs;
2. signing in alone does not register/connect the Workspace;
3. Connect Workspace explicitly registers/recovers and starts the runtime;
4. connected Workspace automatically reconnects after OS login/restart without
   interactive sign-in;
5. explicit Disconnect stops runtime participation but preserves local Workers;
6. another account cannot manage/claim a connected installation;
7. human-session expiry does not terminate runtime work;
8. same-owner reauthentication restores management access;
9. app Lock hides management UI but leaves runtime connected;
10. Touch ID/device authentication unlocks the UI on macOS;
11. sensitive actions require local reauthentication;
12. launch-at-login can be enabled/disabled and uses supported native APIs;
13. WebSocket/HTTPS fallback status remains independently visible;
14. explicit Release ownership is required before account transfer;
15. release upgrade preserves local Work Root data and stable installation
    identity without relying on a Cloud schema compatibility migration.
