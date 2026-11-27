#!/usr/bin/env bash
# Apply local auth D1 and backend PostgreSQL migrations without starting apps.
# Usage: scripts/local-migrate-db.sh [--d1-only]
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
d1_only=0
case "${1:-}" in
  '') [ "$#" -eq 0 ] || { echo "Usage: $0 [--d1-only]" >&2; exit 2; } ;;
  --d1-only) [ "$#" -eq 1 ] || { echo "Usage: $0 [--d1-only]" >&2; exit 2; }; d1_only=1 ;;
  -h|--help) [ "$#" -eq 1 ] || { echo "Usage: $0 [--d1-only]" >&2; exit 2; }; echo "Usage: $0 [--d1-only]"; exit 0 ;;
  *) echo "Usage: $0 [--d1-only]" >&2; exit 2 ;;
esac

database_name="${SYNTILA_LOCAL_D1_NAME:-syntila-auth-development}"
wrangler_config="${SYNTILA_WRANGLER_CONFIG:-${repo_root}/apps/cloud/wrangler.jsonc}"
if [ "$d1_only" = 0 ]; then
  export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-syntila_app}"
  export PGPASSWORD="${PGPASSWORD:-devpass}" PGDATABASE="${PGDATABASE:-syntila_local}"
  case "$PGHOST" in 127.0.0.1|localhost|::1) ;; *) echo "Refusing to migrate a non-local PostgreSQL host: $PGHOST" >&2; exit 1;; esac
  if ! command -v psql >/dev/null 2>&1; then
    for candidate in /opt/homebrew/opt/postgresql@18/bin /opt/homebrew/opt/postgresql/bin /usr/local/opt/postgresql@18/bin; do
      [[ -x "$candidate/psql" ]] && PATH="$candidate:$PATH" && break
    done
  fi
  command -v psql >/dev/null 2>&1 || { echo "psql is required to check local PostgreSQL." >&2; exit 1; }
  command -v bun >/dev/null 2>&1 || { echo "bun is required to migrate local PostgreSQL." >&2; exit 1; }
  if ! psql -d postgres -Atqc 'select 1' >/dev/null 2>&1; then
    echo "PostgreSQL is not reachable as ${PGUSER}@${PGHOST}:${PGPORT}; start it and configure the local role first." >&2
    exit 1
  fi
fi
cd "$repo_root"
echo "Applying pending local auth D1 migrations: $database_name"
printf 'y\n' | pnpm exec wrangler d1 migrations apply "$database_name" --local --config "$wrangler_config"
echo "Local D1 migration complete."
if [ "$d1_only" = 0 ]; then
  databases=$(psql -d postgres -Atqc 'select datname from pg_database')
  if ! grep -Fxq -- "$PGDATABASE" <<< "$databases"; then
    command -v createdb >/dev/null 2>&1 || { echo "createdb is required to create $PGDATABASE." >&2; exit 1; }
    createdb -- "$PGDATABASE"
    echo "Created local PostgreSQL database $PGDATABASE."
  fi
  echo "Applying pending local backend PostgreSQL migrations: $PGDATABASE"
  (cd "$repo_root/apps/backend" && bun src/migrate.ts)
  echo "Local PostgreSQL migration complete."
fi
