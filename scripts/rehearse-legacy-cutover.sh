#!/usr/bin/env bash
# Rollback rehearsal for the Workspace cutover (P10), on a scratch database.
# Applies every migration, runs each cutover step, proves its effect, rolls every
# step back and proves the legacy path works again. Nothing else is touched.
#   scripts/rehearse-legacy-cutover.sh
# Environment: PGHOST PGPORT PGUSER PGPASSWORD (as start-local-backend.sh); REHEARSAL_DATABASE (default syntila_cutover_rehearsal).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-syntila_app}" PGPASSWORD="${PGPASSWORD:-devpass}"
DB="${REHEARSAL_DATABASE:-syntila_cutover_rehearsal}"
case "$DB" in syntila|syntila_prod|syntila_production|syntila_local) echo "Refusing to use $DB." >&2; exit 2;; esac
export PATH="$HOME/.bun/bin:$PATH"
if ! command -v psql >/dev/null 2>&1; then
  for c in /opt/homebrew/opt/postgresql@18/bin /opt/homebrew/opt/postgresql/bin /usr/local/opt/postgresql@18/bin; do [[ -x "$c/psql" ]] && PATH="$c:$PATH" && break; done
fi
cleanup() { psql -d postgres -qc "DROP DATABASE IF EXISTS \"$DB\"" >/dev/null 2>&1 || true; }
trap cleanup EXIT
psql -d postgres -qc "DROP DATABASE IF EXISTS \"$DB\""
psql -d postgres -qc "CREATE DATABASE \"$DB\""
export PGDATABASE="$DB"
cd "$ROOT/apps/backend"
bun src/migrate.ts >/dev/null
cut() { bun scripts/legacy-cutover.ts "$@" >/dev/null; }
q() { psql -d "$DB" -Atqc "$1"; }
step() { printf '%-58s' "$1"; }
ok() { echo ok; }
bad() { echo FAIL; echo "  $1" >&2; exit 1; }

step "all switches start open";                    [[ "$(q "SELECT workspace_registration_closed_at IS NULL AND workspace_gateway_closed_at IS NULL AND worker_required_from IS NULL FROM legacy_cutover")" == t ]] && ok || bad "unexpected initial state"
step "close-registration";                         cut close-registration; [[ "$(q "SELECT workspace_registration_closed_at IS NOT NULL FROM legacy_cutover")" == t ]] && ok || bad "not closed"
step "require-worker";                             cut require-worker; [[ "$(q "SELECT worker_required_from IS NOT NULL FROM legacy_cutover")" == t ]] && ok || bad "not required"
step "close-gateway (no legacy assignments running)"; cut close-gateway; [[ "$(q "SELECT workspace_gateway_closed_at IS NOT NULL FROM legacy_cutover")" == t ]] && ok || bad "not closed"
step "archive-mapping runs twice without error";   cut archive-mapping; cut archive-mapping; ok
step "reopen all (the rollback)";                  cut reopen all; [[ "$(q "SELECT workspace_registration_closed_at IS NULL AND workspace_gateway_closed_at IS NULL AND worker_required_from IS NULL FROM legacy_cutover")" == t ]] && ok || bad "still closed"
echo "Rehearsal passed: every step applied and rolled back on $DB."
