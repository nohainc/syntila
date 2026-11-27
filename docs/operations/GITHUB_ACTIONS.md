# GitHub Actions

Syntila uses these manual (`workflow_dispatch`) workflows for Windows builds and releases (all other checks and deployments run locally on macOS).

| Workflow | Runs when | Purpose |
| --- | --- | --- |
| `build-connect-windows.yml` | Manual | Build and test the Windows x64 installer and portable archive; download them from the run artifacts. |
| `release-windows.yml` | Manual | Publish the artifacts from a selected successful build run. |

Run **Build Connect for Windows** first. The installer and binaries are unsigned. To publish, run **Release Connect for Windows** on `main` and provide the build run ID and optional release notes. The selected build must be a successful manual run on `main`. The release verifies its checksums and publishes the same installer and archive without rebuilding. Actions artifacts expire according to the repository retention policy, so release them before expiry. The release is the shared `connect-v<version>` (macOS and Linux add their files with the `prod-release-connect-*` scripts): it is created at the build commit if missing, or the Windows files are added when it is on that same commit. Existing files are never replaced.

Windows may show publisher or SmartScreen warnings for these unsigned downloads.

The Windows installer and portable archive put `Syntila Connect.exe`, `syntila-connect.exe` and `syntila-worker.exe` in the same folder. Connect resolves the Worker Engine beside its CLI on each platform. Upgrade portable installations by replacing the complete bundle; existing Worker data is stored separately.

## One-time GitHub setup

1. Settings → Environments → create `connect-windows-release` (optional: required reviewers).
2. In that environment (or repository) add these Variables (public values, not secrets):
   - `SYNTILA_PROFILE_TRUST_ROOTS`: the public key set that matches the private signing key the backend uses (`SYNTILA_PROFILE_SIGNING_JWK` and `SYNTILA_PROFILE_SIGNING_KEY_ID` in `/etc/syntila/backend.env`). Derive the public value with `scripts/profile-signing-env.mjs` (verifies an existing seed against the public roots; see [Production provisioning](PRODUCTION_PROVISIONING.md#profile-signing-identity)) or, for a new development key, `scripts/local-setup-profile-signing.mjs`. A mismatch makes Connect refuse every Profile. The value must be a flat map such as `{"syntila-profile-v1":"PUBLIC_KEY"}`; the build rejects empty, nested, or invalid maps.
   - `SYNTILA_UPDATE_KEYS`: may stay empty; updates are manual.
3. The server address is not built in: it comes from the pairing code the web app issues, so a released Connect talks to production (`https://api.syntila.app`) when paired from `https://syntila.app`.

## Release procedure

1. When starting a new series, run `scripts/set-version.sh connect 0.3` on a clean, up-to-date `main` (substitute the intended major.minor). It commits the series, creates an annotated `connect-series-v0.3` tag and pushes both atomically. A failed push leaves the local commit and tag for recovery; it does not publish a release.
2. Build from the desired pushed `main` commit. The version is `major.minor` plus the number of first-parent commits since the series tag; all platforms in one release must use that same commit. The Windows build fetches full history and tags.
3. Run **Build Connect for Windows** on `main`; note the run ID. It runs `dart test`, builds, runs `scripts/test-connect-windows-installer.ps1` (per-user install under `%LOCALAPPDATA%\Programs\Syntila\Connect`, no administrator rights, upgrade and uninstall) and uploads the installer, portable zip and checksums.
4. Run **Release Connect for Windows** with that run ID. Check the Release has the installer, the portable zip and `SHA256SUMS-windows`, and that the checksum verifies.
5. Install it on a Windows machine and follow [Connect onboarding](CONNECT_ONBOARDING.md).

Shared setup lives in `.github/actions/` (`setup-flutter`, which uses `scripts/ci/setup-flutter-linux-arm64.sh` on Linux ARM64). Production deploys do not run on GitHub; they use the `scripts/prod-*.sh` scripts on the dev machine.

## Rules for changing workflows

Every action is pinned to a commit SHA with its version in a comment. Dependabot proposes updates weekly. Changes to `.github/` and `infra/` require the code owner's review.
