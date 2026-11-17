#!/usr/bin/env bash
# Local performance runner for real user actions on the local Syntila stack.
#
# Usage:
#   scripts/perf-local.sh [--probes N] [--users N] [--messages N] [--chats N] [--json out.json] [--no-thresholds]
#
# Prerequisite:
#   Run `pnpm start:local` so the local backend (:8788) and PostgreSQL are up.
#   No real AI is invoked: Scenario A probes the developer Workspace transport,
#   Scenario B posts discussion messages with realtime WebSocket fan-out, and
#   Scenario C runs Chat workflows against an in-process FakeWorkspace.
#   All synthetic data created in Scenarios B and C is deleted on exit.
#
# Options:
#   --probes N         Delivery probes per payload size in Scenario A (default 50)
#   --users N          Synthetic users in Scenario B (default 10)
#   --messages N       Messages posted per user in Scenario B (default 10)
#   --chats N          Concurrent Chat requests in Scenario C (default 10)
#   --json <file>      Write full JSON report (commit, machine info, metrics) to <file>
#   --thresholds <f>   Override threshold file (default scripts/perf-thresholds.json)
#   --no-thresholds    Report numbers without failing on threshold violations
set -euo pipefail

export PATH="$HOME/.bun/bin:/opt/homebrew/opt/postgresql@18/bin:/opt/homebrew/opt/postgresql/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-syntila_app}"
export PGPASSWORD="${PGPASSWORD:-devpass}"
export PGDATABASE="${PGDATABASE:-syntila_local}"
export AUTH_JWT_ISSUER="${AUTH_JWT_ISSUER:-http://localhost:${AUTH_PORT:-8787}}"
export AUTH_JWT_AUDIENCE="${AUTH_JWT_AUDIENCE:-syntila-backend}"
export ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-http://localhost:${WEB_PORT:-3000}}"

exec bun "$ROOT/scripts/perf-local.ts" "$@"
