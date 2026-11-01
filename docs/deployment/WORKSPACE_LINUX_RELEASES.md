# Linux Workspace APT releases

The headless install unit contains `workspace`, `syntila`, and
one canonical generic CLI Worker Engine. Provider CLIs are installed separately.
There is no Flutter desktop bundle; the headless install unit is the only Linux artifact.

## Production repository

The APT site is served by GitHub Pages at:

```text
https://nohainc.github.io/syntila/
```

The signing-key fingerprint is:

```text
6EA013D12EF79CBDC34D66058182CCCFCF4175F2
```

This dedicated OpenPGP key was created on 2026-10-26 and expires on 2028-10-25.
Its private backup and revocation certificate are outside the source checkout,
under `~/.config/syntila/release-keys` on the provisioning Mac (directory 0700,
private exports 0600). Keep an additional secured offline backup. Never commit
these files or upload private material as a build artifact.

The repository's `apt-repository` branch retains package data and old versions;
`main` retains source. The Pages artifact is an explicit whitelist of `pool`,
`dists`, the public key, the installation page and `.nojekyll`. Neither source
history nor signing material is copied into the site. No extra repository or
personal access token is needed: the publisher uses a job-scoped GITHUB_TOKEN
with contents write permission, and the official Pages deployment action uses
`pages: write` and an OIDC token. Both signing and Pages environments restrict
deployments to the `main` branch.

## Build from macOS or Linux

Dart 3.8+ supports cross-compiling Linux x64/arm64 executables. Install the Dart SDK,
Node.js, Python 3 and dpkg (`brew install dpkg` on macOS). Supply the production
public application-release trust roots, then:

```bash
export SYNTILA_RELEASE_TRUST_KEYS_JSON="$(gh variable get SYNTILA_RELEASE_TRUST_KEYS_JSON --repo nohainc/syntila)"
bash scripts/internal/build-workspace-linux-headless.sh x64
bash scripts/package-workspace-linux.sh x64
bash scripts/internal/build-workspace-linux-headless.sh arm64
bash scripts/package-workspace-linux.sh arm64
```

Outputs are under `dist/syntila`: `linux-<arch>`, headless
`.tar.gz` bundles, and `deb/syntila_<version>_<amd64|arm64>.deb`.
`SYNTILA_WORKSPACE_VERSION` overrides the pubspec version at compile/package
time; use a new version for every release. Build-only target inputs are
`SYNTILA_BUILD_TARGET_OS=linux` and `SYNTILA_BUILD_TARGET_ARCH=x64|arm64`.
Target Engine artifacts live under `dist/cli-worker-engine` and do not replace
native Workspace or Profile Lab assets. The canonical Engine script remains
the sole source of Engine builds. Packages set the build-time
`SYNTILA_WORKSPACE_PACKAGE_MANAGER=apt` so the application updater cannot compete
with APT. Never promote candidates containing CI fixture trust anchors.

Linux builds write a versioned build manifest with hashes of all three
executables and the relevant source tree. A new build invalidates any old
success marker before compiling. Packaging checks the manifest, version,
source digest and binary digests, refusing stale output after a failed build.
Run `pnpm exec vitest run scripts/workspace-build-manifest.test.mjs` to exercise
missing-manifest, mismatched-version and altered-binary rejection.

The headless email/password setup also requires the matching Cloud
`/api/desktop-auth/password` endpoint. Deploy that backward-compatible endpoint
before publishing a CLI that advertises `setup`. Browser approval remains
available for accounts requiring additional verification; runtime connection
and restarts never require a new password while the runtime credential remains
valid. No database migration is needed for this setup route.

Production builds require the genuine Workspace application-release public
roots even though APT manages this installation. The initial application key
`syntila/workspace-2026-10` was provisioned independently of the APT signing key;
no fixture key is trusted by production packages. Existing configured application
roots must be retained during later rotations, following the
[release trust contract](../security/RELEASE_TRUST_AND_ROTATION.md).

## Validation

Cross-compilation proves compilation, not Linux behavior. The Linux release
workflow builds and tests natively on Ubuntu 22.04 amd64 and ARM64. ARM64 CI
bootstraps the official stable Flutter source tag whose commit matches the
release manifest, since the archive action cannot resolve a Linux ARM64 SDK.
Other hosts use the existing SDK action; Pub cache keys include architecture.

The workflow analyzes Workspace and tests CLI/registration/IPC/Linux adapters.
It then signs a disposable test repository and performs actual APT installation,
upgrade, service IPC, Engine startup, SIGTERM shutdown and removal, checking that
installation identity, sessions and Work Root data survive. Repository contract
tests exercise real signing and publishing against a local bare git remote,
retain old versions and check that only package data is exported.

```bash
python3 scripts/release/test-apt-repository.py # dpkg and GnuPG required
# Linux only, on a disposable machine with sudo, after building a package:
bash scripts/test-workspace-linux-package.sh x64
```

After Pages deployment, separate fresh amd64 and ARM64 runners verify the
public key fingerprint, signed InRelease and actual HTTPS APT installation.
They start the installed service as a normal user, check health/version/APT
update ownership, execute the bundled Engine and stop gracefully. See
`scripts/test-workspace-public-apt.sh` and the workflow's `verify-public` jobs.
Earlier local qualification is retained in
[Linux package acceptance](../acceptance/WORKSPACE_LINUX_PACKAGES.md).

## Release configuration

| Scope | Name | Value |
| --- | --- | --- |
| Repository variable | `SYNTILA_RELEASE_TRUST_KEYS_JSON` | Production application-release public roots |
| `workspace-linux-release` environment variable | `SYNTILA_APT_SIGNING_FINGERPRINT` | Full OpenPGP signing fingerprint above |
| `workspace-linux-release` environment secret | `SYNTILA_APT_PRIVATE_KEY` | Armored signing private key for noninteractive GPG signing |
| `workspace-linux-release` environment variable | `SYNTILA_WORKSPACE_SIGNING_KEY_ID` | Initial independent application key ID: `workspace-2026-10` |
| `workspace-linux-release` environment secret | `SYNTILA_WORKSPACE_ED25519_SEED` | Application metadata key backup, separate from the APT key |

APT publishing uses only the OpenPGP secret. The application public root is a
compile-time input; its private seed is not used to sign APT metadata. Private
APT material is imported into an ephemeral `0700` GnuPG directory only after
successful builds/tests and removed after publishing. The key is available
noninteractively only in the main-restricted release environment.

## Publish and upgrade

Dispatch `Workspace / Linux / Release` from `main` with `publish=true`. The
workflow reads its immutable version from `apps/workspace/pubspec.yaml` on that
commit. Publication requires successful push-triggered repository CI for that
exact commit, followed by successful native package tests for both
architectures. The signing job downloads those tested packages without rebuilding
them, validates their exact version/architecture pair, adds them to the existing
package-data branch, generates signed indexes, and pushes a fast-forward commit.
It exports only the public site tree to the official Pages artifact action. The
next job deploys Pages, then both public-install acceptance jobs must pass.
Concurrent releases are serialized. Missing keys or roots fail closed.

For example:

```bash
gh workflow run release-linux.yml --repo nohainc/syntila --ref main -f publish=true
```

A non-publish run retains candidates as workflow artifacts. It uses configured
production roots when available, falling back to fixture roots only when no
production roots exist. Candidate testing alone does not publish anything.

Existing package versions and by-hash indexes are retained for rollback and
clients mid-update. Replacing an existing version/architecture with different
bytes is rejected. Retry failed deployment jobs with the existing artifact;
never rebuild different bytes under an already published version. If a rebuild
is required, increment the package version. The signed Release has a publication
date and no expiry during quiet release periods. Monitor Pages/repository size
and migrate static hosting before approaching its limits.

See the [Linux operator guide](../operations/WORKSPACE_LINUX.md) for installation.
APT upgrades require a user-service stop/start around package replacement; no
root maintainer script touches running users' assignments. Existing installation
IDs, registration, runtime credentials, Work Root, Profiles and sessions remain
in the original state directory. No data migration is introduced. An archive
install must stop/unregister its old user unit before registering the packaged
service; the manager refuses to silently change a unit pointing at another
executable. Reboot/linger, real provider assignments and production browser
approval still need target-host acceptance evidence.
