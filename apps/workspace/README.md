# Syntila Workspace

Syntila Workspace is the machine-side execution and security runtime. It is a
headless Dart service plus a management CLI; there is no desktop GUI.

It maintains the Cloud connection, owns application-managed runtime state,
resolves the user-owned local Work Root, and creates/resolves one stable
working directory per Space shared by its Threads, manages logical Workers and
local provider credentials, resolves current Tool Profiles, launches the generic
CLI Worker Engine, enforces local permissions, supervises execution, and reports
safe readiness/status back to Syntila Cloud.

Spaces, Threads, Discuss, Work orchestration, Space membership and remote
scheduling policy belong in Syntila. The authoritative ownership and
lifecycle contract is the
[Workspace architecture](../../docs/architecture/WORKSPACE_ARCHITECTURE.md).

## Executables

| Name | Role |
| --- | --- |
| `syntila` | Unified binary (`bin/syntila_workspace.dart`): the management CLI, and the service when run as `syntila run` |
| `workspace` | Alias of the same binary. When invoked under this name it runs the service, which is what systemd, containers and `--once` smoke tests use |
| `syntila-agent` | The separately supervised generic CLI Worker Engine, bundled under `assets/engines/` |

`bin/syntila_workspace_service.dart` is the service entry point used by the
unified binary and by source-mode development; `bin/syntila_workspace_cli.dart`
is the CLI-only entry point. The runtime is composed in
`lib/workspace_runtime.dart`.

Users install only Syntila Workspace. Workspace manages the bundled generic
Engine and current Tool Profiles; provider CLI software is installed separately
by its provider.

## GUI manifest

`syntila --gui-manifest[=N]` prints a GUI Manifest v1 Nano Markup document
describing the management commands (titles, parameters, result views,
destructive/interactive flags) for GUI front ends. It needs no service, no
sign-in and no network. Unsupported versions exit `2`. The command list lives
in `lib/workspace_gui_manifest.dart`; keep it in sync with the CLI dispatch.

## Configuration: `workspace.nano`

Non-secret behavior is defined in the strict, versioned Nano Markup file
`<state>/workspace.nano`: Cloud origin and connect-on-start intent, display
name, parallel execution slots, and a map of named absolute folders. The service
reads it once at process start; there is no live reload or settings IPC command.

~~~text
syntila config init|show|validate|path
~~~

Edit the file while the service is stopped (or edit and then run
`syntila service restart`). Credentials, identities, Cloud
registration, Worker registry, Profiles and sessions live in dedicated stores,
never in `workspace.nano`. `connect`, `disconnect`, `setup` and sign-in update
the relevant keys for you.

## Account and service lifecycle

The CLI drives the whole lifecycle; it speaks only the authenticated local IPC
protocol and never starts Engines or provider CLIs itself.

~~~text
syntila service install|start|stop|restart|status|uninstall
syntila setup                 # config, name, login, register, then optionally start the service
syntila login                 # Cloud email/password sign-in (stores the session only)
syntila register              # register this Workspace with Cloud (after login)
syntila logout                # delete the stored sign-in session
syntila unregister            # unregister from Cloud and clear identity
syntila reset                 # stop, unregister and clear local runtime state
syntila work-dir [PATH]       # inspect or update primary Work Root path
syntila connect | disconnect  # Cloud connection intent
syntila pause | resume        # stop or resume accepting new work
syntila status | version | logs | metrics
syntila workers               # list configured workers
syntila workers catalog       # list available catalog workers
syntila workers add TYPE      # add worker from catalog (gemini, chatgpt, etc.)
syntila workers remove TYPE   # remove a configured worker
syntila workers [check|test|enable|disable]
syntila slots | assignments [cancel ID] | folders [add|remove]
~~~

`service install` registers the per-user background service with the host
manager: a systemd user unit on Linux, a LaunchAgent in `~/Library/LaunchAgents`
on macOS (`macos_service_manager.dart`), and a scheduled task on Windows.
`service stop` asks the service to drain active assignments before it exits and
leaves the registration and the persisted Cloud intent intact. Closing a
terminal never stops the service. A running service can be Cloud-offline
without being stopped; it connects over WebSocket with HTTP fallback and
bounded reconnect backoff.

Stopping the service preserves installation ownership and local Worker/provider
credentials. See [ADR-014](../../docs/decisions/ADR-014-workspace-desktop-lifecycle.md)
for the lifecycle dimensions and [ADR-021](../../docs/decisions/ADR-021-workspace-service-linux-windows.md)
for the headless architecture.

## Storage

The Workspace is an execution environment, not a directory. Its private
Application Data Root is resolved automatically under the Syntila application
family root (`~/Library/Application Support/Syntila/` on macOS, XDG state on
Linux, `%LOCALAPPDATA%\Syntila` on Windows). The user Work Root is separate and
defaults to `~/Documents/Syntila`; Space Work Directories live beneath it and
are configured through `folders.work` in `workspace.nano`. Space directory names
are human-readable, while a private registry and marker bind each directory to
its immutable Space ID. Thread directories are not created during normal
execution; Thread sessions and runtime metadata remain under the Application
Data Root. A changed Work Root applies to future Space directory resolution and
never moves existing user files.

The per-installation lock rejects a second service process that attempts to own
the same Workspace installation.

## Cloud connection

Sign in with `syntila login` (Cloud email and password), then run
`syntila register`. Workspace verifies installation ownership, registers or
recovers through `POST /api/workspace-runtime/register`, and then connects to the
Workspace Gateway using its runtime credential. The service journals assignment
outcomes and classifies interrupted work on startup before accepting new work.
See the canonical architecture document for recovery states, process cleanup,
logging and Cloud reconciliation limits.

## First-party Worker v1 contract

The supported product-facing Worker slots are **ChatGPT**, powered by Codex CLI
(`codex`), and **Gemini**, powered by Antigravity CLI (`agy`). Each Workspace has
one local Worker slot for each logical Worker Type. The corresponding CLI owns
sign-in, credential storage, and billing mode; Syntila checks whether the CLI
can execute and does not request or store provider credentials. See
[ADR-015](../../docs/decisions/ADR-015-first-party-worker-v1-contract.md).

Normal Workspace execution uses the generic Engine and current Worker Profiles.
If Profile Lab can list a Worker but Workspace reports its Profile as
unavailable, check `syntila logs` and the diagnostics report for the
schema, digest, identity, Engine-compatibility or Cloud-connectivity error. Do
not bypass local Profile validation or delete the cached Profile directories.
Worker readiness remains a local execution fact; Cloud receives only safe
inventory.

## Build and run

Requirements: the Dart SDK (no Flutter SDK), Node.js for the release-trust
helper, and macOS, Linux or Windows for the matching package.

| Task | Command |
| --- | --- |
| Compile the unified binary and Engine (host OS) | `bash scripts/build-workspace-service.sh` → `dist/syntila/` |
| Run the compiled service | `scripts/run-workspace-service.sh` (`--source` runs from Dart source) |
| Run from source against local Cloud | `pnpm workspace:run:local` |
| One-shot compile + start + stop check | `bash scripts/check-workspace-service.sh` |
| Analyze and test | `bash scripts/check-flutter-app.sh workspace` (`dart analyze`, `dart test`) |
| macOS bundle (signed, zipped) | `pnpm workspace:build:macos[:local|:prod|:all]`, then `pnpm workspace:package:macos` for a `.pkg` |
| Linux headless bundle and `.deb` | `scripts/build-workspace-linux-headless.sh <x64\|arm64>` then `scripts/package-workspace-linux.sh <arch>` |

`SYNTILA_RELEASE_TRUST_KEYS_JSON` supplies the explicit public Ed25519 roots
used to verify Workspace application releases; it is not used to admit Worker
Profiles. Optional macOS environment: `SYNTILA_MACOS_SIGN_IDENTITY`,
`SYNTILA_MACOS_NOTARY_PROFILE`, `SYNTILA_WORKSPACE_VERSION`.

Compiled service and Engine processes set their diagnostic names at startup, so
process tools show `workspace` and `syntila-agent` rather than the Dart runtime.
This changes only the local display name.

### macOS

`build-workspace-macos.sh` produces `dist/syntila/macos/syntila/`
(`syntila`, the `workspace` symlink and `assets/engines/syntila-agent`)
signed with the hardened-runtime entitlements in
`packaging/macos/workspace-helper.entitlements`, plus
`Syntila-Workspace-<version>-macos.zip`. There is no `.app` and no `SMAppService`;
`--install` copies the bundle to `~/.local/lib` and links the commands into
`~/.local/bin`, and `syntila service install` writes the LaunchAgent.
An Apple identity is optional for local use (ad-hoc signatures are used when none
is available). Update metadata is signed by an independent Ed25519 application
release key and binds the archive digest, version, channel, supported platform,
minimum supported version and release notes; Developer ID signing and
notarization complement this verification and do not replace it. Publish macOS
builds through `.github/workflows/release-macos.yml`, which requires a successful
repository CI run for the selected `main` revision.

### Linux

A systemd user unit per installation, Unix-socket IPC, a recorded Secret Service
or user-only file credential store, XDG state, and process-group/cgroup cleanup.
See the [Linux operations guide](../../docs/operations/WORKSPACE_LINUX.md).

### Windows

Per-user scheduled-task service management, owner-only named-pipe IPC, DPAPI
credentials, private local state and Engine Job Object cleanup. The package
remains unsigned with manual updates. The Windows build and installer scripts
still predate the headless service/CLI-only layout and are being reworked; see
[the Windows guide](../../docs/operations/WORKSPACE_WINDOWS_PREVIEW.md) and
[the installer guide](../../docs/operations/WORKSPACE_WINDOWS_INSTALLER.md).

## Local vs production builds

A Workspace build targets exactly one Cloud; there is no runtime switch.

| Command | Cloud API | State directory (macOS) |
| --- | --- | --- |
| `pnpm workspace:build:macos:prod` (default) | `https://syntila.app` | `~/Library/Application Support/Syntila` |
| `pnpm workspace:build:macos:local` | `http://localhost:8787` | `~/Library/Application Support/Syntila Local` |

Local builds are compiled with `SYNTILA_WORKSPACE_ENVIRONMENT=local`, ignore
`cloud.url` from `workspace.nano`, and write to a separate state directory so they
never touch a production registration or session. Start the local API/web stack
first with `pnpm app:run:local`. The local bundle installs as
`syntila-local`; the production and local services can run side by
side, each with its own state directory, installation lock, IPC socket and
LaunchAgent label.
