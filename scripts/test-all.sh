#!/usr/bin/env bash
# Every check that gates a commit, with a one-line verdict per step.
#   scripts/test-all.sh            full run (about 4 minutes)
#   scripts/test-all.sh --quick    typecheck + backend suite only
#   scripts/test-all.sh --perf     add scripts/test-perf.sh as the last step (needs pnpm start:local; never default)
# Full output of each step: $TEST_LOG_DIR (default /tmp/syntila-tests). Exit code 1 if any step failed.
set -uo pipefail
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGS="${TEST_LOG_DIR:-/tmp/syntila-tests}"
mkdir -p "$LOGS"
quick=0; perf=0
for a in "$@"; do case "$a" in --quick) quick=1;; --perf) perf=1;; esac; done
failed=0

step() { # name, command...
  local name="$1"; shift
  local log="$LOGS/$name.log" t0=$SECONDS
  if "$@" >"$log" 2>&1; then
    printf 'ok    %-14s %3ss\n' "$name" $((SECONDS - t0))
  else
    printf 'FAIL  %-14s %3ss  (see %s)\n' "$name" $((SECONDS - t0)) "$log"
    tail -15 "$log" | sed 's/^/        /'
    failed=1
  fi
}

in_backend() { ( cd "$ROOT/apps/backend" && "$@" ); }
write_paths() {
  cp "$ROOT/docs/backend/WRITE_PATHS.md" "$LOGS/WRITE_PATHS.before"
  in_backend bun run write-paths && diff -q "$LOGS/WRITE_PATHS.before" "$ROOT/docs/backend/WRITE_PATHS.md"
}
packages_tsc() {
  cd "$ROOT" && for p in packages/email packages/core apps/cloud; do node node_modules/typescript/bin/tsc -p "$p/tsconfig.json" || return 1; done
}
root_vitest() {
  cd "$ROOT" && node node_modules/vitest/vitest.mjs run \
    --exclude apps/cloud/test/v8-schema-clean-room-acceptance.test.ts \
    --exclude apps/cloud/test/work-v1-v8-regression.acceptance.test.ts \
    packages/email/test packages/core/test apps/cloud/test scripts/email-preview.test.mjs
}

echo "bun $(bun --version)  $(psql --version 2>&1)"
step typecheck  in_backend bun run typecheck
step backend    "$ROOT/scripts/test-backend.sh"
if [ "$quick" = 0 ]; then
  step write-paths write_paths
  step concurrency "$ROOT/scripts/test-concurrency.sh" 3
  step packages-tsc packages_tsc
  step root-vitest root_vitest
fi
if [ "$perf" = 1 ]; then step perf "$ROOT/scripts/test-perf.sh"; fi
grep -hE '^[0-9]+ pass, [0-9]+ fail' "$LOGS/backend.log" 2>/dev/null | sed 's/^/backend: /'
[ "$failed" = 0 ] && echo "ALL GREEN" || echo "FAILED"
exit "$failed"
