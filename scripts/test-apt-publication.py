#!/usr/bin/env python3
"""Exercise the live APT verification without contacting or changing Pages."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
paths = [
    'dists/stable/Release', 'dists/stable/InRelease',
    'dists/stable/main/binary-amd64/Packages',
    'dists/stable/main/binary-arm64/Packages',
    'pool/main/s/syntila-connect/syntila-connect_0.2.0_amd64.deb',
    'pool/main/s/syntila-connect/syntila-connect_0.2.0_arm64.deb',
]
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    local, remote, bin_dir = (tmp / name for name in ('local', 'remote', 'bin'))
    bin_dir.mkdir()
    for base in (local, remote):
        for path in paths:
            target = base / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(path)
    curl = bin_dir / 'curl'
    curl.write_text('#!/bin/bash\nfor arg in "$@"; do url="$arg"; done\ncat "$FAKE_REMOTE/${url#"$FAKE_BASE"/}"\n')
    curl.chmod(0o755)
    sleep = bin_dir / 'sleep'
    sleep.write_text('#!/bin/sh\nexit 0\n')
    sleep.chmod(0o755)
    env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', FAKE_REMOTE=str(remote), FAKE_BASE='https://example.invalid')
    command = ['bash', '-o', 'pipefail', '-c',
               'source scripts/internal/verify-apt-publication.sh; verify_apt_publication https://example.invalid "$1" 0.2.0',
               '_', str(local)]
    def run():
        return subprocess.run(command, cwd=root, env=env, capture_output=True, text=True)
    assert run().returncode == 0, 'matching public repository should pass'
    (remote / paths[2]).write_text('stale index')
    assert run().returncode != 0, 'stale public index must fail'
    shutil.copyfile(local / paths[2], remote / paths[2])
    (remote / paths[4]).write_text('wrong package')
    assert run().returncode != 0, 'wrong public package must fail'
    (remote / paths[4]).unlink()
    assert run().returncode != 0, 'missing public package must fail'
    shutil.copyfile(local / paths[4], remote / paths[4])

    # Exercise the publisher's Pages switch and preflight with isolated stubs.
    sandbox = tmp / 'publisher'
    (sandbox / 'scripts/internal').mkdir(parents=True)
    (sandbox / 'packaging/linux').mkdir(parents=True)
    (sandbox / 'dist/connect/release/linux').mkdir(parents=True)
    for path in ('scripts/prod-publish-connect-linux.sh', 'scripts/internal/verify-apt-publication.sh',
                 'packaging/linux/apt-index.html'):
        shutil.copyfile(root / path, sandbox / path)
    (sandbox / 'scripts/prod-lib.sh').write_text('''
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONNECT_RELEASE_DIR="$ROOT/dist/connect/release"
parse_flags() { DRY_RUN=0; [ "${1:-}" != --dry-run ] || DRY_RUN=1; }
require() { :; }
connect_version() { echo 0.2.0; }
git_state() { echo test; }
require_clean_main() { :; }
check_connect_build() { :; }
say() { :; }
confirm() { :; }
die() { echo "$*" >&2; exit 1; }
''')
    stubs = {
        'git': '''#!/bin/bash
echo "git $*" >> "$FAKE_LOG"
case "$*" in
  *'remote get-url origin'*) echo https://github.com/test/repo.git;;
  'clone '*) for arg in "$@"; do target="$arg"; done; mkdir -p "$target"; cp -R "$FAKE_REMOTE/." "$target/";;
  'diff --cached --quiet') exit 1;;
esac
''',
        'gh': '''#!/bin/bash
echo "gh $*" >> "$FAKE_LOG"
if [ "$1" = api ] && [ "$2" != -X ]; then
  [ "$FAKE_PAGES" != fail ] || exit 1
  [ "$FAKE_PAGES" != update-fail ] || { echo 'workflow main /'; exit 0; }
  echo "$FAKE_PAGES"
fi
[ "$FAKE_PAGES" != update-fail ] || exit 1
''',
        'gpg': '#!/bin/sh\nexit 0\n',
        'gpgconf': '#!/bin/sh\nexit 0\n',
        'python3': '#!/bin/sh\nexit 0\n',
    }
    for name, content in stubs.items():
        target = bin_dir / name
        target.write_text(content)
        target.chmod(0o755)
    log = tmp / 'calls.log'
    env.update(FAKE_LOG=str(log), HOME=str(tmp / 'home'), FAKE_BASE='https://test.github.io/repo')
    def publish(pages, *args):
        log.write_text('')
        env['FAKE_PAGES'] = pages
        result = subprocess.run(['bash', str(sandbox / 'scripts/prod-publish-connect-linux.sh'), *args],
                                env=env, capture_output=True, text=True)
        return result, log.read_text()
    result, calls = publish('workflow main /')
    assert result.returncode == 0, result.stderr
    assert 'git push origin HEAD:apt-repository' in calls
    assert "gh api -X PUT repos/test/repo/pages" in calls
    result, calls = publish('legacy apt-repository /')
    assert result.returncode == 0, result.stderr
    assert 'gh api -X PUT' not in calls
    result, calls = publish('fail')
    assert result.returncode != 0 and 'git push origin' not in calls
    result, calls = publish('update-fail')
    assert result.returncode != 0 and 'git push origin' in calls
    result, calls = publish('workflow main /', '--dry-run')
    assert result.returncode == 0 and 'git push origin' not in calls and 'gh api -X PUT' not in calls
print('APT publication verification checks passed')
