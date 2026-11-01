# Workspace Windows runtime candidate

Windows x64 source support includes the standalone Dart Workspace Service, the
`syntila` management CLI, and the separately supervised generic CLI
Worker Engine. The package is an unsigned qualification candidate, with manual
updates; Windows installer packaging and release signing remain separate ADR-021
phases.

## Build and run

Install the Dart SDK, Node.js and Git for Windows Bash. Supply
`SYNTILA_RELEASE_TRUST_KEYS_JSON` with your public application-release trust
roots, then run from PowerShell at the repository root:

```powershell
./scripts/internal/build-workspace-windows.ps1
```

The script uses the canonical Engine/service build scripts and creates
`dist/syntila/syntila-workspace-windows-x64-release-preview.zip`.
Extract the entire ZIP to a stable per-user installation directory. The target
machine needs the Microsoft Visual C++ x64 redistributable. Run
`syntila.exe service install` and `setup` (or `login`, then `connect`).
Moving an installation changes its scheduled task executable path; stop and
unregister the old task before registering the new path. Existing data is kept.
For manual updates, stop the service, replace the complete application directory,
and start the service again. Do not replace individual Engine or service files.

The **Workspace / Windows / Release** workflow builds and tests the signed Windows release.

## Platform behavior

- `WorkspaceServiceManager` owns a Task Scheduler task per installation. The
  task runs at logon as the current user, in the interactive session, without
  requesting elevation or a Windows SCM service. Stop keeps registration;
  Cloud disconnect keeps the service available. Stop requests graceful exit
  through the host stop marker before bounded Task Scheduler termination.
- Management uses `\\.\pipe\syntila-workspace-<installation-id>`. The native
  adapter sets a protected owning-user SID DACL, rejects remote clients, and
  verifies the pipe owner before sending the existing capability key. Existing
  protocol/version/authentication semantics remain; input is byte-bounded before
  JSON decoding. No TCP listener is introduced.
- Workspace credentials use CurrentUser DPAPI with service/account entropy.
  Only ciphertext is written under `Credentials` in private Workspace state.
  State uses `%LOCALAPPDATA%\Syntila\Workspace`; user work defaults to
  `%USERPROFILE%\Documents\Syntila`, independently of application files.
- Legacy `~/.syntila` state stops default activation with a
  recoverable error. Registries may hold absolute paths, so the application does
  not move files or guess which root is authoritative. Select the existing root
  with `SYNTILA_WORKSPACE_DATA_DIR` (or the service's `--data-dir`) to retain its
  installation/Cloud identities, credentials, registry, sessions, Profiles,
  Engine files, and configured Work Root. Existing macOS installations do not
  migrate. No replacement Cloud Workspace is created by this recovery.
- Management step-up uses Windows Hello, with an OS credential-dialog fallback.
  Password verification compares the returned logon SID to the current user;
  credentials are wiped from native buffers and never persisted. Cancellation
  does not authorize an action. Interactive prompts require target-device tests.
- Prevent Sleep uses a process-owned Windows system power request. The request
  is cleared when disabled and released by Windows if the service exits.
- The service and Engine retain kill-on-close Windows Job Objects. Descendants
  cannot escape on an Engine/service crash. Forced Engine cleanup terminates
  its job. Provider CLI account state stays with the same OS user.
- CLI discovery respects bounded PATHEXT executable suffixes. Standard npm
  `.cmd`/`.bat` launchers are resolved to Node entry points and invoked directly,
  preserving literal arguments without a command shell. Arbitrary batch wrappers
  are rejected; declare a direct executable in their Profile. CLI authentication
  and supported-platform environment/path rules remain Profile-owned.

## Qualification gates

Automated evidence covers IPC authentication/restart, bounded framing, DPAPI
ciphertext/rotation, compiled-service duplicate ownership/disconnect/restart,
Engine descendant cleanup, literal CLI arguments, and UI process startup.
These checks do not establish successful model execution with every published
Profile, interactive logon/reboot behavior, Windows signing/SmartScreen handling,
or rendered UI quality. Retain target-device evidence for those claims before a
Windows production release. A compatible Profile and a CLI logged in as the
service user are required for real assignments.
