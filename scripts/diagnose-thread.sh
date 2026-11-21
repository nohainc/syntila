#!/usr/bin/env bash
# Read-only look at a Thread in the LOCAL database. Refuses non-local hosts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-syntila_app}"
export PGPASSWORD="${PGPASSWORD:-devpass}" PGDATABASE="${PGDATABASE:-syntila_local}"
case "$PGHOST" in 127.0.0.1|localhost|::1) ;; *) echo "Refusing: PGHOST=$PGHOST is not local." >&2; exit 1;; esac
if ! command -v psql >/dev/null 2>&1; then
  for c in /opt/homebrew/opt/postgresql@18/bin /opt/homebrew/opt/postgresql/bin /usr/local/opt/postgresql@18/bin; do
    [[ -x "$c/psql" ]] && PATH="$c:$PATH" && break
  done
fi
psql -v ON_ERROR_STOP=1 -v space_name="${1:-test}" -v thread_name="${2:-ttt}" -f "$ROOT/scripts/sql/diagnose-thread.sql"
