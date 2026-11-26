#!/usr/bin/env bash
# Short performance run (about 1-2 minutes) on the local stack, history in _perf/.
#   scripts/test-perf.sh [extra perf-local.sh flags, e.g. --no-thresholds]
# Needs `pnpm start:local`. Writes _perf/<date>-<shortcommit>.json and checks configured limits.
# Exit code: perf-local.sh's (1 when a threshold is exceeded or a scenario had errors).
set -uo pipefail
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/_perf"
commit="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
out="$ROOT/_perf/$(date +%Y-%m-%dT%H%M%S)-$commit.json"

"$ROOT/scripts/perf-local.sh" --chats 1 --json "$out" "$@"
status=$?

exit "$status"
