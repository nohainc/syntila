#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_CLOUD_URL="${SYNTILA_DEVELOPMENT_CLOUD_URL:-http://localhost:8787}"
bash "$ROOT/scripts/internal/build-cli-worker-engine.sh"
cd "$ROOT/apps/profile_lab"
exec flutter run -d macos --debug \
  --dart-define="SYNTILA_PROFILE_LAB_ENVIRONMENT=local" \
  --dart-define="SYNTILA_CLOUD_URL=$DEV_CLOUD_URL" "$@"
