#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKSPACE_DIR="$ROOT/apps/workspace"
SERVICE_DIR="$ROOT/dist/syntila"
SERVICE_NAME="syntila"
ENGINE_NAME="syntila-agent"

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
  SERVICE_NAME="syntila.exe"
  ENGINE_NAME="syntila-agent.exe"
fi

SOURCE_MODE="0"
case "${1:-}" in
  --source)
    SOURCE_MODE="1"
    shift
    ;;
  --help|-h)
    cat <<'USAGE'
Usage: scripts/internal/run-workspace-service.sh [--source] [service options]

Starts the compiled Workspace Service by default. Build it first with:
  scripts/internal/build-workspace-service.sh

Use --source only for Dart source debugging; that mode displays as dart: in
process tools because it is launched through the Dart VM.
USAGE
    exit 0
    ;;
esac

if [[ "$SOURCE_MODE" == "0" ]]; then
  SERVICE="$SERVICE_DIR/$SERVICE_NAME"
  ENGINE="$SERVICE_DIR/assets/engines/$ENGINE_NAME"
  if [[ ! -x "$SERVICE" || ! -x "$ENGINE" ]]; then
    echo "The compiled Workspace Service is missing." >&2
    echo "Run scripts/internal/build-workspace-service.sh first, or use --source for source debugging." >&2
    exit 1
  fi
  # Persisted registration and secure storage remain authoritative. Explicit
  # arguments are still available for isolated development/test installations.
  exec "$SERVICE" --background-service "$@"
fi

if [[ ! -f "$WORKSPACE_DIR/.dart_tool/package_config.json" ]]; then
  echo "Workspace dependencies are not resolved. Run dart pub get in apps/workspace first." >&2
  exit 1
fi

ENGINE="$WORKSPACE_DIR/assets/engines/syntila-agent"
if [[ ! -x "$ENGINE" ]]; then
  echo "The bundled CLI Worker Engine is missing. Run scripts/internal/build-cli-worker-engine.sh first." >&2
  exit 1
fi

DART=""
if command -v flutter >/dev/null 2>&1; then
  FLUTTER_BIN="$(dirname "$(command -v flutter)")"
  CACHED_DART="$FLUTTER_BIN/cache/dart-sdk/bin/dart"
  if [[ -x "$CACHED_DART" ]]; then DART="$CACHED_DART"; fi
fi
DART="${DART:-$(command -v dart || true)}"
[[ -n "$DART" ]] || {
  echo "Dart SDK is required to run the Workspace Service." >&2
  exit 1
}

cd "$WORKSPACE_DIR"
exec "$DART" run \
  "-DSYNTILA_WORKSPACE_ENVIRONMENT=${SYNTILA_WORKSPACE_ENVIRONMENT:-production}" \
  bin/syntila_workspace_service.dart --background-service "$@"
