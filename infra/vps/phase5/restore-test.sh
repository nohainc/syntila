#!/usr/bin/env bash
# Restores the latest dump into a scratch database and verifies it, then drops it.
# Usage: sudo bash restore-test.sh [dump-file]
set -Eeuo pipefail
dump=${1:-$(ls -1t /var/backups/syntila/syntila-*.dump 2>/dev/null | head -1)}
[ -n "$dump" ] && [ -f "$dump" ] || { echo "No dump found; run syntila-dump first." >&2; exit 1; }
scratch=syntila_restore_test
psql_pg() { sudo -u postgres psql -v ON_ERROR_STOP=1 -XAtq "$@"; }
cleanup() { psql_pg -c "DROP DATABASE IF EXISTS $scratch" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
echo "Restoring $dump"
start=$(date +%s)
psql_pg -c "CREATE DATABASE $scratch"
sudo -u postgres pg_restore --exit-on-error --no-owner --dbname="$scratch" "$dump"
echo "Restore took $(( $(date +%s) - start )) s"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected $3, got $2)"; fail=1; fi; }
live_migrations=$(psql_pg -d syntila -c "select string_agg(version, ',' order by version) from schema_migrations")
check "schema migrations match live" "$(psql_pg -d $scratch -c "select string_agg(version, ',' order by version) from schema_migrations")" "$live_migrations"
# Tables of the current schema (apps/backend/migrations/schema.lock). A table
# that does not exist makes psql fail and the test with it, which is the point:
# this list must follow the schema.
for t in users spaces space_memberships threads conversation_history_entries execution_workspaces worker_assignments; do
  live=$(psql_pg -d syntila -c "select count(*) from $t")
  restored=$(psql_pg -d $scratch -c "select count(*) from $t")
  echo "     $t: restored $restored, live now $live"
  [ "$restored" -le "$live" ] || { echo "FAIL $t has more rows than live"; fail=1; }
done
check "conversation history numbered 1..n without gaps" "$(psql_pg -d $scratch -c "
  select count(*) from (select conversation_id from conversation_history_entries
    group by conversation_id having min(sequence) <> 1 or max(sequence) <> count(*)) t")" "0"
# The full data invariants, when the file is installed next to this script or named.
inv=${INVARIANTS_SQL:-$(dirname "$0")/check-invariants.sql}
if [ -f "$inv" ]; then
  violations=$(psql_pg -d $scratch -F ' ' -f "$inv" | awk -F ' ' '$NF != 0 {print}' )
  check "data invariants (check-invariants.sql)" "${violations:-none}" "none"
else
  echo "     skipped check-invariants.sql (not installed; set INVARIANTS_SQL)"
fi
[ "$fail" = 0 ] && echo "RESTORE TEST PASSED" || { echo "RESTORE TEST FAILED"; exit 1; }
