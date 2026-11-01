import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('prepare-workspace-github-release.py')


class PromotionTests(unittest.TestCase):
    def run_promotion(self, scenario):
        with tempfile.TemporaryDirectory() as temp:
            gh = Path(temp) / 'gh'
            gh.write_text('''#!/usr/bin/env python3
import json, os, sys
endpoint = sys.argv[2]
platform = {'1': 'linux', '2': 'macos', '3': 'windows'}
run_id = endpoint.split('/actions/runs/')[1].split('/')[0]
p = platform[run_id]
if '/jobs?' in endpoint:
    names = {'linux': ['verify-public (ubuntu-22.04)', 'verify-public (ubuntu-22.04-arm)'], 'macos': ['Syntila Workspace (signed and notarized)'], 'windows': ['Publish GitHub Release']}[p]
    if os.environ['SCENARIO'] == 'unpublished' and p == 'linux': names = []
    print(json.dumps({'jobs': [{'name': n, 'conclusion': 'success'} for n in names]}))
else:
    sha = ('b' if os.environ['SCENARIO'] == 'different_commit' and p == 'windows' else 'a') * 40
    print(json.dumps({'path': '.github/workflows/release-' + p + '.yml', 'status':'completed', 'conclusion':'success', 'event':'workflow_dispatch', 'head_branch':'main', 'head_sha':sha, 'html_url':'https://example.test'}))
''')
            gh.chmod(0o755)
            env = dict(os.environ, PATH=temp + os.pathsep + os.environ['PATH'],
                       GITHUB_REPOSITORY='example/repo', VERSION='1.2.3',
                       LINUX_RUN_ID='1', MACOS_RUN_ID='2', WINDOWS_RUN_ID='3', SCENARIO=scenario)
            return subprocess.run(['python3', str(SCRIPT)], env=env, cwd=temp, text=True, capture_output=True)

    def test_rejects_unpublished_linux_run(self):
        result = self.run_promotion('unpublished')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('did not publish', result.stderr)

    def test_rejects_different_commits(self):
        result = self.run_promotion('different_commit')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('same source commit', result.stderr)


if __name__ == '__main__':
    unittest.main()
