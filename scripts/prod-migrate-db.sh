#!/usr/bin/env bash
# Production database migrations, separate from a release.
#
# Migrations normally run automatically when the backend is deployed
# (scripts/prod-deploy-backend.sh): the service applies them before it starts.
# Use this script when you want to see the state, or to
# apply a schema change ahead of the code (expand migrations only: forward-only
# changes that the running release ignores).
#
#   scripts/prod-migrate-db.sh status          applied and pending migrations, schema drift check
#   scripts/prod-migrate-db.sh apply [--yes] [--dry-run] [--allow-dirty]   apply the pending migrations of this checkout
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
cmd="${1:-status}"; shift || true
parse_flags "$@"
require rsync; require ssh

remote_env='set -a; . /etc/syntila/backend.env; set +a; export PGPASSWORD="$(cat /etc/syntila/postgres-password)"'

case "$cmd" in
  status)
    say "Applied on production"
    ssh -t "$PROD_VPS" "sudo -u postgres psql -XAtq -d syntila -c \"SELECT version FROM schema_migrations ORDER BY version\" | tail -5; echo '(last 5)'"
    say "In this checkout but not applied"
    pending=$(pending_migrations || true); echo "${pending:-none}"
    ;;
  apply)
    require bun
    build_backend
    pending=$(pending_migrations || true)
    [ -n "$pending" ] || { echo "No pending migrations."; exit 0; }
    case "$pending" in unknown*) echo "$pending" >&2; echo "Refusing to apply blind; run \"status\" on the VPS first." >&2; exit 1;; esac
    confirm "Apply these migrations to PRODUCTION now:
$pending"
    require_clean_main
    stage_backend
    say "Migrate on the VPS (asks for the sudo password)"
    run ssh -t "$PROD_VPS" "set -e
      sudo -u syntila bash -c '$remote_env; /home/syntila/.bun/bin/bun \$HOME/$PROD_STAGE/backend/dist/migrate.js'
      sudo -u syntila bash -c '$remote_env; /home/syntila/.bun/bin/bun \$HOME/$PROD_STAGE/backend/dist/migrate.js --verify'"
    ;;
  *) echo "Usage: prod-migrate-db.sh status | apply [--yes]" >&2; exit 2 ;;
esac
