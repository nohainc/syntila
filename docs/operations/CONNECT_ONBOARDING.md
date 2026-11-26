# Connect onboarding (Windows)

Connect runs a computer's Workers. It is installed for your Windows user only and never needs administrator rights.

1. **Download.** From the GitHub Releases page of the repository, get `Syntila-Connect-<version>-windows-x64-Setup.exe` (or the portable zip) and `SHA256SUMS`. Verify: `(Get-FileHash .\Syntila-Connect-<version>-windows-x64-Setup.exe).Hash` must match the line in `SHA256SUMS`. The files are unsigned, so Windows SmartScreen may warn.
2. **Install.** Run the installer. It installs to `%LOCALAPPDATA%\Programs\Syntila\Connect` and adds a Start menu entry. The portable zip is the same files in a folder of your choice.
3. **Pair.** In the web app open Workers, add a Worker and copy the pairing code (it works once and expires after ten minutes). In PowerShell: `syntila-connect pair --pairing-code CODE --auto-start`. The server address is part of the code, so the Worker talks to the server that issued it. `--auto-start` installs the per-user logon task so the Worker starts when you sign in.
4. **Start and check.** `syntila-connect status` (or the Syntila Connect app). A Worker shows "ready" in the web app after Connect reports ready. Folders: `syntila-connect folders add PATH` (add `--read-only` to withhold writes); a folder that was not granted cannot be reached.
5. **Update.** Install the next version over the old one; Worker data is kept. Portable: replace the whole folder.
6. **Uninstall.** Windows Settings → Apps → Syntila Connect (or `unins000.exe` in the install folder). Remove the logon task first with `syntila-connect service uninstall` if you want no trace.
7. **Where data lives.** `%LOCALAPPDATA%\Syntila\Workers\<worker-id>\` holds each Worker's credential (protected with DPAPI), session, journal and lock; folders and the device ID are shared by the computer. Uninstalling does not delete this data.
8. **Support checks.** `syntila-connect status --json` and `syntila-connect logs get --lines 200` (ids and codes only).

Related: [CONNECT_CLI_AND_SERVICES.md](../specifications/CONNECT_CLI_AND_SERVICES.md), [ADR-034](../decisions/ADR-034-connect-pairing-and-session-fencing.md).
