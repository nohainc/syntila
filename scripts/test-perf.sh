#!/usr/bin/env bash
# Short performance run (about 1-2 minutes) on the local stack, history in _perf/.
#   scripts/test-perf.sh [extra perf-local.sh flags, e.g. --no-thresholds]
# Needs `pnpm start:local`. Writes _perf/<date>-<shortcommit>.json, prints a comparison with the
# previous file (regressions above 25% marked) and refreshes docs/operations/PERFORMANCE_RESULTS.md.
# Exit code: perf-local.sh's (1 when a threshold is exceeded or a scenario had errors).
set -uo pipefail
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/_perf"
commit="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
out="$ROOT/_perf/$(date +%Y-%m-%dT%H%M%S)-$commit.json"

"$ROOT/scripts/perf-local.sh" --probes 20 --users 5 --messages 10 --chats 10 --json "$out" "$@"
status=$?

if [ -f "$out" ]; then
  echo
  bun "$ROOT/scripts/perf-report.mjs" --compare "$out"
  bun "$ROOT/scripts/perf-report.mjs" >/dev/null
fi
exit "$status"
