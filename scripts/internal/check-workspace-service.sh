#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKSPACE_DIR="$ROOT/apps/workspace"
DART=""
if command -v flutter >/dev/null 2>&1; then
  FLUTTER_BIN="$(dirname "$(command -v flutter)")"
  CACHED_DART="$FLUTTER_BIN/cache/dart-sdk/bin/dart"
  if [[ -x "$CACHED_DART" ]]; then DART="$CACHED_DART"; fi
fi
DART="${DART:-$(command -v dart || true)}"

if [[ -z "$DART" ]]; then
  echo "Dart SDK is required to check the Workspace Service." >&2
  exit 1
fi
if [[ ! -f "$WORKSPACE_DIR/.dart_tool/package_config.json" ]]; then
  echo "Workspace dependencies are not resolved; run dart pub get first." >&2
  exit 1
fi
if [[ ! -x "$WORKSPACE_DIR/assets/engines/syntila-agent" ]]; then
  echo "The generic CLI Worker Engine is missing; build it first." >&2
  exit 1
fi

# Unix-domain socket paths have a small platform limit; keep the smoke-test
# state under a short path even when macOS TMPDIR is deeply nested.
TEMP_ROOT="$(mktemp -d "/tmp/cws.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

cd "$WORKSPACE_DIR"
"$DART" compile exe \
  --packages="$WORKSPACE_DIR/.dart_tool/package_config.json" \
  bin/syntila_workspace_service.dart \
  -o "$TEMP_ROOT/workspace"
"$TEMP_ROOT/workspace" \
  --once \
  --data-dir "$TEMP_ROOT/data"

test -s "$TEMP_ROOT/data/installation-id"
echo "Workspace Service compiled, started headlessly, and stopped cleanly."
