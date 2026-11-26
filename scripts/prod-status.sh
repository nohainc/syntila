#!/usr/bin/env bash
# Read-only production status: API and app health, site, migrations (backend and
# auth D1), releases on the VPS and service state. Changes nothing.
#
#   scripts/prod-status.sh
set -uo pipefail
source "$(dirname "$0")/prod-lib.sh"
parse_flags "$@"
require curl; require ssh

http() { # label url
  local code; code=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' "$2" || true)
  printf '%-22s %s  %s\n' "$1" "${code:-000}" "$2"
}
say "Public endpoints"
http "API /health/ready" "$PROD_API_URL/health/ready"
http "App /health" "$PROD_APP_URL/health"
http "Site" "$PROD_APP_URL/"

say "Backend migrations"
echo "pending (this checkout vs production):"
pending_migrations | sed 's/^/  /' || true
say "Auth D1 migrations"
if command -v pnpm >/dev/null 2>&1 && [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then d1_pending | tail -15 || true
else echo "(skipped: needs pnpm and CLOUDFLARE_API_TOKEN)"; fi

say "VPS ($PROD_VPS)"
vps_read 'echo "current:  $(readlink -f /opt/syntila/current 2>/dev/null || echo none)"
  echo "releases (newest first):"; ls -1dt /opt/syntila/releases/* 2>/dev/null | sed "s/^/  /"
  echo "syntila-backend:       $(systemctl is-active syntila-backend)"
  echo "syntila-monitor.timer: $(systemctl is-active syntila-monitor.timer)"' \
  || echo "(could not reach the VPS over ssh)"
