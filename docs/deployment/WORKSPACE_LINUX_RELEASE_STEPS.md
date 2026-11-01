# Release the Linux Workspace to APT (quick steps)

Short checklist. Background, keys and design: [Linux release operations](WORKSPACE_LINUX_RELEASES.md).
Install instructions: [Linux operator guide](../operations/WORKSPACE_LINUX.md).

Requirements: write access to `nohainc/syntila`, `gh` logged in, and approval
rights for the `workspace-linux-release` environment.

## 1. Push dependencies first

The CLI (`apps/workspace`) and the GUI (`apps/workspace_gui`) take the
`gui-manifest` SDK from GitHub at the commit pinned in their `pubspec.yaml` /
`pubspec.lock`. A release only contains what those pins point to.

If `gui-manifest` changed:

```bash
git -C gui-manifest push origin main
# set the new commit as `ref:` in apps/workspace/pubspec.yaml, then:
cd apps/workspace && dart pub get && dart analyze && cd ../..
# update the commit in apps/workspace_gui/pubspec.lock (flutter pub upgrade gui_manifest_flutter)
```

## 2. Bump the version

Edit `version:` in `apps/workspace/pubspec.yaml` (e.g. `1.0.17`). It must be a
new, never-published version; APT rejects different bytes under an old one.

## 3. Commit and push to `main`

```bash
git add -A && git commit -m "Release Workspace 1.0.17" && git push origin main
gh run list --workflow ci.yml --branch main --limit 1   # wait until it succeeds
```

Publishing requires a green CI run on this exact commit.

## 4. Dry run (builds and tests, publishes nothing)

```bash
gh workflow run release-linux.yml --ref main
gh run watch
```

Fix failures and bump the version again if code changed.

## 5. Publish

```bash
gh workflow run release-linux.yml --ref main -f publish=true
gh run watch
```

Approve the `workspace-linux-release` environment if asked. The run signs the
repository, deploys it to `https://nohainc.github.io/syntila/`, and then checks
a public install on amd64 and arm64. The release is done when `verify-public` passes.

## 6. Check on Linux

```bash
sudo apt update && sudo apt install --only-upgrade syntila
syntila --version      # expect 1.0.17; also check the output looks new
```

First-time install and key fingerprint check: see the operator guide.

## 7. Tag (optional)

```bash
git tag workspace-linux-v1.0.17 && git push origin workspace-linux-v1.0.17
```

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Version is new but CLI/GUI output is old | Check the executable path and restart the user service; see [output diagnostics](../operations/WORKSPACE_LINUX.md#diagnose-old-output-after-an-upgrade). Also check dependency pins (step 1). |
| "version already exists" | Bump to a new version. |
| Publish refused | CI is not green on that `main` commit. |
| Deploy or `verify-public` failed | Re-run failed jobs; never rebuild bytes under a published version. |
| Bad release | Publish a higher fixed version, or pin: `sudo apt install syntila=1.0.14`. |
