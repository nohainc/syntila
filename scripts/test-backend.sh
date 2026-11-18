#!/usr/bin/env bash
# Backend test suite (bun, real PostgreSQL). One `bun test` process per file.
#   scripts/test-backend.sh                    all files
#   scripts/test-backend.sh conversations api  only files whose path contains a filter
# Env: TEST_JOBS (parallel files, default 4), TEST_LOG (write failing output there),
#      TEST_VERBOSE=1 (list passing files too), TEST_DATABASE_URL (role with CREATEDB).
set -euo pipefail
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/../apps/backend"
exec bun scripts/test.ts "$@"
