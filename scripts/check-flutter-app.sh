#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-}"
case "$APP" in
  workspace|workspace_gui|profile_lab|app) ;;
  *) echo "Usage: check-flutter-app.sh workspace|workspace_gui|profile_lab|app [--prepared]" >&2; exit 1 ;;
esac
shift
PREPARED=0
if [[ "${1:-}" == "--prepared" ]]; then PREPARED=1; shift; fi
[[ $# == 0 ]] || { echo "Unknown argument: $1" >&2; exit 1; }
cd "$ROOT/apps/$APP"
# The Workspace is a pure Dart service/CLI (no Flutter SDK dependency).
if [[ "$APP" == workspace ]]; then PUB=(dart pub); else PUB=(flutter pub); fi
if [[ "$PREPARED" == 0 ]]; then
  "${PUB[@]}" get
  if [[ "$APP" != app && "$APP" != workspace_gui ]]; then
    bash "$ROOT/scripts/build-cli-worker-engine.sh"
  fi
else
  [[ -f .dart_tool/package_config.json ]] || { echo "Resolve dependencies first." >&2; exit 1; }
  if [[ "$APP" != app && "$APP" != workspace_gui && ! -x assets/engines/syntila-agent ]]; then
    echo "Build the Engine before prepared app checks." >&2; exit 1
  fi
fi
FORMAT_PATHS=(lib test)
if [[ -d bin ]]; then FORMAT_PATHS+=(bin); fi
dart format --output=none --set-exit-if-changed "${FORMAT_PATHS[@]}"
if [[ "$APP" == workspace ]]; then
  dart analyze
  DART_EXECUTABLE="$(command -v dart)" dart test --concurrency=1
  bash "$ROOT/scripts/check-workspace-service.sh"
elif [[ "$APP" == workspace_gui ]]; then
  flutter analyze
  # Also drive the real CLI: build it and point the smoke test at it.
  CLI_BIN="$(mktemp -d)/syntila"
  (cd "$ROOT/apps/workspace" && dart pub get && dart compile exe bin/syntila_workspace_cli.dart -o "$CLI_BIN")
  SYNTILA_CLI="$CLI_BIN" flutter test
else
  flutter analyze
  flutter test
fi
