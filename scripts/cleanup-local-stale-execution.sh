#!/usr/bin/env bash
# Clears orphaned execution state (stale Thread leases, never-launched
# assignments and Agent commands, stuck queued Work Requests) from the LOCAL
# development PostgreSQL database. Stop the local backend first.
# Refuses any database that is not on this machine.
#   PGHOST=127.0.0.1 PGPORT=5432 PGUSER=syntila_app PGPASSWORD=devpass PGDATABASE=syntila_local
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-syntila_app}"
export PGPASSWORD="${PGPASSWORD:-devpass}" PGDATABASE="${PGDATABASE:-syntila_local}"
case "$PGHOST" in 127.0.0.1|localhost|::1) ;; *) echo "Refusing: PGHOST=$PGHOST is not local." >&2; exit 1;; esac
if ! command -v psql >/dev/null 2>&1; then
  for candidate in /opt/homebrew/opt/postgresql@18/bin /opt/homebrew/opt/postgresql/bin /usr/local/opt/postgresql@18/bin; do
    [[ -x "$candidate/psql" ]] && PATH="$candidate:$PATH" && break
  done
fi
psql -v ON_ERROR_STOP=1 -q -f "$ROOT/scripts/sql/cleanup-stale-execution-state.sql"
echo "Cleaned stale execution state in ${PGDATABASE}."
