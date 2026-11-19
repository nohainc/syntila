#!/usr/bin/env bash
# Local performance runner for real user actions on the local Syntila stack.
#
# Usage:
#   scripts/perf-local.sh [--probes N] [--chats N] [--workflow chat|work] [--allow-offline] [--model ID] [--json out.json] [--no-thresholds]
#
# Prerequisite:
#   Run `pnpm start:local` so the local backend (:8788) and PostgreSQL are up.
#   Scenario A probes the developer Workspace transport,
#   Scenario C runs real Chat requests on the developer Workspace and may use provider quota.
#   Temporary benchmark data is removed on completion.
#
# Options:
#   --probes N         Delivery probes per payload size in Scenario A (default 50)
#   --chats N          Sequential real requests in Scenario C (default 1)
#   --workflow MODE    chat (default) or stateful work
#   --allow-offline    Allow a request before the Workspace reconnects
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
