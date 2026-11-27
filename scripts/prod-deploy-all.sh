#!/usr/bin/env bash
# Full production release in a safe order: backend (with its migrations), then
# the web app and auth Worker (with the auth D1 migrations). --site also
# deploys the public site. Stops at the first failure and says which part is
# deployed and which is not.
#
#   scripts/prod-deploy-all.sh [--yes] [--skip-tests] [--dry-run] [--allow-dirty] [--site]
set -uo pipefail
here="$(dirname "$0")"
if ! web_version=$(node "$here/release-version.mjs"); then
  echo "Syntila version preflight failed; nothing was deployed." >&2
  exit 1
fi
echo "Syntila version: $web_version"
site=0; args=()
for a in "$@"; do [ "$a" = --site ] && site=1 || args+=("$a"); done
dry=0; for a in "${args[@]+"${args[@]}"}"; do [ "$a" = --dry-run ] && dry=1; done
parts=(backend web-app); [ "$site" = 1 ] && parts+=(site)
script_for() { case "$1" in backend) echo prod-deploy-backend.sh;; web-app) echo prod-deploy-web-app.sh;; site) echo prod-deploy-frontend.sh;; esac; }
[ "$dry" = 1 ] && echo "Plan (dry run, nothing is deployed): ${parts[*]}"
done_parts=()
for part in "${parts[@]}"; do
  if "$here/$(script_for "$part")" ${args[@]+"${args[@]}"}; then
    done_parts+=("$part")
  else
    echo >&2
    echo "FAILED at: $part" >&2
    echo "Deployed:     ${done_parts[*]:-nothing}" >&2
    left=(); seen=0; for p in "${parts[@]}"; do [ "$p" = "$part" ] && seen=1; [ "$seen" = 1 ] && left+=("$p"); done
    echo "Not deployed: ${left[*]} (the failed part may be partly applied; check scripts/prod-status.sh)" >&2
    exit 1
  fi
done
echo; [ "$dry" = 1 ] && echo "Dry run complete." || echo "Release complete: ${done_parts[*]}"
