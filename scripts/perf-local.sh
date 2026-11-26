#!/usr/bin/env bash
# Local performance runner for real user actions on the local Syntila stack.
#
# Usage:
#   scripts/perf-local.sh [--probes N] [--chats N] [--parallel N] [--workflow chat|work] [--allow-offline] [--model ID] [--json out.json] [--no-thresholds]
#
# Prerequisite:
#   Run `pnpm start:local` so the local backend (:8788) and PostgreSQL are up.
#   Scenario A is retired; no Worker Agent delivery probe exists.
#   Scenario C runs real requests on a Worker and may use provider quota.
#   A Space with active work is preserved for inspection.
#
# Options:
#   --probes N         Accepted for existing invocations; transport is skipped
#   --chats N          Real requests in Scenario C (default 1)
#   --parallel N       Maximum concurrent requests on separate Threads (1–8, default 1)
#   --workflow MODE    chat (default) or stateful work
#   --allow-offline    Allow a request before the Worker reconnects
#   --model ID         Select a model supported by the chosen Worker
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
