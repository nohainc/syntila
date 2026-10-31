# Workspace on Linux

Linux x64/arm64 support is headless: the standalone Dart Workspace Service,
the `syntila` management CLI and the separately supervised generic
CLI Worker Engine (ADR-021), shipped together as a Debian package through a
signed APT repository or as a headless tarball. See [Linux release operations](../deployment/WORKSPACE_LINUX_RELEASES.md)
for publication setup and qualification requirements.

## Install the headless Debian package

Use the production HTTPS repository below. Verify the public signing key against
fingerprint `6EA013D12EF79CBDC34D66058182CCCFCF4175F2` before installing it.

```bash
APT_URL=https://nohainc.github.io/syntila
curl --fail --location "$APT_URL/syntila-archive-keyring.gpg" -o /tmp/syntila-archive-keyring.gpg
gpg --show-keys --with-fingerprint /tmp/syntila-archive-keyring.gpg
sudo install -D -m 644 /tmp/syntila-archive-keyring.gpg /etc/apt/keyrings/syntila-archive-keyring.gpg
printf 'Types: deb\nURIs: %s\nSuites: stable\nComponents: main\nSigned-By: /etc/apt/keyrings/syntila-archive-keyring.gpg\n' "$APT_URL" | sudo tee /etc/apt/sources.list.d/syntila.sources
sudo apt update
sudo apt install syntila
```

Run all following commands as the normal user who owns the provider CLI logins,
without `sudo`. The package does not install provider CLIs or manage their logins.
It installs binaries under `/usr/lib/syntila`, and symlinks under
`/usr/bin`; GTK and a desktop session are not needed.

On a desktop, also install the GUI from the same repository:

```bash
sudo apt install syntila-gui
```

`syntila-gui` installs into the same folder (`/usr/lib/syntila/gui`), drives
`/usr/lib/syntila/syntila`, requires the exactly matching `syntila` version, and
adds a "Syntila Workspace" desktop entry and `syntila-gui` command. The CLI keeps
working on its own; headless hosts never pull in GTK.

```bash
syntila setup
# Enter your existing Syntila Cloud email and password at the prompts.
# Password input is hidden. Never pass it as a command-line argument.
syntila status
sudo loginctl enable-linger "$USER"
```

`setup` refuses to run while the service is already running. Otherwise it creates
`workspace.nano` if it is missing, asks for the Workspace name (Enter keeps the
machine name), signs in through Cloud's existing Better Auth email/password
verifier, registers or recovers this installation, and finally asks whether
to start the systemd **user** service. If you answer yes it installs and starts
the service, waits for authenticated local IPC and for Cloud synchronization.
It never installs or probes Workers. Zero Workers is a supported online state.
An already registered installation skips the name and password prompts. The
runtime credential persists across logout and service restart; it is independent
of the management session's expiry. No browser is needed on the server and no
public inbound port is opened.

## Configure the service

The package creates `<state>/workspace.nano` on first setup. Inspect and
validate it with:

```bash
syntila config path
syntila config show
syntila config validate
```

Stop the service before editing this Nano Markup file, then restart it. Settings
are applied only at process startup; the service has no live configuration
mutation command. The file controls `service.enabled`, `cloud.url`,
`cloud.connect_on_start`, `workspace.name`, `execution.parallel_slots` (1–10),
and the named absolute-path `folders` map. Required aliases are `root`,
`syntila`, `state`, and `work`; additional aliases describe useful locations
but do not grant Worker access. Passwords, tokens, and registration IDs must
never be added to this file.

For an already running service, `syntila login --password` performs
only account sign-in/registration; follow it with `syntila connect`.
Accounts that require additional verification must use the existing browser
flow (`syntila login`, opening the returned URL on another device).
Password sign-in does not bypass MFA, disabled accounts or ownership checks.
Passwords and temporary authentication cookies are never stored in Workspace
state, CLI output or diagnostics. The temporary Cloud login session is closed
after issuing the separate desktop management session.

Before contacting Cloud, login tests credential write/read/delete. A fresh
Linux install selects Secret Service only when both `secret-tool` and an active
`org.freedesktop.secrets` service are available. A systemd user D-Bus by itself
does not qualify. Otherwise it selects the documented headless file store:
`0700` directory and `0600` files owned by the service user. An existing recorded
store remains authoritative; it is never silently replaced. If it is broken,
setup fails before remote registration. Review the recorded store and preserve
existing keys before any explicit repair.

Login failures report a safe `stage` and `code` through `login status`, without
returning server response text or secrets. A Cloud-only registration can be
recovered under the same installation identity after same-owner verification;
setup does not create a replacement Workspace to conceal a failed local write.

Browser `login` starts a service-owned approval operation and returns immediately. Poll
`login status` for `pending`, `complete`, `failed` or `cancelled`; use
`login cancel` to cancel before registration commits. No comparison code is
printed because the existing Cloud approval contract uses a verification URL.
The service retains the intent poll token, human session and runtime credential;
none is returned to the CLI. Sign-in refuses a different owner or ambiguous/stale
registration; existing installations needing recovery must use the desktop
recovery flow. A fresh registration does not connect Cloud until `connect`.

The service uses the Work Root in `<state>/workspace.nano` (initially
`~/Documents/Syntila`). Edit the configuration while the service is stopped,
then restart it; there is no live settings mutation or command-line Work Root
override.
Pass `--data-dir DIR` on **every** CLI command when using a custom state root.
`service install` registers/enables the systemd user unit but does not start it.
`service stop` preserves its registration; `service uninstall` removes the user
unit and preserves all user files.

Update after active assignments finish:

```bash
syntila service stop
sudo apt update
sudo apt install --only-upgrade syntila syntila-gui   # omit syntila-gui if not installed
syntila service start
syntila status
```

APT updates the complete service/CLI/Engine unit. Package installation, upgrade,
removal and purge have no maintainer scripts that start a root service or alter
user state. A running daemon is not automatically restarted: stop/start it as
shown so it uses the matching new Engine. This package disables the separate
application self-updater; APT owns updates. Automatic upgrades require explicitly
configuring the host's unattended-upgrades origin and an appropriate maintenance
window. Removing the package leaves user service registration and state in place;
run `service uninstall` first if you want to remove its systemd unit too.

## Build

The headless install unit is the service, the `syntila` management CLI and
the generic CLI Worker Engine (`syntila-agent`). Build it on any host with the
Dart SDK and Node.js; Dart cross-compiles Linux x64/arm64 executables. The
desktop GUI is built into the same folder; Flutter cannot cross-compile, so
that step runs on a Linux host of the target architecture (with clang, cmake,
ninja-build, pkg-config and libgtk-3-dev):

```bash
export SYNTILA_RELEASE_TRUST_KEYS_JSON='{...public application-release trust roots...}'
bash scripts/build-workspace-linux-headless.sh x64   # or arm64
bash scripts/build-workspace-gui-linux.sh --gui-only # optional, native host
bash scripts/package-workspace-linux.sh x64          # Debian packages, needs dpkg
```

This produces `dist/syntila/linux-<arch>/` (with `gui/` when built), a headless
`.tar.gz`, a full `syntila-workspace-linux-<arch>.tar.gz` when the GUI is built,
`dist/syntila/deb/syntila_<version>_<arch>.deb` and, with the GUI,
`syntila-gui_<version>_<arch>.deb`. See
[Linux release operations](../deployment/WORKSPACE_LINUX_RELEASES.md). The
**Release Linux Workspace** workflow builds and tests natively on Ubuntu amd64
and ARM64, including a real APT install/upgrade and a headless setup smoke test.

## Service (systemd user unit)

- The service is a **systemd user unit**
  `~/.config/systemd/user/workspace-<installation-id>.service`, run as
  the logged-in user so provider CLIs see their own logins. Stop keeps the unit
  enabled; Disconnect Cloud keeps the service running; `service uninstall` disables and
  removes only the unit file.
- To keep the service running without a login session (mini PC, server):
  `loginctl enable-linger "$USER"`.
- Moving the install directory changes the unit's `ExecStart`; the manager
  refuses to overwrite a unit that points to another executable. Run
  `service uninstall` at the old location first. State is preserved.
- Manual update: stop the service, replace the whole directory, start again.

## Headless hosts and containers

Run the service as the foreground main process; the supervisor/container owns
restarts and SIGTERM performs a graceful stop:

```bash
./workspace --data-dir /data/state
```

Persist the state root, Work Root, and the provider CLI credential directories
(`~/.claude`, `~/.codex`, `~/.gemini`) on volumes.

Manage a running service with `syntila` (ADR-021 §2.6). It speaks
the local authenticated IPC only; pass `--data-dir` if the service did:

```bash
./syntila status          # also: version, metrics, logs
./syntila connect         # disconnect, pause, resume
./syntila workers         # workers check|test|enable|disable
./syntila slots           # assignments, assignments cancel ID, folders
```

Add `--json` for raw output. Use `login`, `login status` and `login cancel`
for initial Cloud registration through browser approval. A foreground process
can use these commands without systemd; its supervisor owns process lifecycle.

## Platform behavior

- **State root:** `$XDG_STATE_HOME/syntila/workspace` (default
  `~/.local/state/syntila/workspace`). If a legacy `~/.syntila` root
  exists it remains authoritative in place; nothing is moved or re-registered.
  `SYNTILA_WORKSPACE_DATA_DIR` / `--data-dir` override as on other platforms.
- **IPC:** Unix-domain socket `runtime/manager.sock` under the `0700` state
  root (not `$XDG_RUNTIME_DIR`), using the unchanged authenticated protocol.
- **Runtime credential:** Secret Service (`secret-tool`, libsecret) when a
  session D-Bus is present, otherwise a `0600` file under
  `<state>/Credentials` that is refused if group/other can read it. The first
  write records the choice in `<state>/credential-store`; the CLI and service
  then always use it, with no later fallback. Force a store with
  `SYNTILA_WORKSPACE_SECRET_STORE=secret-service|file`.
- **Process cleanup:** provider CLIs run in their own session/process group
  and are killed as a tree; the unit uses `KillMode=mixed` so anything left in
  its cgroup is reaped on stop.
- **Prevent sleep:** a logind `systemd-inhibit --what=sleep:idle` lock.

## Not yet qualified

Reboot/linger start, Secret Service on specific desktops, real provider
assignments, Wayland vs X11 sessions, and ARM64 desktop UI startup need
device evidence. Headless amd64/arm64 package lifecycle checks are documented
in [Linux package acceptance](../acceptance/WORKSPACE_LINUX_PACKAGES.md).
