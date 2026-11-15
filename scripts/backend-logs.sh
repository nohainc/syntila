#!/usr/bin/env bash
# Shows what the production backend logged, by topic.
#
#   scripts/backend-logs.sh                # unexpected errors, last day
#   scripts/backend-logs.sh errors 3h      # unexpected errors, last 3 hours
#   scripts/backend-logs.sh lock           # write summaries every 5 minutes (db.writes; db.writer_lock if the fallback lock is on)
#   scripts/backend-logs.sh slow           # single writes that held the lock 250 ms or more
#   scripts/backend-logs.sh db             # database health: lock waits, deadlocks, transactions
#   scripts/backend-logs.sh lockwaits      # lock waits and deadlocks PostgreSQL itself logged
#   scripts/backend-logs.sh conflicts      # parallel requests answered 409 conflict / 503 busy
#   scripts/backend-logs.sh limited        # requests refused by the rate limiter
#   scripts/backend-logs.sh retention      # nightly pruning results
#   scripts/backend-logs.sh all 2d         # everything above, last 2 days
#   scripts/backend-logs.sh follow         # live log
#
# The period is a number followed by m, h or d (default 1d). At most 50
# lines per topic are shown; set LINES=200 for more.
set -euo pipefail
host="${SYNTILA_HOST:-syntila@46.225.103.109}"
topic="${1:-errors}"
period="${2:-1d}"
lines="${LINES:-50}"

case "$period" in
  *m) since="-${period%m} minutes";;
  *h) since="-${period%h} hours";;
  *d) since="-${period%d} days";;
  *) echo "Period must look like 30m, 3h or 2d (got: $period)" >&2; exit 2;;
esac
case "${period%?}" in ''|*[!0-9]*) echo "Period must look like 30m, 3h or 2d (got: $period)" >&2; exit 2;; esac

show() { # title, pattern
  echo "== $1 (since $period)"
  ssh "$host" "journalctl -u syntila-backend --since '$since' --no-pager -o cat | grep -F -- '$2' | tail -n $lines" || true
  echo
}

case "$topic" in
  errors)    show "unexpected errors" '"http.unhandled_error"';;
  lock)      show "writes" '"db.writes"'; show "writer lock (fallback on)" '"db.writer_lock"';;
  slow)      show "slow writes" '"db.slow_write"'; show "slow transactions" '"db.slow_tx"';;
  db)
    show "database health (every 5 minutes)" '"db.health"'
    show "data-layer transactions (every 5 minutes)" '"db.tx"'
    show "slow transactions" '"db.slow_tx"';;
  lockwaits)
    echo "== PostgreSQL lock waits and deadlocks (since $period)"
    ssh "$host" "sudo journalctl -u 'postgresql*' --since '$since' --no-pager -o cat | grep -E 'still waiting for|deadlock detected|acquired .* after' | tail -n $lines" || true
    ssh "$host" "sudo sh -c 'grep -hE \"still waiting for|deadlock detected\" /var/log/postgresql/*.log 2>/dev/null | tail -n $lines'" || true
    echo;;
  conflicts) show "concurrent conflicts (409)" '"http.concurrent_conflict"'; show "concurrent timeouts (503)" '"http.concurrent_timeout"';;
  limited)   show "rate limited" '"http.rate_limited"';;
  retention) show "retention" '"retention.';;
  all)
    show "unexpected errors" '"http.unhandled_error"'
    show "slow writes" '"db.slow_write"'
    show "slow transactions" '"db.slow_tx"'
    show "database health" '"db.health"'
    show "rate limited" '"http.rate_limited"'
    show "retention" '"retention.'
    show "writer lock" '"db.writer_lock"';;
  follow)    exec ssh -t "$host" "journalctl -u syntila-backend -f -o cat";;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac
