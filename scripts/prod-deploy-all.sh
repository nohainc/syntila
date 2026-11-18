#!/usr/bin/env bash
# Full production release in a safe order: backend (with its migrations), then
# the web app and auth Worker. Add --site to deploy the public site as well.
#
#   scripts/prod-deploy-all.sh [--yes] [--skip-tests] [--site]
set -euo pipefail
here="$(dirname "$0")"
site=0; args=()
for a in "$@"; do [ "$a" = --site ] && site=1 || args+=("$a"); done
"$here/prod-deploy-backend.sh" ${args[@]+"${args[@]}"}
"$here/prod-deploy-web-app.sh" ${args[@]+"${args[@]}"}
if [ "$site" = 1 ]; then "$here/prod-deploy-frontend.sh" ${args[@]+"${args[@]}"}; fi
echo; echo "Release complete."
