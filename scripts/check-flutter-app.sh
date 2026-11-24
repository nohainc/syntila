#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-}"
case "$APP" in
  connect_gui|profile_lab|app) ;;
  *) echo "Usage: check-flutter-app.sh connect_gui|profile_lab|app [--prepared]" >&2; exit 1 ;;
esac
shift
PREPARED=0
if [[ "${1:-}" == "--prepared" ]]; then PREPARED=1; shift; fi
[[ $# == 0 ]] || { echo "Unknown argument: $1" >&2; exit 1; }
cd "$ROOT/apps/$APP"
PUB=(flutter pub)
if [[ "$PREPARED" == 0 ]]; then
  "${PUB[@]}" get
  if [[ "$APP" == profile_lab ]]; then
    bash "$ROOT/scripts/internal/build-cli-worker-engine.sh"
  fi
else
  [[ -f .dart_tool/package_config.json ]] || { echo "Resolve dependencies first." >&2; exit 1; }
  if [[ "$APP" == profile_lab && ! -x assets/engines/syntila-agent ]]; then
    echo "Build the Engine before prepared app checks." >&2; exit 1
  fi
fi
FORMAT_PATHS=(lib test)
if [[ -d bin ]]; then FORMAT_PATHS+=(bin); fi
dart format --output=none --set-exit-if-changed "${FORMAT_PATHS[@]}"
flutter analyze
flutter test
