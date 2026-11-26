# GitHub Actions

Syntila uses these manual (`workflow_dispatch`) workflows for Windows builds and releases (all other checks and deployments run locally on macOS).

| Workflow | Runs when | Purpose |
| --- | --- | --- |
| `build-connect-windows.yml` | Manual | Build and test the Windows x64 installer and portable archive; download them from the run artifacts. |
| `release-windows.yml` | Manual | Publish the artifacts from a selected successful build run. |

Run **Build Connect for Windows** first. The installer and binaries are unsigned. To publish, run **Release Connect for Windows** on `main` and provide the build run ID and optional release notes. The selected build must be a successful manual run on `main`. The release verifies its checksums and publishes the same installer and archive without rebuilding. Actions artifacts expire according to the repository retention policy, so release them before expiry. The release creates a tag at the build commit using its version; an existing release cannot be replaced by this workflow.

Windows may show publisher or SmartScreen warnings for these unsigned downloads.

The Windows installer and portable archive put `Syntila Connect.exe`, `syntila-connect.exe` and `syntila-worker.exe` in the same folder. Connect resolves the Worker Engine beside its CLI on each platform. Upgrade portable installations by replacing the complete bundle; existing Worker data is stored separately.

The build requires production profile trust roots and uses the `connect-windows-release` environment. Environment protection rules may require approval for either workflow.

Shared setup lives in `.github/actions/` (`setup-flutter`). Helper scripts live in `scripts/ci/`. Repository protection is defined in `scripts/github/apply-repo-settings.sh`.

## Rules for changing workflows

Every action is pinned to a commit SHA with its version in a comment. Dependabot proposes updates weekly. Changes to `.github/`, `scripts/ci/`, `scripts/github/`, `scripts/release/`, and `infra/` require the code owner's review.

Production secrets are only available to jobs in the `production`, `production-site`, `workspace-release`, `workspace-linux-release`, and `workspace-windows-release` environments. Pull requests from forks never receive secrets. Forks need approval before any workflow runs.

Path filters are computed in `scripts/ci/detect-changes.sh`. A change to shared tooling (`.github/`, `scripts/`, root configs, lockfile) runs every CI domain, so the filters cannot skip tests they are responsible for.

## Applying repository settings

Run `scripts/github/apply-repo-settings.sh` as a repository admin. It is a dry run until you pass `--apply`, and it is safe to run again. The settings it applies are described in the script header.
