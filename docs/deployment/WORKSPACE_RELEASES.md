# Workspace, Engine, and Worker Profile Releases

Workspace application releases use the Cloud API under `/api/workspace-releases`. Architecture v8 has three release classes:

1. **Workspace:** the signed `syntila` service/CLI bundle (macOS: signed and notarized zip/pkg; Linux: signed APT package; Windows: Authenticode-signed installer).
2. **CLI Worker Engine:** generic executable bundled with a Workspace release; it has no separate Cloud release catalog.
3. **Worker Profile:** one current provider integration payload per logical Worker, published through Cloud with digest and revision validation.

Provider CLI software is installed and updated by its provider.

## Worker Profile publication flow

~~~text
edit local candidate
-> schema/security validation and fixture tests
-> atomic Cloud publication with expected revision and digest
-> Workspace refresh and activation
~~~

Cloud stores the canonical Profile digest, revision, actor, and bounded history. Workspace validates the digest, identity, schema, and Engine compatibility before caching and activation. Restoring a prior snapshot publishes it as a new current revision; there are no Profile channels.

Real acceptance evidence is produced by [the Profile acceptance suite](../../apps/workspace/test/tool_profile_real_acceptance_test.dart). It covers passive/live probes, a Thread write, durable session start/resume, timeout, and process-tree cancellation. Stable promotion requires evidence for the immutable release digest. The current release gates are listed in the [v8 implementation roadmap](../roadmaps/ARCHITECTURE_V8_IMPLEMENTATION.md#release-gates).

## Workspace and Engine releases

Each Workspace release contains one platform-specific CLI Worker Engine build. Workspace verifies the bundled executable and checks its identity during Local Worker Protocol initialization. Updating or rolling back the Engine means updating or restoring the complete signed Workspace release.

Use the manually dispatched [Workspace macOS release workflow](../../.github/workflows/release-macos.yml) to build, sign, notarize, publish, download, and verify a macOS release. The workflow uses Workspace signing credentials and public trust roots.

Dispatch it from `main`. Before accessing release credentials or building, the
workflow requires a successful push-triggered repository CI run for the exact
selected commit. A passing run for another revision or a pull request does not
authorize the release.

The Workspace app does not yet perform a complete automatic update transaction with active-work drain, staging, restart, health check, and rollback. Until that passes end-to-end acceptance, install a downloaded and verified notarized archive manually while Workspace is stopped.

## Trust and incident operations

Use [Release Trust and Rotation](../security/RELEASE_TRUST_AND_ROTATION.md) for key separation, overlap rotation, revocation, and recovery constraints. Never store release signing seeds or publication tokens in the repository, package archives, desktop artifacts, or workflow output.

## Headless Linux packages

The service, management CLI and bundled Engine can be cross-compiled from macOS
and distributed as one Debian package through a signed vendor APT repository.
See [Linux release operations](WORKSPACE_LINUX_RELEASES.md) for build commands,
protected signing/publication setup, native package tests and update operations.
APT manages this install unit; its separate application self-updater is disabled.

## Windows installer

The Windows bundle and Inno Setup installer are Authenticode-signed and
published as GitHub Releases. See [Windows release operations](WORKSPACE_WINDOWS_RELEASES.md)
for signing identity setup, required secrets, the release procedure and
device qualification.

## GitHub Release promotion

After the Linux APT, macOS Workspace and Windows release workflows have each
published the **same version from the same main commit**, run
`promote-workspace-release.yml` on `main`. Supply the version and the three
workflow run IDs. First leave `publish` false and inspect the retained
`workspace-github-release-<version>` artifact. Run it again with `publish=true`
to create the `workspace-v<version>` GitHub Release. It includes Linux x64 and
arm64 packages and archives, the macOS archive, the Windows x64 installer and
archive, checksums, and source/run provenance. Workflow artifacts must still be
available; the macOS workflow must have retained its archive using the current
workflow. The promotion validates the published runs and reuses their bytes.

APT publication is handled by `release-linux.yml`. GitHub Releases alone does
not publish to Homebrew or WinGet: those require a Homebrew tap/cask and a
WinGet package manifest submitted to the community repository, respectively.
No Homebrew or WinGet publishing automation is configured here yet.
