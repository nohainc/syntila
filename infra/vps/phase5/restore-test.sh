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
for t in users spaces space_memberships threads messages ai_tasks thread_events; do
  live=$(psql_pg -d syntila -c "select count(*) from $t")
  restored=$(psql_pg -d $scratch -c "select count(*) from $t")
  echo "     $t: restored $restored, live now $live"
  [ "$restored" -le "$live" ] || { echo "FAIL $t has more rows than live"; fail=1; }
done
# Integrity: every thread's event log is gap-free and matches threads.last_seq.
check "thread event logs gap-free" "$(psql_pg -d $scratch -c "
  select count(*) from threads t left join lateral (
    select count(*) n, coalesce(max(seq),0) mx from thread_events e where e.thread_id = t.id) e on true
  where e.n <> t.last_seq or e.mx <> t.last_seq")" "0"
check "messages reference existing threads" "$(psql_pg -d $scratch -c "select count(*) from messages m left join threads t on t.id = m.thread_id where t.id is null")" "0"
check "AI answers linked to tasks" "$(psql_pg -d $scratch -c "select count(*) from messages where kind='ai_answer' and task_id not in (select id from ai_tasks)")" "0"
[ "$fail" = 0 ] && echo "RESTORE TEST PASSED" || { echo "RESTORE TEST FAILED"; exit 1; }
