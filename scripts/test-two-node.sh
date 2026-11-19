#!/usr/bin/env bash
# Two backend processes on one PostgreSQL database (multi-server rules, ADR-033).
#   scripts/test-two-node.sh [--strict]
# --strict also fails the known gaps (realtime across nodes until ADR-038/039).
set -euo pipefail
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/../apps/backend"
exec bun scripts/two-node.ts "$@"
