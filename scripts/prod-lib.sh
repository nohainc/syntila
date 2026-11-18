#!/usr/bin/env bash
# Shared settings and helpers for the prod-*.sh scripts. Source it; do not run it.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Production backend host (override with the environment).
PROD_VPS="${PROD_VPS:-syntila@46.225.103.109}"
PROD_STAGE="${PROD_STAGE:-phase3-stage}"          # staging directory in the VPS home
PROD_API_URL="${PROD_API_URL:-https://api.syntila.app}"
PROD_APP_URL="${PROD_APP_URL:-https://syntila.app}"

YES=0; SKIP_TESTS=0
parse_flags() { # --yes: no confirmation prompt; --skip-tests: skip the pre-deploy test run
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) YES=1 ;;
      --skip-tests) SKIP_TESTS=1 ;;
      *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
  done
}

say() { printf '\n== %s\n' "$*"; }

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1" >&2; exit 1; }; }

confirm() { # confirm "what will happen"
  [ "$YES" = 1 ] && return 0
  printf '\n%s\nContinue? [y/N] ' "$1"
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Cancelled."; exit 1; }
}

git_state() { # production deploys should come from a known commit
  local dirty; dirty=$(git -C "$ROOT" status --short | wc -l | tr -d ' ')
  echo "commit $(git -C "$ROOT" rev-parse --short HEAD), $dirty uncommitted change(s)"
  [ "$dirty" = 0 ] || echo "warning: the working tree is not clean; the build includes uncommitted changes" >&2
}

run_tests() { # the quick gate: typecheck + backend suite
  [ "$SKIP_TESTS" = 1 ] && { echo "(tests skipped)"; return 0; }
  say "Tests (scripts/test-all.sh --quick)"
  "$ROOT/scripts/test-all.sh" --quick
}

build_backend() { say "Build backend"; ( cd "$ROOT/apps/backend" && bash scripts/build.sh ); }

# Copies the built backend, migrations and VPS files to the staging directory.
stage_backend() {
  say "Upload to $PROD_VPS:$PROD_STAGE"
  ssh "$PROD_VPS" "mkdir -p $PROD_STAGE/backend $PROD_STAGE/vps"
  rsync -a --delete "$ROOT/apps/backend/dist/" "$PROD_VPS:$PROD_STAGE/backend/dist/"
  rsync -a --delete "$ROOT/apps/backend/migrations/" "$PROD_VPS:$PROD_STAGE/backend/migrations/"
  rsync -a --delete "$ROOT/infra/vps/" "$PROD_VPS:$PROD_STAGE/vps/"
}

# Migrations in the build that the production database has not applied yet.
# Reading the list needs the database login of the syntila user; when that is
# not possible the function says so instead of listing every migration.
pending_migrations() {
  local applied
  if ! applied=$(ssh -o BatchMode=yes "$PROD_VPS" 'set -a; . /etc/syntila/backend.env; set +a
      PGPASSWORD="$(cat /etc/syntila/postgres-password 2>/dev/null)" psql -XAtq -h "${PGHOST:-127.0.0.1}" -U "${PGUSER:-syntila_app}" -d "${PGDATABASE:-syntila}" -c "SELECT version FROM schema_migrations"' 2>/dev/null) \
     || [ -z "$applied" ]; then
    echo "unknown (could not read schema_migrations; the VPS run lists them before applying)"
    return 0
  fi
  printf '%s\n' "$applied" | sort > /tmp/prod-applied.$$
  ls "$ROOT/apps/backend/migrations" | grep -E '^[0-9]{4}_[a-z0-9_]+\.sql$' | sort | comm -23 - /tmp/prod-applied.$$
  rm -f /tmp/prod-applied.$$
}
