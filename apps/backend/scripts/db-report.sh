#!/usr/bin/env bash
# Runs the read-only database health report on the VPS:  bash apps/backend/scripts/db-report.sh
# The report only reads statistics; it changes nothing.
set -euo pipefail
host="${SYNTILA_HOST:-syntila@46.225.103.109}"
here="$(cd "$(dirname "$0")" && pwd)"
scp -q "$here/db-report.sql" "$host:/tmp/syntila-db-report.sql"
ssh -t "$host" "sudo -u postgres psql -X -d syntila -f /tmp/syntila-db-report.sql; status=\$?; rm -f /tmp/syntila-db-report.sql; exit \$status"
