# Step-by-step: bump the Workspace version and publish a Linux APT release

This is the operator checklist for shipping a new Linux Workspace version to the
public APT repository. Background, key custody and design rationale are in
[Linux release operations](WORKSPACE_LINUX_RELEASES.md); installation is in the
[Linux operator guide](../operations/WORKSPACE_LINUX.md).

## 0. Prerequisites (one-time)

- Write access to `nohainc/syntila`, and the `gh` CLI authenticated (`gh auth status`).
- Permission to approve the `workspace-linux-release` environment (it restricts
  deployments to `main`).
- Release configuration already present (see "Release configuration" in the
  release operations doc): `SYNTILA_RELEASE_TRUST_KEYS_JSON` repository variable,
  and `SYNTILA_APT_SIGNING_FINGERPRINT` / `SYNTILA_APT_PRIVATE_KEY` in the
  `workspace-linux-release` environment. Missing keys make the run fail closed.
- Optional, for local dry-run builds: Dart 3.8+, Node.js, Python 3, `dpkg`
  (`brew install dpkg` on macOS), GnuPG.

## 1. Choose the new version

The Workspace version is a single value: `version:` in `apps/workspace/pubspec.yaml`
(currently `1.0.14`). The release workflow reads it when no version input is given.

- Use semantic versioning `MAJOR.MINOR.PATCH` (e.g. `1.0.15`). The workflow rejects
  anything not matching `^[0-9]+\.[0-9]+\.[0-9]+([+~.-][A-Za-z0-9.+~-]+)?$`.
- **Every release needs a new, never-published version.** APT history is
  immutable: publishing different bytes under an existing version/architecture is
  rejected. If a release must be rebuilt, bump the version again.
- Check what is already published:

  ```bash
  git fetch --tags origin
  git tag --list 'workspace-linux-v*'
  curl -s https://nohainc.github.io/syntila/dists/stable/main/binary-amd64/Packages | grep -A1 '^Package: syntila$'
  ```

## 2. Bump the version

```bash
git switch main && git pull --ff-only
git switch -c release/workspace-1.0.15

# edit apps/workspace/pubspec.yaml -> version: 1.0.15
sed -i.bak 's/^version: .*/version: 1.0.15/' apps/workspace/pubspec.yaml && rm apps/workspace/pubspec.yaml.bak

git diff apps/workspace/pubspec.yaml   # confirm only the version line changed
```

Other apps (`apps/app`, `apps/workspace_gui`, `apps/profile_lab`) carry their
own independent versions and are **not** part of the Linux package version.
`SYNTILA_WORKSPACE_VERSION` can override the pubspec value at build time, but
prefer committing the bump so source and release agree.

## 3. Validate locally (optional but recommended)

```bash
cd apps/workspace
dart pub get --enforce-lockfile
dart analyze
dart test test/workspace_cli_test.dart test/workspace_headless_auth_test.dart \
  test/workspace_manager_service_test.dart test/linux_runtime_test.dart
cd ../..
python3 scripts/release/test-apt-repository.py    # needs dpkg + GnuPG
pnpm exec vitest run scripts/workspace-build-manifest.test.mjs
```

Optional local package build (cross-compile; proves compilation only):

```bash
export SYNTILA_RELEASE_TRUST_KEYS_JSON="$(gh variable get SYNTILA_RELEASE_TRUST_KEYS_JSON --repo nohainc/syntila)"
bash scripts/build-workspace-linux-headless.sh x64
bash scripts/package-workspace-linux.sh x64
# repeat with arm64; outputs in dist/syntila/deb/syntila_<version>_<amd64|arm64>.deb
```

Never promote locally built packages that contain CI fixture trust anchors; the
public release is always built by the workflow.

## 4. Merge the bump to `main`

```bash
git add apps/workspace/pubspec.yaml
git commit -m "Release Workspace 1.0.15"
git push -u origin release/workspace-1.0.15
gh pr create --repo nohainc/syntila --fill
```

Get review, wait for CI to pass, merge. Then confirm CI succeeded on the **exact
merge commit** on `main` — publishing requires a successful push-triggered CI run
for that commit (a PR run does not count):

```bash
git switch main && git pull --ff-only
gh run list --repo nohainc/syntila --workflow ci.yml --branch main --limit 3
```

Also, if this release advertises a new CLI feature that needs a Cloud endpoint
(e.g. headless `setup` needing `/api/desktop-auth/password`), deploy Cloud first.

## 5. Dry run: build and test without publishing

Dispatch the workflow from `main` with `publish=false` (the default):

```bash
gh workflow run release-linux.yml --repo nohainc/syntila --ref main -f version=1.0.15
gh run watch --repo nohainc/syntila   # pick the run
```

This runs on native Ubuntu x64 and ARM64: analyze + tests, APT repository
contract tests, build and package, a real APT install/upgrade test, and the
headless setup test. Candidates (`.deb` and `.tar.gz`) are kept as artifacts.
Nothing is published. Fix any failure, bump the version if code changed, and repeat.

## 6. Publish

```bash
gh workflow run release-linux.yml --repo nohainc/syntila --ref main \
  -f version=1.0.15 -f publish=true
```

Then:

1. Watch the run: `gh run watch --repo nohainc/syntila`.
2. When the `publish` job pauses for the `workspace-linux-release` environment,
   approve it in the GitHub Actions UI (if reviewers are required).
3. The pipeline then, without rebuilding: downloads the tested packages, imports the
   signing key into an ephemeral GnuPG dir, adds the packages to the
   `apt-repository` branch (fast-forward push), generates signed `InRelease`
   indexes, uploads the Pages artifact, and deploys to
   `https://nohainc.github.io/syntila/`.
4. `verify-public` jobs on fresh amd64 and ARM64 runners install from the public
   HTTPS repository, check the key fingerprint and signed metadata, start the
   service and check the version. **The release is not complete until both pass.**

If only the deploy step failed, re-run the failed jobs with the existing artifact.
Never rebuild different bytes under an already published version.

## 7. Verify as a user

On a clean Ubuntu/Debian machine (key fingerprint must be
`6EA013D12EF79CBDC34D66058182CCCFCF4175F2`):

```bash
APT_URL=https://nohainc.github.io/syntila
curl --fail --location "$APT_URL/syntila-archive-keyring.gpg" -o /tmp/syntila-archive-keyring.gpg
gpg --show-keys --with-fingerprint /tmp/syntila-archive-keyring.gpg
sudo install -D -m 644 /tmp/syntila-archive-keyring.gpg /etc/apt/keyrings/syntila-archive-keyring.gpg
printf 'Types: deb\nURIs: %s\nSuites: stable\nComponents: main\nSigned-By: /etc/apt/keyrings/syntila-archive-keyring.gpg\n' "$APT_URL" | sudo tee /etc/apt/sources.list.d/syntila.sources
sudo apt update
apt-cache policy syntila          # candidate should be 1.0.15
sudo apt install syntila          # or: sudo apt install --only-upgrade syntila
syntila --version
```

Existing installs upgrade with `sudo apt update && sudo apt upgrade`. The user
service is stopped/started around replacement; installation ID, registration,
Work Root, Profiles and sessions are preserved.

## 8. Tag and record

```bash
git tag workspace-linux-v1.0.15 <merge-commit-sha>
git push origin workspace-linux-v1.0.15
```

Add release notes or acceptance evidence as needed (see
[Linux package acceptance](../acceptance/WORKSPACE_LINUX_PACKAGES.md)).

## Rollback and troubleshooting

| Situation | Action |
| --- | --- |
| Bad release published | Old versions stay in the repository. Publish a **new higher** version containing the fix (APT picks the highest version). Users can pin the previous one: `sudo apt install syntila=1.0.14`. |
| "version already exists" / different bytes rejected | The version was published before. Bump to a new version. |
| Publish refused: CI not green | Wait for or fix push CI on the exact `main` commit; do not dispatch from a branch. |
| Missing keys/trust roots | Set the variables/secrets in "Release configuration"; the run fails closed by design. |
| Pages deploy or `verify-public` failed | Re-run failed jobs for the same run; do not rebuild under the same version. |
| Signing key rotation or loss | Follow [Release Trust and Rotation](../security/RELEASE_TRUST_AND_ROTATION.md). Never commit private keys. |
