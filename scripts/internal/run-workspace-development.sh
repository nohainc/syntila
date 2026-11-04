#!/usr/bin/env bash
# Runs the Workspace service from Dart source against the local Cloud.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEV_DRAFT_ROOT="${SYNTILA_DEVELOPMENT_PROFILE_DIRECTORY:-}"
PUBLIC_ROOTS="${SYNTILA_RELEASE_TRUST_KEYS_JSON:-{}}"
# Same state directory a --local build (syntila-local) uses, so the
# local CLI can talk to this service. It is kept apart from production state.
LOCAL_STATE_ROOT="$HOME/Library/Application Support/Syntila Local/Workspace/State"
LEGACY_STATE_ROOT="$HOME/Library/Application Support/Syntila/Workspace/DevelopmentState"
if [[ -n "${SYNTILA_WORKSPACE_DEVELOPMENT_DATA_DIR:-}" ]]; then
  DEV_STATE_ROOT="$SYNTILA_WORKSPACE_DEVELOPMENT_DATA_DIR"
elif [[ -d "$LEGACY_STATE_ROOT" && ! -d "$LOCAL_STATE_ROOT" ]]; then
  DEV_STATE_ROOT="$LEGACY_STATE_ROOT"
  echo "Using legacy development state at $LEGACY_STATE_ROOT." >&2
  echo "Move it to $LOCAL_STATE_ROOT to share it with syntila-local." >&2
else
  DEV_STATE_ROOT="$LOCAL_STATE_ROOT"
fi
bash "$ROOT/scripts/internal/build-cli-worker-engine.sh"
cd "$ROOT/apps/workspace"
dart pub get
# Local builds are pinned to the local Cloud URL (http://localhost:8787).
exec dart run \
  "-DSYNTILA_WORKSPACE_ENVIRONMENT=local" \
  "-DSYNTILA_RELEASE_TRUST_KEYS_JSON=$PUBLIC_ROOTS" \
  "-DSYNTILA_DEVELOPMENT_PROFILE_DIRECTORY=$DEV_DRAFT_ROOT" \
  bin/syntila_workspace_service.dart --background-service \
  --data-dir "$DEV_STATE_ROOT" "$@"
