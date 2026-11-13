#!/usr/bin/env bash
# Runs the Syntila backend locally (Bun + local PostgreSQL) on :8788 with
# auto-reload, wired to the local auth Worker (wrangler dev on :8787).
#
# Environment (defaults suit a Homebrew PostgreSQL with the test role):
#   PGHOST=127.0.0.1 PGPORT=5432 PGUSER=syntila_app PGPASSWORD=devpass
#   PGDATABASE=syntila_local  BACKEND_PORT=8788  AUTH_PORT=8787  WEB_PORT=3000
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-syntila_app}"
export PGPASSWORD="${PGPASSWORD:-devpass}" PGDATABASE="${PGDATABASE:-syntila_local}"
BACKEND_PORT="${BACKEND_PORT:-8788}"
AUTH_PORT="${AUTH_PORT:-8787}"
WEB_PORT="${WEB_PORT:-3000}"

node "$ROOT/scripts/setup-local-backend.mjs"

if ! command -v psql >/dev/null 2>&1; then
  for candidate in /opt/homebrew/opt/postgresql@18/bin /opt/homebrew/opt/postgresql/bin /usr/local/opt/postgresql@18/bin; do
    [[ -x "$candidate/psql" ]] && PATH="$candidate:$PATH" && break
  done
fi
if ! psql -d postgres -Atqc "select 1" >/dev/null 2>&1; then
  echo "PostgreSQL is not reachable as ${PGUSER}@${PGHOST}:${PGPORT}." >&2
  echo "Start it (brew services start postgresql@18) and create the role:" >&2
  echo "  psql -d postgres -c \"CREATE ROLE syntila_app LOGIN SUPERUSER PASSWORD 'devpass';\"" >&2
  exit 1
fi
if [[ "$(psql -d postgres -Atqc "select 1 from pg_database where datname = '${PGDATABASE}'")" != "1" ]]; then
  psql -d postgres -qc "CREATE DATABASE \"${PGDATABASE}\""
  echo "Created local database ${PGDATABASE}."
fi

cd "$ROOT/apps/backend"
bun src/migrate.ts

export PORT="$BACKEND_PORT" BIND_HOST=127.0.0.1
export SYNTILA_ENVIRONMENT=development
export SYNTILA_APP_URL="http://localhost:${WEB_PORT}"
export ALLOWED_ORIGINS="http://localhost:${WEB_PORT},http://127.0.0.1:${WEB_PORT},http://localhost:${AUTH_PORT}"
# Tokens are issued by the local auth Worker (issuer = its BETTER_AUTH_URL origin).
export AUTH_JWT_ISSUER="http://localhost:${AUTH_PORT}"
export AUTH_JWT_AUDIENCE=syntila-backend
export AUTH_JWT_PUBLIC_KEYS_FILE="$ROOT/.development/local-backend/auth-public-keys.json"
export EMAIL_RELAY_URL="http://localhost:${AUTH_PORT}/api/internal/email"
EMAIL_RELAY_SECRET="$(cat "$ROOT/.development/local-backend/relay-secret")"
export EMAIL_RELAY_SECRET
export SYNTILA_PROFILE_LAB_OWNER_EMAIL="${SYNTILA_PROFILE_LAB_OWNER_EMAIL:-vitalii@nohainc.com}"
echo "Syntila backend (local): http://localhost:${BACKEND_PORT}  db=${PGDATABASE}  auth=http://localhost:${AUTH_PORT}"
exec bun --watch src/server.ts
