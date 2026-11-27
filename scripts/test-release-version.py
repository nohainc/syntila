#!/usr/bin/env python3
"""Exercise the shared series tag and Git-derived revisions in isolated repositories."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    remote, repo = root / 'remote.git', root / 'repo'
    subprocess.run(['git', 'init', '--bare', '-q', '-b', 'main', str(remote)], check=True)
    repo.mkdir()
    for name in ('scripts/set-version.sh', 'scripts/release-version.mjs', 'release-versions/syntila'):
        target = repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)
    def run(*args, check=True, cwd=repo):
        return subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=check)
    run('git', 'init', '-q', '-b', 'main')
    run('git', 'config', 'user.name', 'Version test')
    run('git', 'config', 'user.email', 'version@example.test')
    run('git', 'config', 'commit.gpgsign', 'false')
    run('git', 'config', 'core.hooksPath', '/dev/null')
    run('git', 'add', '.')
    run('git', 'commit', '-qm', 'initial')
    run('git', 'remote', 'add', 'origin', str(remote))
    run('git', 'tag', 'connect-v0.2.2')
    run('git', 'push', '-qu', 'origin', 'main', '--tags')
    def version(check=True): return run('node', 'scripts/release-version.mjs', check=check)
    assert version(check=False).returncode != 0, 'missing series must fail'
    assert run('bash', 'scripts/set-version.sh', '0.2', check=False).returncode != 0
    assert run('bash', 'scripts/set-version.sh', '0.3.1', check=False).returncode != 0
    assert run('bash', 'scripts/set-version.sh', 'connect', '0.3', check=False).returncode != 0
    run('bash', 'scripts/set-version.sh', '0.3')
    assert run('git', 'cat-file', '-t', 'syntila-series-v0.3').stdout.strip() == 'tag'
    assert run('git', 'ls-remote', '--tags', 'origin', 'refs/tags/syntila-series-v0.3').stdout
    assert version().stdout.strip() == '0.3.0'
    (repo / 'change').write_text('one change')
    run('git', 'add', 'change'); run('git', 'commit', '-qm', 'change')
    assert version(check=False).returncode != 0, 'unpushed commit must fail'
    run('git', 'push', '-q', 'origin', 'main')
    assert version().stdout.strip() == '0.3.1'
    assert version().stdout.strip() == '0.3.1', 'every component must get the same version'
    (repo / 'change').write_text('dirty')
    assert version(check=False).returncode != 0
    assert run('bash', 'scripts/set-version.sh', '0.4', check=False).returncode != 0
    run('git', 'restore', 'change')
    assert run('bash', 'scripts/set-version.sh', '0.3', check=False).returncode != 0
    hook = remote / 'hooks/pre-receive'
    hook.write_text('#!/bin/sh\nexit 1\n')
    hook.chmod(0o755)
    result = run('bash', 'scripts/set-version.sh', '0.4', check=False)
    assert result.returncode != 0 and 'Atomic push failed' in result.stderr
    assert run('git', 'rev-parse', 'syntila-series-v0.4').returncode == 0
    assert not run('git', 'ls-remote', '--tags', 'origin', 'refs/tags/syntila-series-v0.4').stdout
    hook.unlink()
    run('git', 'tag', '-d', 'syntila-series-v0.4')
    run('git', 'reset', '--hard', 'origin/main')
    run('git', 'tag', 'connect-v0.3.1')
    run('git', 'tag', 'web-v0.3.1')
    assert version().stdout.strip() == '0.3.1', 'products may release the same commit'
    run('git', 'tag', '-d', 'connect-v0.3.1', 'web-v0.3.1')
    run('git', 'tag', 'connect-v0.3.2')
    assert version(check=False).returncode != 0, 'future release tag must fail closed'
    run('git', 'tag', '-d', 'connect-v0.3.2')
    run('git', 'tag', 'connect-v0.3.1', 'HEAD^')
    assert version(check=False).returncode != 0, 'same version on another commit must fail'
    run('git', 'tag', '-d', 'connect-v0.3.1')
    run('git', 'tag', '-a', 'syntila-series-v0.4', '-m', 'future series')
    assert version(check=False).returncode != 0, 'newer series must fail closed'
    run('git', 'tag', '-d', 'syntila-series-v0.4')
    sha = run('git', 'rev-parse', 'HEAD').stdout.strip()
    run('git', 'checkout', '-q', '--detach')
    assert version(check=False).returncode != 0, 'detached non-CI checkout must fail'
    ci_env = dict(os.environ, GITHUB_ACTIONS='true', GITHUB_REF='refs/heads/main', GITHUB_SHA=sha)
    ci = subprocess.run(['node', 'scripts/release-version.mjs'], cwd=repo, env=ci_env, capture_output=True, text=True)
    assert ci.returncode == 0 and ci.stdout.strip() == '0.3.1', ci.stderr
    run('git', 'checkout', '-q', 'main')
    shallow = root / 'shallow'
    run('git', 'clone', '-q', '--depth', '1', f'file://{remote}', str(shallow), cwd=root)
    assert run('node', 'scripts/release-version.mjs', check=False, cwd=shallow).returncode != 0
print('Shared release version checks passed')
