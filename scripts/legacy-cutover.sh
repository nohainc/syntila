#!/usr/bin/env bash
# Staged cutover from Workspaces to Worker Agents (P10). See docs/operations/LEGACY_CUTOVER.md.
#   scripts/legacy-cutover.sh status | close-registration | require-worker | close-gateway
#                             | archive-mapping | reopen [registration|gateway|worker|all]
# Uses the local database by default (PGHOST/PGUSER/PGPASSWORD/PGDATABASE). On the VPS
# run it from the release directory with the service's environment.
set -euo pipefail
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/../apps/backend"
exec bun scripts/legacy-cutover.ts "$@"
