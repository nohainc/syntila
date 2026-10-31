# Workspace architecture

This is the canonical description of the Workspace application and runtime.
New code should follow this document.

## Ownership

```text
workspace (headless Dart service)
    Cloud transport, assignments, state, workers, sessions, logs,
    diagnostics, Work Root access; authoritative on every platform
                 ▲
                 │ authenticated local IPC (status and operations)
                 │ workspace.nano (restart-applied desired configuration)
                 │
syntila (management CLI)
    account/setup flows, configuration editing, host service controls

workspace → Worker subsystem → syntila-agent → provider CLI
```

The CLI (and any future management client) must not create a Cloud connection,
run readiness checks, spawn the Worker Engine, or execute an assignment. The
Service is authoritative; clients only send IPC requests and display results. The Worker Engine is an execution primitive;
it receives a profile, command, environment policy, working directory, input,
execution options, and cancellation, and returns output. It has no Cloud,
Space, Thread, Workflow, D1, or UI dependency.

The service is the unified Dart executable `syntila` (run as
`syntila run`) and keeps the
generic Engine as a separately supervised child (`syntila-agent`). The service
holds the per-installation lock, owns process cleanup, and is the only runtime
owner. Closing a terminal or the CLI closes its IPC client and does not stop execution.
At startup the compiled Dart processes set their macOS diagnostic names to
those product names. This affects only Activity Monitor/process diagnostics;
it does not change the executable, IPC protocol, Workspace credentials, or
Cloud authentication.

Execution failures use the versioned, privacy-safe diagnostic event contract in
[`DIAGNOSTIC_EVENTS_V1.md`](../specifications/DIAGNOSTIC_EVENTS_V1.md). The
service and Engine keep bounded correlated records locally, while Cloud records
the corresponding admission, transport, and result/error events. Diagnostic
exports report completeness and omit prompts, provider output, credentials, and
local filesystem paths.

## Lifecycle and state

Host registration and process state are separate from Cloud state:

```text
Service: registered → stopped | starting → running | failed
Cloud:   disconnected | connecting | connected | reconnecting
```

`service stop` drains/cancels according to the bounded service policy,
disconnects Cloud, terminates child Engines, and leaves host registration in
place. `service uninstall` is a separate destructive host operation. At startup
the service reads `workspace.nano` exactly once and connects only when
`cloud.connect_on_start` is true. Runtime operations (`connection.*`,
`worker.*`, assignment controls, logs, and diagnostics) cross authenticated
versioned IPC. Configuration is not mutated or reloaded through IPC. Host operations cannot be
implemented through IPC because they must start or stop a process that may not
exist.

Opening the management app passively attaches to local IPC without starting the
service. A missing IPC key or socket means the service is unavailable and is not
shown as an access error. Explicit startup still waits for authenticated IPC
readiness and reports timeout diagnostics if the endpoint never becomes ready;
authentication and other IPC failures remain visible.

The service persists enough assignment and process information to reconcile a
restart without blindly rerunning uncertain work. Cloud session history is
audited in D1, while live transport state, queues, cursors, and acknowledgments
belong to the Cloud gateway's live transport layer.

A terminal outcome is written to the local journal before it is sent. If the send
fails while the connection stays up (timeout, Cloud restarting), the service
re-sends every unacknowledged outcome on a timer (20 s, doubling up to 16x)
until Cloud's terminal `assignment.ack` marks it reconciled. A reconnect cancels
the timer and the connect-time sync takes over, so the two paths never overlap.

Workspace release checks are also service-owned. A client sends an
`updates.check` IPC request (the CLI no longer has a command for it); the service performs the authenticated release
lookup without disconnecting or reconnecting Cloud. If update support is not
configured, the client reports that state instead of using a connection retry as
a fallback.

Human management authentication is a separate concern from runtime
authentication. `syntila login` (Cloud email and password) stores a
short-lived `DesktopHumanSession`; `syntila register` uses it for
account ownership checks and registration (a Workspace that Cloud has released
is claimed as a new one); `syntila logout` deletes the stored session
locally and leaves the registration and runtime credential in place. The Workspace Service uses the registered
Workspace runtime identity and secure runtime credential for Cloud reconnect and
execution. Losing or expiring the human session does not disconnect Cloud, stop
or unregister the service, release Workspace ownership, remove the runtime
credential, or disable Workers. Explicit `disconnect`, `service stop`, ownership
release, and reset actions retain their own separate lifecycle semantics.

## Worker subsystem

A downloaded Profile remains staged when its activation probe fails. The
management snapshot retains the probe issue (for example
`provider_tool_unavailable`) and reports “Profile downloaded; activation blocked”
instead of a download failure. Readiness preserves that cause when no active
Profile exists. CLI detection without probe evidence is displayed as “Not checked”.
Cloud registration does not establish local CLI or Profile readiness.

Workspace verification retains the CLI Engine probe checks: the version
command, model discovery when declared, each Profile-defined passive command and
config check, and the usage/account command for a live test. Passive availability
checks do not run the usage command. A CLI discovery/start failure appears as
`provider_tool`; successful discovery is implicit in the version result and is
not an additional synthetic success. Model discovery can warn when a cached
catalog is retained. These probes never call a model and do not repeat Profile
Lab's schema-validation or event-replay authoring tests. Status icons accompany
each returned check and the last-check timestamps; an unavailable saved result
is marked unknown rather than inferred as successful. Detailed evidence remains
visible without a separate verification heading or overall-result row. The service
retains every probe and its evidence. Workspace name, Work Root and parallel
capacity are configured in `workspace.nano` and apply when the service restarts.

Per-Worker updates use `workers.refreshWorker` with `workerTypeId`. An older
running service that rejects the command must be replaced with the current
binary and restarted after active work finishes. The client reports this recovery;
it does not fall back to refreshing every Worker or restart active work.


`WorkspaceWorkerSubsystem` is the service composition boundary. It owns the
local Worker registry, catalog/profile resolution, Profile/readiness checks,
Engine supervision, and the small API used by runtime and IPC:

```text
listWorkers · enableWorker · disableWorker · removeWorker · testWorker
resolveWorker · refresh · execute · cancel · recoverOrphanedProcesses · shutdown
```

Worker lifecycle (`absent`, `installing`, `ready`, `degraded`, `failed`,
`removing`) is separate from activation (`enabled` or `disabled`). A Worker
Engine process is started on demand for a probe or assignment and is always
tracked by the one process supervisor. No client polling loop or idle Engine is
required.

### Worker management and verification

A Workspace starts with no Workers. The Workers list shows only Workers the
user added; the rest of the Cloud catalog is display metadata offered by
**Add Worker**, which runs `workers.configureWorker` for the chosen type.
Profiles are downloaded, verified and probed only for added Workers, so the
Service does not test catalog entries nobody uses.

`workers.removeWorker` (`workerId`) removes a Worker without keeping its
settings. The Service disables it first, so it takes no new assignments and
Cloud stops scheduling it. With nothing running or queued for it, the registry
record and its runtime Engine state directory are deleted at once (`state:
removed`). Otherwise the reply is `state: removing`, the Worker ID appears in
`workerCatalog.removingWorkerIds`, and a Service timer finishes removal when
its work ends. While removing, enable, disable, test, full-access and re-adding
that type are rejected with `worker_removing`. Work Root, Space directories,
provider sessions and Profiles are untouched. A service stop during a pending
removal leaves the Worker disabled; removing it again completes the removal.
Re-adding a type creates a fresh record with a new Worker ID. Cloud drops the
removed Worker from inventory on the next full snapshot.

The manager has separate Workspace and Workers tabs. Workspace contains machine
settings and execution capacity. Workers uses a scrollable list of added
Workers on the left and an independently scrollable detail/action panel on the right. Switching
tabs preserves the selected Worker and in-progress verification. Selection is keyed
by logical Worker type and survives inventory refreshes. Availability evidence,
activation, permissions, and model discovery remain separate. The detail panel
shows the actual issue code, safe diagnostic details and a recovery action;
it does not substitute a generic “Needs attention” badge for the failure.

The Service readiness monitor publishes transient check progress through the
existing authenticated `worker.catalogChanged` and snapshot path. The optional
`workerCatalog.checks` map is keyed by Worker type. Each entry has
`schemaVersion: 1`, `mode` (`passive` or `live`), `phase` (`profile`, `probe`,
`save`), `outcome` (`running`, `passed`, `failed`), UTC `startedAt`, optional
`completedAt`, and optional `issueCode`. These are actual execution boundaries:
Profile resolution, the combined Profile-defined CLI probe, and recording a
successful verification. Failed check evidence is still saved in the last-test
record without marking that final success step as passed. No provider-specific
sub-tests or synthetic percentages are inferred by the manager. Failure retains its failing stage; later steps are not
shown as passed. Testing preserves activation and may consume provider quota.

Progress is Service memory, available to newly attached IPC clients, and is never
restored from a client's display cache. Persisted last passive/live timestamps,
live pass/fail and safe failure details remain visible after a test ends or the
service stops. A stopped service is presented as stale evidence, not live
availability. Missing progress fields from an older service are supported;
existing IPC commands and Cloud/Engine protocols are unchanged.

## Local IPC

The manager protocol is versioned, authenticated with a per-installation
capability key, and transported over a private Unix-domain socket on macOS.
The service sends an initial status snapshot and then event updates. Clients
must negotiate the protocol version, authenticate before commands, bound frame
sizes, and reconnect with backoff. The socket is a management boundary, not a
public localhost API.

## Filesystem ownership

Syntila-owned runtime state is under:

```text
~/Library/Application Support/Syntila/Workspace/
    configuration, registry, profiles, engines, sessions, assignments,
    logs, cache, runtime
```

User-owned files are under the configured Work Root (default
`~/Documents/Syntila`) and Space directories below it. Every Space owner,
including the Workspace owner, has one folder directly under Work Root, named
once as the first 8 characters of their user ID (longer on collision) and
recorded in the private registry; it never changes, so a user rename moves
nothing and no personal name appears in paths. A Space lives at `<owner-folder>/<Space name>`; a
duplicate name inside one owner folder gets a ` (2)` suffix. The folder follows
the Space owner (Cloud sends `spaceOwnerUserId` with each assignment), never the member who runs the Work. Paths already in the registry
stay authoritative. Folders organize files; they are not an isolation boundary.
Folders outside Work Root are reachable only through the owner-managed
Allowed Folders list (see below). A Worker receives the
resolved Space directory, never Application Support as its normal working
directory. Resetting runtime state, clearing logs/cache, deleting a Thread, or
removing a Workspace must not delete user work. Space directory identity is
stable and tied to `spaceId`; display-name changes do not silently move files.

Stateful assignments sharing a Space directory are serialized with one
Space-wide process lock. Cloud mutation leases and their monotonic fencing
counters (`threads.lease_fence_counter`, never reset by clearing Work
history) belong to individual Threads. Workspace therefore compares tokens
only within the same `(spaceId, threadId)`, persisting versioned records at
`space-fences/<spaceId>/<threadId>.json` in application state. A new Thread's
token `1` must not be rejected because another Thread reached token `23`.
Lower tokens and equal tokens with a different lease ID remain rejected for
the same Thread, including after Service restart.

Legacy `space-fences/<spaceId>.json` files remain preserved as historical
evidence. They contain no Thread identity and cannot safely supply a
Thread-scoped ordering; they are not copied into an arbitrary Thread's record.
The first admitted assignment establishes the scoped record, while the
Space-wide lock continues to prevent simultaneous filesystem mutation. Cloud
lease issuance and validation remain authoritative. No installation, Workspace,
registry, credential, Work Root, Profile, Engine, or session identity changes.

## Allowed Folders

Browsers cannot browse or verify local folders, and whether a provider CLI can
write to a path depends on the host account the service runs as. The
Workspace owner therefore maintains an explicit Allowed Folders list with
`syntila folders`; Spaces can only choose from that list.

- The list is private service state at
  `<Application Support>/Registry/allowed-folders.json` (schema version 1).
  Only the authenticated local Manager IPC changes it: `folders.list`,
  `folders.add`, `folders.rename`, `folders.remove`, `folders.recheck`.
  Cloud assignment payloads cannot add or change entries.
- Adding a folder canonicalizes the path (symlinks resolved) and rejects the
  filesystem root, the home folder or any folder containing it, Work Root and
  application data (or anything overlapping them), duplicates, and folders
  overlapping an existing entry. At most 32 folders are allowed.
- Each add and recheck runs a real access probe (list, then create and delete
  a temporary file) and records `available`, `read_only`, `denied`, or
  `missing`. A failing folder is reported, never silently dropped.
- Removing or renaming an entry never touches the folder or its files.
- Only `id`, `displayName`, `status`, and `checkedAt` may leave the machine
  (`AllowedFolder.toCloudSummary`). Absolute paths stay local; execution maps
  folder IDs back to paths and re-checks access before launch.
- The feature is owner-only: Cloud must only offer the list for Spaces whose
  Workspace belongs to the requesting user, and switching a Space to another
  Workspace detaches its folders (files untouched).

`syntila folders [list]`, `folders add PATH [--name NAME]` and
`folders remove ID` call the same IPC commands. Removing a folder never touches
its files.

The service publishes the path-free summaries as an optional
`allowedFolders` array in each full `worker.inventory` snapshot
(`WorkspaceAllowedFolderSchema`, at most 32 entries). Because Cloud validates
inventory strictly, the service includes the field only after Cloud announces
`workspace.allowed_folders.v1` in `hello.ack` `cloudCapabilities`. An
unreadable local list omits the field so Cloud keeps its last known list.
Folder changes made over IPC republish the inventory immediately.

Cloud announces `workspace.allowed_folders.v1`, stores the list in
`workspace_allowed_folders` (migration 0085), and records Space attachments
in `space_additional_folders`. `GET/PUT /api/spaces/:spaceId/additional-folders`
serves only the owner of both the Space and its effective Workspace; other
callers get `eligible: false` and no folders. A folder dropped from the
published list, or a Space switching Workspace, detaches the folder in Cloud
only. Omitted or malformed lists keep the stored folders.

The AX web app shows an "Additional folders" picker under the Space's
Workspace selector for eligible owners. Missing or inaccessible folders can
be detached but not newly attached. The Change Workspace dialog states how
many folders will be detached and that local files are untouched.

At dispatch, Cloud adds the attached folder IDs to the assignment input as
`additionalFolderIds`, repeating the Space-owner equals Workspace-owner check.
Only IDs travel; payloads naming `additionalDirectories` are rejected. Before
launch the service maps each ID to its local path and probes it again. A
folder that is no longer allowed, missing, or denied fails the assignment
with a message naming the folder, and a Worker whose Profile cannot pass
folders fails with "This Worker cannot use additional folders yet". Folders
are never dropped silently. The Engine receives the verified paths in
`execute.request` `additionalDirectories` and expands the Profile's
`{"forEachAdditionalDirectory": [...]}` argument slot once per folder (see
`docs/specifications/TOOL_PROFILE_V1.md`).

Concurrency follows the Space directory rule: Threads already run in
parallel inside one Space folder and the user decides what runs together, so
attached folders are not locked. Several Spaces, or several Threads, may use
the same folder at the same time; the Space-wide lock still covers only the
short Space preparation.

All Profile Lab drafts (`apps/profile_lab/assets/profiles/*.json`) place the
`forEachAdditionalDirectory` slot so each CLI receives a repeatable
`--add-dir <path>` (Codex, Claude Code, GitHub Copilot CLI, Antigravity, and
Grok Build). For Codex the slot precedes the `resume` subcommand because
`codex exec resume` does not accept `--add-dir`. A Worker only uses folders
after its updated Profile is published through Profile Lab.

## Authentication and security

The service reads the existing Workspace registration and secure runtime
credential; it does not create a replacement Cloud identity. Cloud HTTP and
WebSocket paths use the same `WorkspaceRuntimeAuthenticator`. The service
never places tokens in application tables or forwards Cloud credentials to a
Worker Engine. IPC authorization, installation ownership, execution admission,
and Work Root boundaries are enforced by the service.

## Restart-applied configuration

`<state>/workspace.nano` is the only non-secret behavior configuration. It is
strict, versioned Nano Markup parsed with `nohainc/nanomarkup.dart`; unknown
behavior keys, invalid scalar values, relative paths, credentialed URLs, and
missing required folders fail validation. The service reads it once at process
start. The CLI and desktop app edit it atomically and use the host manager to
restart the process. The service exposes active values read-only; it accepts no
settings mutation or live reload command.

```text
..
    version 1
    service..
        enabled true
    cloud..
        url https://syntila.app
        connect_on_start true
    workspace..
        name My Workspace
    execution..
        parallel_slots 5
    folders..
        root /home/me
        syntila /home/me/.local/share/syntila/workspace
        state /home/me/.local/state/syntila/workspace
        work /home/me/Documents/Syntila
        profiles /home/me/.local/share/syntila/workspace/Profiles
        engines /home/me/.local/share/syntila/workspace/Engines
        logs /home/me/.local/state/syntila/workspace/logs
        cache /home/me/.local/state/syntila/workspace/cache
```

`root`, `syntila`, `state`, and `work` are required. Extra aliases are allowed
for platform locations, but aliases do not grant Worker filesystem access.
Allowed folders remain a separate security registry. The state directory is a
bootstrap selected by the platform default or `--data-dir`; `folders.state`
documents it and cannot relocate the file that contains it.

Secrets, identities, Cloud registration, Worker registry, Profiles, sessions,
and transient state remain in dedicated stores and never belong in
`workspace.nano`. Environment variables are build/development/test inputs,
credential-store selection, or the bootstrap state-directory override—not
fallback settings in packaged builds.

| Variable | Classification | Purpose |
| --- | --- | --- |
| `SYNTILA_WORKSPACE_VERSION` | build/release | service and CLI version |
| `SYNTILA_WORKSPACE_ENVIRONMENT` | build-time define | `local` or `production` target Cloud; selects the state directory and pins the Cloud URL for local builds |
| `SYNTILA_RELEASE_TRUST_KEYS_JSON` | build/release | public Workspace application-release trust roots |
| `SYNTILA_MACOS_SIGN_IDENTITY` | build/release | service and Engine signing |
| `SYNTILA_MACOS_NOTARY_PROFILE` | release-only | notarization keychain profile |
| `SYNTILA_DART_EXECUTABLE` | build/test-only | select a Dart SDK for Engine builds |
| `SYNTILA_DEVELOPMENT_PROFILE_DIRECTORY` | development-only | unsigned local Profile drafts |
| `SYNTILA_WORKSPACE_DEVELOPMENT_DATA_DIR` | development-only | isolated dev state root |
| `SYNTILA_WORKSPACE_BUNDLE_DIR` | test/development-only | explicit bundled Engine location |
| `SYNTILA_WORKSPACE_DATA_DIR` | CLI/test override | explicit state directory; persisted state wins in packaged service |
| `SYNTILA_WORKSPACE_RUNTIME_ID`, `SYNTILA_WORKSPACE_INSTALLATION_ID`, `SYNTILA_WORKSPACE_ID` | CLI/test override | fixture identity values; never production secrets |
| `SYNTILA_WORKSPACE_TOKEN` | test-only | fixture credential; production uses secure storage |

`SYNTILA_WORKSPACE_GATEWAY` is a Cloudflare binding name, not Workspace
configuration. Provider, profile-admin, deployment, and database variables are
owned by their respective Cloud/Profile Lab workflows and are outside this
runtime contract.

## Build and artifact pipeline

There is one Worker Engine source and build:

```text
engines/cli_worker
       ↓ scripts/build-cli-worker-engine.sh
apps/workspace/assets/engines/syntila-agent
apps/profile_lab/assets/engines/syntila-agent
```

The two app paths are materialized copies for their bundles, not independent
source artifacts.

`scripts/build-workspace-service.sh` compiles the unified `syntila`
binary (plus the Engine) into `dist/syntila/`,
or `dist/syntila/linux-<arch>/` when cross-compiling.
`scripts/run-workspace-service.sh` launches that compiled executable by default
and reserves `--source` for Dart debugging; `scripts/check-workspace-service.sh`
compiles the service and runs a one-shot lifecycle in temporary directories.
`scripts/build-workspace-macos.sh` produces the signed macOS bundle directory
(`syntila`, `assets/engines/syntila-agent`)
and a zip; `scripts/verify-workspace-service-bundle.sh` validates it and
`scripts/package-workspace-macos.sh` wraps it in a `.pkg`. There is no `.app` and
no `SMAppService`: the installer does not register or start the service, and
`syntila service install` writes the per-user LaunchAgent, so upgrades
keep existing Application Support state. Linux uses
`scripts/build-workspace-linux-headless.sh` and `scripts/package-workspace-linux.sh`
(see [Linux releases](../deployment/WORKSPACE_LINUX_RELEASES.md)). Set
`SYNTILA_MACOS_INSTALLER_SIGN_IDENTITY` (Developer ID Installer) and
`SYNTILA_MACOS_NOTARY_PROFILE` for distributable macOS artifacts.
Signing and launchd checks are release/device evidence and cannot be replaced
by a successful Dart compile.

## Validation and boundaries

Focused suites are organized around the ownership model:

| Suite | Protects |
| --- | --- |
| Workspace CLI | commands, `workspace.nano` handling and IPC projections |
| Workspace Service/runtime | lifecycle, assignment recovery, configuration, filesystems |
| Workspace IPC | authentication, versioning, commands, events |
| Worker Engine | profile/command execution and process cleanup |
| Workspace Cloud | runtime authentication, sessions, inventory, admission |
| Workspace DB | schema and migration contracts |

Architecture tests assert that the CLI does not construct Cloud/Engine runtime
objects or spawn processes, the Engine does not import Cloud domain code, the
Service composes Cloud and Workers, `service stop` does not unregister, and
`Disconnect Cloud` leaves the service process available. Historical migration
tests remain where they protect existing installations; obsolete architecture
tests should be removed only after an equivalent boundary test exists.

## Future portability

The shared service and protocol remain platform-independent Dart. macOS host
registration (a user LaunchAgent driven through `launchctl`) is behind
`WorkspaceServiceManager` in `macos_service_manager.dart`. Linux and Windows support is
decided in [ADR-021](../decisions/ADR-021-workspace-service-linux-windows.md)
and is implemented in platform adapters. Windows x64 runtime source support
includes per-user logon tasks, owner-only named pipes, DPAPI and process jobs;
release qualification remains gated by Windows device evidence. Linux source
support includes systemd user units, Unix-socket IPC, and a recorded Secret
Service or `0600` file credential store; see the
[Linux operations guide](../operations/WORKSPACE_LINUX.md).

- Linux: systemd user unit, or the service as a foreground main process for
  containers; Unix-domain socket IPC under the `0700` state root; Secret
  Service or a `0600` file, selected once per state root and recorded
  (`systemd-creds` is not implemented); `$XDG_STATE_HOME/syntila/workspace`,
  with an existing legacy `~/.syntila` root kept in place.
- Windows: per-user logon task in the interactive session (not a Service
  Control Manager service); named-pipe IPC restricted to the owning user;
  DPAPI secret store; `%LOCALAPPDATA%\Syntila\Workspace`.
- On every platform the Service, Engine, and provider CLIs run as the same
  user that owns the CLI logins; Syntila never manages provider credentials.
- Headless operation is primary. Hosts are configured through `workspace.nano`
  and managed through the `syntila` client over authenticated local
  IPC. Existing Cloud email/password sign-in works in the terminal without a
  browser; browser approval remains an MFA fallback.

### Profile-declared model discovery

The Worker Engine owns bounded CLI model discovery under the current Profile;
the Service persists and republishes public metadata through existing inventory
and IPC events. Client refresh requests go through the Service and do not run provider
commands. Workflow/request settings remain the authoritative selection surface.
See [Gemini/AGY profile and discovery contract](GEMINI_AGY_PROFILE.md), including
its required live readiness test and Cloud-owned Chat/Work policy boundary.

For discovery-backed Profiles, Workspace is the source of truth for the current
model and effort list. The Engine uses the provider's declared discovery
protocol: Gemini/AGY uses bounded TSV output, while ChatGPT/Codex uses the
newline-delimited JSON-RPC `initialize` and `model/list` requests of
`codex app-server`. The Service publishes the sanitized catalog with the Worker
inventory, and Cloud exposes only a matching Profile digest and CLI version to
AX. AX therefore reads the catalog through its normal Cloud/cache
synchronization path; it never talks to a provider CLI directly.
Discovery-backed Profiles contain no static fallback catalog or guessed effort
rules. A missing or mismatched catalog leaves choices unavailable. Temporary
discovery failures retain a matching last-known-good catalog with a stale flag;
background refresh restores freshness without changing an identical revision. The app-server is used only for discovery; generic Profile
execution remains the Worker Engine's responsibility.

The additive [Worker execution options v2 contract](../specifications/WORKER_EXECUTION_OPTIONS_V2.md)
keeps logical selection IDs separate from local native IDs. The Service persists
the versioned Engine catalog and removes native IDs from Cloud inventory. Cloud
exposes only selection metadata and an opaque stable catalog revision; Profile
digests and discovery CLI versions remain internal admission bindings.


### Service capability lifecycle

The Service readiness monitor owns startup and one-minute background capability
refresh, plus setup, enable, Profile-change and explicit-refresh triggers.
Matching simultaneous requests coalesce; uncovered scopes and Profile changes
queue a serialized pass. Provider version or Profile digest mismatch invalidates
current capability entries without rewriting historical selections. Freshness
is independent of the stable capability revision and reaches Cloud/AX as bounded
v2 metadata. This continues without a GUI connection or human UI session while
the authorized Service runs. Details are in the
[execution options contract](../specifications/WORKER_EXECUTION_OPTIONS_V2.md#phase-4-freshness-and-service-ownership).

### Shared capability presentation

AX and Profile Lab use `syntila_design/ModelEffortSelector` with public
capability projections from `syntila_protocol`; the Workspace CLI (`workers`)
prints the Service-owned catalog. They display the actual per-model efforts,
defaults and freshness without performing discovery or execution, and their host
adapters supply authorized catalogs. See the shared presentation contract in
[Worker Execution Options v2](../specifications/WORKER_EXECUTION_OPTIONS_V2.md#phase-6-shared-flutter-modeleffort-selection).


### Immutable execution selection evidence

Cloud freezes public effective selections and display names in the assignment;
Workspace Service forwards provider catalog pins using Local Worker Protocol 4.1.
The separately supervised Engine 1.3.0 validates current Profile/catalog
compatibility and writes immutable private native-resolution evidence in its
runtime state directory before invoking a CLI. Completion evidence distinguishes
observed provider exit status from unavailable model/effort attestation. Native
selection details remain local. Combined effort variants obey native-model session
compatibility; separate effort remains per turn. Work history uses frozen public
assignment labels and never the current inventory to relabel an old execution.
See [execution options](../specifications/WORKER_EXECUTION_OPTIONS_V2.md#phase-8--immutable-execution-resolution-and-history)
for snapshot fields and rollout order.

### Windows runtime candidate

`windows_service_manager.dart` implements the per-installation, per-user
interactive logon task behind `WorkspaceServiceManager`. Platform Win32 adapters
own protected paths, CurrentUser DPAPI and named pipes; shared lifecycle/RPC code
retains ownership and wire contracts. Host Stop requests graceful service exit
through private runtime metadata, then bounds forced task termination. Disconnect
Cloud is unchanged and does not stop the service. Stop leaves the logon task
registered. Engine 1.3.1 and the service own nested kill-on-close Windows jobs;
no client launches provider/Engine processes. Runtime credentials remain local.

The Windows package reuses canonical Engine/service builds. CI qualifies native
primitives and compiled-service lifecycle. Signed releases, logon/reboot
and real published Profile execution need target-device evidence. See the
[Windows operations guide](../operations/WORKSPACE_WINDOWS_PREVIEW.md).
