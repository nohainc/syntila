#!/usr/bin/env bash
# Rehearses a deploy on a local copy of the database:
#   restore dump (optional) -> migrate -> schema verify -> invariants -> (optional) smoke
#
#   bash apps/backend/scripts/rehearse.sh [dump-file] [--smoke <baseUrl> <privateJwkFile>]
#
# dump-file: a pg_dump custom-format file (pg_restore) or a plain .sql file (psql).
# Without a dump the script migrates an empty database, which still proves that
# the migrations apply from scratch and that the invariants hold.
# Never run this against production: it drops and recreates $REHEARSE_DB.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.."
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-syntila_app}" PGPASSWORD="${PGPASSWORD:-devpass}"
for dir in /opt/homebrew/opt/postgresql@16/bin /opt/homebrew/opt/postgresql@18/bin; do
  [[ -x "$dir/psql" ]] && PATH="$dir:$PATH" && break
done
db="${REHEARSE_DB:-syntila_rehearse}"
case "$db" in syntila|syntila_prod|syntila_production) echo "refusing to touch $db" >&2; exit 2 ;; esac
dump=""; smoke=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke) smoke=("$2" "$3"); shift 3 ;;
    *) dump="$1"; shift ;;
  esac
done

step() { printf '\n== %s\n' "$*"; }
step "recreate $db on ${PGHOST}:${PGPORT} ($(psql -d postgres -Atqc 'show server_version'))"
psql -X -d postgres -qc "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" -c "CREATE DATABASE \"$db\""
export PGDATABASE="$db"

if [[ -n "$dump" ]]; then
  step "restore $dump"
  if [[ "$dump" == *.sql ]]; then psql -X -q -v ON_ERROR_STOP=0 -f "$dump" >/dev/null
  else pg_restore --no-owner --no-privileges -d "$db" "$dump" || true; fi
fi

step "migrate"
bun src/migrate.ts
step "schema verify"
bun src/migrate.ts --verify
step "invariants (every violations value must be 0)"
out="$(psql -X -At -F ' | ' -f scripts/check-invariants.sql)"
echo "$out"
if echo "$out" | awk -F' [|] ' '$NF != 0 { bad = 1 } END { exit !bad }'; then
  echo "INVARIANTS VIOLATED" >&2; exit 1
fi
step "json columns"
psql -X -At -f scripts/check-json-columns.sql || true
if [[ ${#smoke[@]} -eq 2 ]]; then
  step "smoke"
  bun scripts/smoke.ts "${smoke[@]}"
fi
step "rehearsal ok"
