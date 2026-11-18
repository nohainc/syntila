#!/usr/bin/env bash
# Concurrency and transaction tests, repeated to expose races (default 3 rounds).
#   scripts/test-concurrency.sh [rounds]
set -euo pipefail
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/../apps/backend"
rounds="${1:-3}"
for i in $(seq 1 "$rounds"); do
  echo "-- round $i/$rounds"
  bun test --timeout 20000 --preload ./test/preload.ts \
    test/concurrency.test.ts test/domain/execution-slot-concurrency.test.ts \
    test/domain/queue-concurrency.test.ts test/fixture-sql.test.ts test/tx-env.test.ts
done
