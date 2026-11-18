#!/usr/bin/env bash
# Builds the Flutter web app and deploys it with the auth Worker (syntila-app,
# https://syntila.app). The Worker serves the static app and answers /health;
# /api goes to the VPS backend.
#
#   scripts/prod-deploy-web-app.sh [--yes]
# Env: SYNTILA_API_URL (default /api, same origin)
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
parse_flags "$@"
require flutter; require pnpm

say "Production web app deploy: $(git_state)"
confirm "Build apps/app for web and deploy the auth Worker and web app to $PROD_APP_URL."
say "Build Flutter web"
( cd "$ROOT/apps/app" && flutter build web --release --dart-define=SYNTILA_API_URL="${SYNTILA_API_URL:-/api}" )
say "Deploy (scripts/deploy-api.sh)"
"$ROOT/scripts/deploy-api.sh"
