#!/usr/bin/env bash
# Set the Connect release version in the CLI and desktop app metadata.
# Usage: scripts/set-connect-version.sh MAJOR.MINOR.PATCH
set -euo pipefail

if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/set-connect-version.sh MAJOR.MINOR.PATCH" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
files=(apps/connect/pubspec.yaml apps/connect_gui/pubspec.yaml
       apps/connect/lib/src/cli.dart apps/connect/lib/src/connection.dart
       apps/connect/lib/src/runtime.dart)
status=$(git status --porcelain -- "${files[@]}")
if [ -n "$status" ]; then
  echo "Connect version files have existing changes; commit or save them before running this script." >&2
  exit 1
fi
python3 - "$root" "$1" <<'PY'
import os
from pathlib import Path
import re
import sys
import tempfile

root, version = Path(sys.argv[1]), sys.argv[2]
targets = [
    ('apps/connect/pubspec.yaml', r'^(version: )\d+\.\d+\.\d+[ \t]*$'),
    ('apps/connect_gui/pubspec.yaml', r'^(version: )\d+\.\d+\.\d+[ \t]*$'),
    ('apps/connect/lib/src/cli.dart', r"^(const agentVersion = ')\d+\.\d+\.\d+(';)$"),
    ('apps/connect/lib/src/connection.dart', r"^([ \t]*this\.clientVersion = ')\d+\.\d+\.\d+(',)$"),
    ('apps/connect/lib/src/runtime.dart', r"^([ \t]*String clientVersion = ')\d+\.\d+\.\d+(',)$"),
]

# Validate every target before writing any file, so an unexpected source layout
# cannot silently produce a release with mismatched versions.
updates = []
try:
    for name, pattern in targets:
        path = root / name
        text = path.read_text(encoding='utf-8')
        regex = re.compile(pattern, re.MULTILINE)
        matches = list(regex.finditer(text))
        if len(matches) != 1:
            raise ValueError(f'{name}: expected exactly one version declaration, found {len(matches)}')
        updated = regex.sub(lambda m: m.group(1) + version + (m.group(2) if m.lastindex == 2 else ''), text)
        updates.append((path, updated))
    for path, updated in updates:
        mode = path.stat().st_mode
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as f:
            name = f.name
            try:
                f.write(updated)
                f.flush()
                os.fchmod(f.fileno(), mode & 0o777)
            except BaseException:
                os.unlink(name)
                raise
        os.replace(name, path)
except (OSError, ValueError) as error:
    print(f'Could not set Connect version: {error}', file=sys.stderr)
    sys.exit(1)
print(f'Set Connect version to {version}.')
PY

if git diff --quiet -- "${files[@]}"; then
  echo "Connect is already at $1; no commit created."
  exit 0
fi
if ! git commit --only -m "Bump Connect version to $1" -- "${files[@]}"; then
  echo "Commit failed; the version edits remain in the working tree." >&2
  exit 1
fi
