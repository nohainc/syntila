# GitHub Actions

Syntila uses the manual (`workflow_dispatch`) workflow below for Windows releases (all other checks and deployments run locally on macOS).

| Workflow | Runs when | Purpose |
| --- | --- | --- |
| `release-windows.yml` | Manual | Build and optionally publish the signed Windows Connect release. |

Shared setup lives in `.github/actions/` (`setup-flutter`). Helper scripts live in `scripts/ci/`. Repository protection is defined in `scripts/github/apply-repo-settings.sh`.

## Rules for changing workflows

Every action is pinned to a commit SHA with its version in a comment. Dependabot proposes updates weekly. Changes to `.github/`, `scripts/ci/`, `scripts/github/`, `scripts/release/`, and `infra/` require the code owner's review.

Production secrets are only available to jobs in the `production`, `production-site`, `workspace-release`, `workspace-linux-release`, and `workspace-windows-release` environments. Pull requests from forks never receive secrets. Forks need approval before any workflow runs.

Path filters are computed in `scripts/ci/detect-changes.sh`. A change to shared tooling (`.github/`, `scripts/`, root configs, lockfile) runs every CI domain, so the filters cannot skip tests they are responsible for.

## Applying repository settings

Run `scripts/github/apply-repo-settings.sh` as a repository admin. It is a dry run until you pass `--apply`, and it is safe to run again. The settings it applies are described in the script header.
