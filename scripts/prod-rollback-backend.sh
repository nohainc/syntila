#!/usr/bin/env bash
# Points the production backend back at an earlier release.
#
#   scripts/prod-rollback-backend.sh [--yes] [--dry-run] [release-name]
#
# Lists the releases in /opt/syntila/releases, switches `current` to the chosen
# one (default: the one before the current release), restarts the service and
# checks readiness. It does NOT undo database migrations: the older code must
# work with the current schema (migrations are forward-only, expand/contract).
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
release=""; flags=()
for a in "$@"; do case "$a" in -*) flags+=("$a");; *) release="$a";; esac; done
parse_flags ${flags[@]+"${flags[@]}"}
require ssh; require curl

say "Releases on $PROD_VPS"
listing=$(vps_read 'cur=$(readlink -f /opt/syntila/current); for r in $(ls -1dt /opt/syntila/releases/*); do [ "$r" = "$cur" ] && m=" (current)" || m=""; echo "$(basename $r)$m"; done')
echo "$listing"
if [ -z "$release" ]; then
  release=$(printf '%s\n' "$listing" | awk '/\(current\)/{f=1;next} f{print;exit}')
  [ -n "$release" ] || die "No previous release to roll back to."
fi
case "$release" in *[!0-9TZ]*|"") die "Not a release name: $release";; esac
confirm "Roll the backend on $PROD_VPS back to release $release. Database migrations are NOT undone."
run ssh -t "$PROD_VPS" "set -e; sudo test -f /opt/syntila/releases/$release/dist/server.js
  sudo ln -sfn /opt/syntila/releases/$release /opt/syntila/current.new && sudo mv -T /opt/syntila/current.new /opt/syntila/current
  sudo systemctl restart syntila-backend.service
  for i in \$(seq 1 40); do curl -fsS --max-time 2 http://127.0.0.1:3000/health/ready >/dev/null 2>&1 && exit 0; sleep 1; done
  echo 'Backend not ready after rollback' >&2; sudo journalctl -u syntila-backend -n 40 --no-pager >&2; exit 1"
if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] would check $PROD_API_URL/health/ready"
else curl -fsS --max-time 15 "$PROD_API_URL/health/ready" && echo && echo "ok   backend ready on $release"; fi
