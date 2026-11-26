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

Shared setup lives in `.github/actions/` (`setup-flutter`, which uses `scripts/ci/setup-flutter-linux-arm64.sh` on Linux ARM64). Production deploys do not run on GitHub; they use the `scripts/prod-*.sh` scripts on the dev machine.

## Rules for changing workflows

Every action is pinned to a commit SHA with its version in a comment. Dependabot proposes updates weekly. Changes to `.github/` and `infra/` require the code owner's review.
