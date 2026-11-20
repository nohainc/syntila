# Worker Agent: onboarding and support

For people who used a Workspace before.

- **What changed.** A Worker is now its own thing, not a part of a Workspace. One Agent (`syntila-worker`) runs one Worker on a computer. You pick Workers, not Workspaces, when you start Work.
- **Set up a computer.** In Workers, add a Worker and copy the pairing code. On that computer: `syntila-worker install --pairing-code CODE --auto-start`. The code works once and expires after ten minutes.
- **Coming from a Workspace.** After installing, run `syntila-worker import-workspace --from <old Workspace data folder> --dry-run`, then again without `--dry-run`. Your Work Root and folders come over read-only; add `--write` to keep write access. Keys, Profiles and native sessions are not copied: the Agent makes its own key and downloads Profiles itself.
- **Folders.** `syntila-worker permissions add-folder PATH [--write]`. A folder that was not granted cannot be reached, whatever the web app asks for.
- **Files between steps.** Steps pass files as artifacts (kept 7 days), never as paths on a computer.
- **If a request shows "This request did not finish."** Open the Work view for the step's error; the timeline line is fixed text on purpose.
- **Support checks.** `syntila-worker status --json` and `syntila-worker logs --lines 200` (ids and codes only). A Worker shows "ready" in the web app only after its Agent reports ready.
- **A Workspace cannot register any more** once registration is closed; the app tells the user to install the Agent (HTTP 410 `workspace_registration_closed`).

Related: [WORKER_AGENT_CLI_AND_SERVICES.md](../specifications/WORKER_AGENT_CLI_AND_SERVICES.md), [LEGACY_CUTOVER.md](LEGACY_CUTOVER.md).
