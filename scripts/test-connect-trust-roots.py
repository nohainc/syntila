#!/usr/bin/env python3
"""Check the trust-root inputs accepted by Connect release builds."""
import json
import os
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
for value, expected in [
    ({"release-key": key}, {"release-key": key}),
    ({"syntila": {"release-key": key}}, None),
    ({"syntila": {"release-key": "AA=="}}, None),
    ({}, None),
    ({"bad key": key}, None),
    ({"release-key": "A" * 43}, {"release-key": "A" * 43}),
    ({"release-key": "A" * 42 + "B"}, None),
]:
    env = dict(os.environ, SYNTILA_PROFILE_TRUST_ROOTS=json.dumps(value), PROD_ENV_FILE="/dev/null")
    result = subprocess.run(
        ["bash", "-c", "source scripts/prod-lib.sh; connect_trust_roots"],
        cwd=root, env=env, capture_output=True, text=True,
    )
    if expected is None:
        assert result.returncode != 0, value
    else:
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == expected
print("Connect trust-root input checks passed")
