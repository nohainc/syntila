#!/usr/bin/env python3
"""Collect already-published, tested Workspace artifacts without rebuilding."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def gh_json(endpoint):
    return json.loads(command('gh', 'api', endpoint))


def main():
    repo = os.environ['GITHUB_REPOSITORY']
    version = os.environ['VERSION']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Version must be X.Y.Z')
    runs = {}
    for platform in ('linux', 'macos', 'windows'):
        run_id = os.environ[platform.upper() + '_RUN_ID']
        if not re.fullmatch(r'[0-9]+', run_id):
            raise ValueError(f'Invalid {platform} run ID')
        run = gh_json(f'repos/{repo}/actions/runs/{run_id}')
        if (run['path'] != f'.github/workflows/release-{platform}.yml' or
                run['status'] != 'completed' or run['conclusion'] != 'success' or
                run['event'] != 'workflow_dispatch' or run['head_branch'] != 'main'):
            raise ValueError(f'{platform} run is not a successful manual release from main')
        jobs = gh_json(f'repos/{repo}/actions/runs/{run_id}/jobs?per_page=100')['jobs']
        names = [j['name'] for j in jobs if j['conclusion'] == 'success']
        if platform == 'linux' and len([n for n in names if n.startswith('verify-public (')]) != 2:
            raise ValueError('Linux run did not publish and verify both architectures')
        if platform == 'macos' and 'Syntila Workspace (signed and notarized)' not in names:
            raise ValueError('macOS Workspace publishing job did not succeed')
        if platform == 'windows' and 'Publish GitHub Release' not in names:
            raise ValueError('Windows run did not publish')
        runs[platform] = (run_id, run)
    shas = {run['head_sha'] for _, run in runs.values()}
    if len(shas) != 1:
        raise ValueError('Release runs must use the same source commit')
    sha = shas.pop()
    if not re.fullmatch(r'[a-f0-9]{40}', sha):
        raise ValueError('Invalid source commit')
    status = gh_json(f'repos/{repo}/compare/{sha}...main')['status']
    if status not in ('identical', 'ahead'):
        raise ValueError('Source commit is not on main')
    # The promotion workflow obtains the version from its checked-out pubspec.
    # Verify it directly at the source commit of the published artifacts too.
    pubspec = command('gh', 'api', f'repos/{repo}/contents/apps/workspace/pubspec.yaml?ref={sha}', '-H', 'Accept: application/vnd.github.raw+json')
    match = re.search(r'^version:\s*([^\s+]+)', pubspec, re.MULTILINE)
    if not match or match.group(1) != version:
        raise ValueError('Source version does not match the published release commit')
    root = Path('workspace-promotion')
    if root.exists():
        shutil.rmtree(root)
    root.mkdir()
    output = root / 'release'
    output.mkdir()
    def download(platform, artifact):
        dest = root / artifact
        subprocess.run(['gh', 'run', 'download', runs[platform][0], '--repo', repo, '--name', artifact, '--dir', str(dest)], check=True)
        return dest
    def copy_unique(source, name):
        matches = list(source.rglob(name))
        if len(matches) != 1 or not matches[0].is_file():
            raise ValueError(f'Expected exactly one {name} in {source}')
        target = output / name
        if target.exists():
            raise ValueError(f'Duplicate asset {name}')
        shutil.copyfile(matches[0], target)
        return target
    for arch, debarch in (('x64', 'amd64'), ('arm64', 'arm64')):
        source = download('linux', f'linux-workspace-{arch}')
        for package in ('syntila', 'syntila-gui'):
            name = f'{package}_{version}_{debarch}.deb'
            path = copy_unique(source, name)
            for field, expected in (('Package', package), ('Version', version), ('Architecture', debarch)):
                if command('dpkg-deb', '--field', str(path), field) != expected:
                    raise ValueError(f'{name}: unexpected {field}')
        for kind in ('headless-', ''):
            copy_unique(source, f'syntila-workspace-{kind}linux-{arch}.tar.gz')
    copy_unique(download('macos', 'syntila-workspace-macos-release'), f'Syntila-Workspace-{version}-macos.zip')
    win = download('windows', 'syntila-workspace-windows-x64-release')
    checksums = {}
    for line in (win / 'SHA256SUMS').read_text().splitlines():
        match = re.fullmatch(r'([a-fA-F0-9]{64})\s+\*?([^/\\]+)', line)
        if not match or match.group(2) in checksums:
            raise ValueError('Invalid Windows checksums')
        checksums[match.group(2)] = match.group(1).lower()
    for name in (f'Syntila-Workspace-{version}-windows-x64.zip', f'Syntila-Workspace-{version}-windows-x64-Setup.exe'):
        path = copy_unique(win, name)
        if checksums.get(name) != hashlib.sha256(path.read_bytes()).hexdigest():
            raise ValueError(f'Windows checksum mismatch: {name}')
    manifest = {'version': version, 'source_commit': sha,
                'runs': {p: {'id': rid, 'url': run['html_url']} for p, (rid, run) in runs.items()}}
    (output / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (output / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(output.iterdir()) if p.is_file()))
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as f:
            f.write(f'source_sha={sha}\n')
    print(f'Prepared {len(list(output.iterdir()))} assets for {version} from {sha}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        print(f'Promotion failed: {exc}', file=sys.stderr)
        sys.exit(1)
