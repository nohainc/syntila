# Windows Workspace installer

The Windows build workflow produces an unsigned per-user Inno Setup installer
alongside the ZIP candidate. This is not a signed production release; signed
releases are produced by the Windows release workflow described in
[Windows Workspace releases](../deployment/WORKSPACE_WINDOWS_RELEASES.md).
`scripts/package-workspace-windows.ps1 -Sign` signs the installer and
uninstaller and refuses to package a bundle with unsigned binaries.

Run `scripts/internal/build-workspace-windows.ps1`, then
`scripts/package-workspace-windows.ps1` on Windows with Inno Setup 6 installed.
The workflow pins compiler 6.7.3 from the official release with a SHA-256 check. Outputs are under
`dist/syntila/installer/` and uploaded as
`syntila-workspace-windows-x64-installer`. The application version comes from
`apps/workspace/pubspec.yaml`; prerelease versions require an explicit packaging
policy before they can be packaged.

The installer copies the complete canonical bundle, including the unified CLI/service and bundled Engine, to `%LOCALAPPDATA%\Programs\Syntila\Workspace` and adds a Windows uninstall entry. It requires no administrator rights.
A stable AppId enables in-place upgrades. Silent installation supports
`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`.

Before upgrading, run `syntila service stop`. Installation and
uninstall refuse to proceed while any Workspace service process is running; inspection failure also blocks installation. No
provider processes are forcibly terminated. An installation in a different
folder also blocks the operation conservatively.

Runtime registration remains owned by WorkspaceServiceManager, not the
installer. Before uninstalling, run `syntila service uninstall`. `service stop` alone preserves registration. The installer does not
remove scheduled tasks, Cloud identity, DPAPI credentials, runtime state,
sessions, provider logins, or Work Root files. Reinstall to the same location to
recover a retained registration. No schema, protocol, or state migration occurs.

The disposable Windows runner tests silent installation, installed executable
hashes and installed-service lifecycle, repeat installation, CLI/service startup, rejection while running, and uninstall.
Real assignment upgrade recovery, reboot/logon, and interactive desktop
qualification remain release checks. CI uses the existing compile-only trust
root; this installer does not establish production release trust.
