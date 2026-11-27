#!/usr/bin/env python3
"""Exercise version updates and commit isolation in a disposable repository."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
files = [
    'apps/connect/pubspec.yaml', 'apps/connect_gui/pubspec.yaml',
    'apps/connect/lib/src/cli.dart', 'apps/connect/lib/src/connection.dart',
    'apps/connect/lib/src/runtime.dart',
]
with tempfile.TemporaryDirectory() as temp:
    repo = Path(temp)
    for name in [*files, 'scripts/set-connect-version.sh']:
        target = repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, target)
    def run(*args, check=True):
        return subprocess.run(args, cwd=repo, capture_output=True, text=True, check=check)
    run('git', 'init', '-q')
    run('git', 'config', 'user.name', 'Version test')
    run('git', 'config', 'user.email', 'version@example.test')
    run('git', 'config', 'commit.gpgsign', 'false')
    run('git', 'add', '.')
    run('git', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'initial')
    (repo / 'unrelated').write_text('keep staged')
    run('git', 'add', 'unrelated')
    script = str(repo / 'scripts/set-connect-version.sh')
    result = run('bash', script, '3.4.5')
    assert result.returncode == 0
    assert run('git', 'log', '-1', '--format=%s').stdout.strip() == 'Bump Connect version to 3.4.5'
    assert set(run('git', 'diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD').stdout.splitlines()) == set(files)
    assert run('git', 'diff', '--cached', '--name-only').stdout.strip() == 'unrelated'
    assert all('3.4.5' in (repo / name).read_text() for name in files)
    commit = run('git', 'rev-parse', 'HEAD').stdout
    assert run('bash', script, '3.4.5').returncode == 0
    assert run('git', 'rev-parse', 'HEAD').stdout == commit
    assert run('bash', script, '3.4.5;echo bad', check=False).returncode != 0
    with (repo / files[0]).open('a') as f:
        f.write('# user edit\n')
    before = (repo / files[0]).read_text()
    assert run('bash', script, '3.4.6', check=False).returncode != 0
    assert (repo / files[0]).read_text() == before
    assert run('git', 'rev-parse', 'HEAD').stdout == commit
    run('git', 'restore', '--', files[0])
    target = repo / files[4]
    target.write_text(target.read_text().replace("String clientVersion = '3.4.5',", "String clientVersion = 'unexpected',"))
    run('git', 'add', files[4])
    run('git', '-c', 'core.hooksPath=/dev/null', 'commit', '--only', '-qm', 'change fixture', '--', files[4])
    snapshots = [(repo / name).read_text() for name in files]
    assert run('bash', script, '3.4.6', check=False).returncode != 0
    assert [(repo / name).read_text() for name in files] == snapshots
print('Connect version update and commit checks passed')
