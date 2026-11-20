#!/usr/bin/env bash
# Regenerates apps/backend/migrations/schema.lock from the migrations, using the
# local PostgreSQL (same credentials/defaults as start-local-backend.sh).
#
# It builds a throwaway EMPTY database, applies every migration, prints the schema
# and replaces schema.lock only if everything succeeded (a failed run never leaves
# an empty lock file). Your local dev database (syntila_local) is not touched.
#
#   scripts/regenerate-schema-lock.sh           rewrite schema.lock
#   scripts/regenerate-schema-lock.sh --check   change nothing; exit 1 if schema.lock is out of date
#
# Environment (defaults match start-local-backend.sh):
#   PGHOST=127.0.0.1 PGPORT=5432 PGUSER=syntila_app PGPASSWORD=devpass
#   LOCK_DATABASE=syntila_lock   (the scratch database; dropped before and after)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-syntila_app}"
export PGPASSWORD="${PGPASSWORD:-devpass}"
LOCK_DATABASE="${LOCK_DATABASE:-syntila_lock}"
export PATH="$HOME/.bun/bin:$PATH"

if ! command -v psql >/dev/null 2>&1; then
  for candidate in /opt/homebrew/opt/postgresql@18/bin /opt/homebrew/opt/postgresql/bin /usr/local/opt/postgresql@18/bin; do
    [[ -x "$candidate/psql" ]] && PATH="$candidate:$PATH" && break
  done
fi
for tool in psql bun; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool not found in PATH." >&2; exit 1; }
done
if ! psql -d postgres -Atqc "select 1" >/dev/null 2>&1; then
  echo "PostgreSQL is not reachable as ${PGUSER}@${PGHOST}:${PGPORT}." >&2
  echo "Start it (brew services start postgresql@18) and create the role:" >&2
  echo "  psql -d postgres -c \"CREATE ROLE syntila_app LOGIN SUPERUSER PASSWORD 'devpass';\"" >&2
  exit 1
fi

TMP="$(mktemp)"
cleanup() {
  rm -f "$TMP"
  psql -d postgres -qc "DROP DATABASE IF EXISTS \"${LOCK_DATABASE}\"" >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql -d postgres -qc "DROP DATABASE IF EXISTS \"${LOCK_DATABASE}\""
psql -d postgres -qc "CREATE DATABASE \"${LOCK_DATABASE}\""

cd "$ROOT/apps/backend"
export PGDATABASE="$LOCK_DATABASE"
bun src/migrate.ts
bun src/migrate.ts --print-lock > "$TMP"
if [[ ! -s "$TMP" ]]; then
  echo "schema.lock was not written: the generated schema is empty." >&2
  exit 1
fi
if [[ "${1:-}" == "--check" ]]; then
  if diff -q "$TMP" migrations/schema.lock >/dev/null; then echo "schema.lock is up to date."; exit 0; fi
  echo "schema.lock is out of date: run scripts/regenerate-schema-lock.sh" >&2
  diff "$TMP" migrations/schema.lock | head -20 >&2 || true
  exit 1
fi
cp "$TMP" migrations/schema.lock
echo "Updated apps/backend/migrations/schema.lock ($(wc -l < migrations/schema.lock | tr -d ' ') lines)."
git --no-pager diff --stat -- migrations/schema.lock || true
