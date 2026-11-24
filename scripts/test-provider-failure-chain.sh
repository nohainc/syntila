#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/syntila-provider-chain.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export SYNTILA_TEST_FAILURE_PAYLOAD="$tmp/payload.json"
export SYNTILA_TEST_FAILURE_WORK="$tmp/work.json"
for SYNTILA_TEST_FAILURE_SHAPE in agy codex agy-sensitive agy-stderr agy-stderr-response agy-whitespace; do
  export SYNTILA_TEST_FAILURE_SHAPE
  (cd "$root/apps/backend" && bun test --preload ./test/preload.ts test/domain/provider-failure-chain.test.ts)
  (cd "$root/apps/app" && flutter test test/provider_failure_chain_test.dart)
done
