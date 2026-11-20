#!/usr/bin/env bash
# Runs the Worker Agent CLI from source against a local data directory, so a
# development Worker never touches an installed one.
#   scripts/run-worker-agent.sh install --pairing-code CODE --no-service
#   scripts/run-worker-agent.sh run
#   scripts/run-worker-agent.sh status
#   scripts/run-worker-agent.sh permissions add-folder ~/work --write
# Any command of `syntila-worker help` works. Data goes to .development/worker-agent
# (override with SYNTILA_WORKER_DATA_DIR). The backend started by
# scripts/start-local-backend.sh has the Worker flags on by default.
set -euo pipefail
export PATH="$HOME/development/flutter/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SYNTILA_WORKER_DATA_DIR="${SYNTILA_WORKER_DATA_DIR:-$ROOT/.development/worker-agent}"
mkdir -p "$SYNTILA_WORKER_DATA_DIR"
node "$ROOT/scripts/setup-local-profile-signing.mjs"
PROFILE_TRUST_ROOTS="$(cat "$ROOT/.development/local-profile-signing/trust-roots.json")"
cd "$ROOT/apps/worker_agent"
dart pub get >/dev/null
exec dart --define="SYNTILA_PROFILE_TRUST_ROOTS=$PROFILE_TRUST_ROOTS" run bin/syntila_worker.dart "$@"
