#!/usr/bin/env bash
# Deletes ALL production data and rebuilds an empty schema. There are no
# backups, so this replaces "restore". Only for the time before the app is live.
#
#   scripts/prod-reset-db.sh --i-understand-this-deletes-all-data [--dry-run]
#
# Stops the service, drops and recreates the database, restarts (the migrations
# recreate the schema). Asks you to type the API host name first.
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
PROD_EXTRA_FLAGS="--i-understand-this-deletes-all-data"
parse_flags "$@"
require ssh

# REMOVE THIS BLOCK when the app goes live (and then delete this script).
APP_IS_LIVE=0
[ "$APP_IS_LIVE" = 0 ] || die "The app is live; resetting the database is disabled."

case " $* " in *" --i-understand-this-deletes-all-data "*) ;; *) die "Refusing: pass --i-understand-this-deletes-all-data";; esac
host="${PROD_API_URL#*://}"; host="${host%%/*}"
say "This DELETES ALL DATA in the production database on $PROD_VPS ($PROD_API_URL)"
if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] would ask you to type: $host"
else
  printf 'Type the host name (%s) to continue: ' "$host"; read -r typed
  [ "$typed" = "$host" ] || die "Host name did not match. Cancelled."
fi
run ssh -t "$PROD_VPS" "set -e
  sudo systemctl stop syntila-backend
  sudo -u postgres psql -v ON_ERROR_STOP=1 -XAtq -d postgres -c 'DROP DATABASE IF EXISTS syntila WITH (FORCE)' -c 'CREATE DATABASE syntila OWNER syntila_app'
  sudo -u postgres psql -XAtq -d syntila -c 'ALTER SCHEMA public OWNER TO syntila_app'
  sudo systemctl start syntila-backend
  for i in \$(seq 1 60); do curl -fsS --max-time 2 http://127.0.0.1:3000/health/ready >/dev/null 2>&1 && echo 'Database reset; schema rebuilt by migrations.' && exit 0; sleep 1; done
  echo 'Backend not ready after reset' >&2; sudo journalctl -u syntila-backend -n 40 --no-pager >&2; exit 1"
