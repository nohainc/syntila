#!/usr/bin/env bash
# Complete release of the web app and auth Worker (syntila-app, https://syntila.app).
# The Worker serves the static app and answers /health; /api goes to the VPS backend.
#
#   scripts/prod-deploy-web-app.sh [--yes] [--skip-tests] [--dry-run] [--allow-dirty]
#
# Order (a failing step stops the script before anything is deployed):
#   secrets present -> gates (cloud types and tests, flutter analyze and test)
#   -> flutter build web -> no server secrets in the bundle -> production security
#   preflight -> email sender check -> auth D1 migrations (list, confirm, apply)
#   -> sync Worker secrets -> wrangler deploy -> public checks.
# --dry-run runs the local gates, build and checks, and only prints the steps
# that change production (D1 apply, secret sync, deploy).
# Env: SYNTILA_API_URL (default /api, same origin). Secrets: see prod-lib.sh.
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
parse_flags "$@"
require flutter; require pnpm; require node; require curl

say "Production web app deploy: $(git_state)"
require_clean_main
require_secrets "${WEB_SECRETS[@]}"
cd "$ROOT"

if [ "$SKIP_TESTS" = 0 ]; then
  say "Gates"
  pnpm --dir apps/cloud types:check
  pnpm --dir apps/cloud test
  ( cd apps/app && flutter analyze && flutter test )
else
  echo "(gates skipped)"
fi

say "Build Flutter web"
( cd apps/app && flutter build web --release --dart-define=SYNTILA_API_URL="${SYNTILA_API_URL:-/api}" )

say "Browser bundle has no server secrets"
node scripts/assert-no-browser-secrets.mjs apps/app/build/web
say "Production security configuration"
pnpm production:preflight
say "Email sender configuration"
pnpm email:config-check

confirm "Deploy the auth Worker and web app to $PROD_APP_URL (applies pending auth D1 migrations and syncs Worker secrets first)."

say "Auth D1 migrations"
d1_flags=(); [ "$YES" = 1 ] && d1_flags+=(--yes); [ "$DRY_RUN" = 1 ] && d1_flags+=(--dry-run)
"$ROOT/scripts/migrate-production-d1.sh" ${d1_flags[@]+"${d1_flags[@]}"}

say "Sync Worker secrets"
if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] would run: scripts/sync-worker-secrets.sh (${WEB_SECRETS[*]:2})"
else
  ( cd apps/cloud && bash ../../scripts/sync-worker-secrets.sh ../../infra/cloudflare/app.wrangler.jsonc )
fi

say "Deploy the Worker"
run pnpm exec wrangler deploy --config infra/cloudflare/app.wrangler.jsonc

say "Public checks"
if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] would check $PROD_APP_URL/health, $PROD_APP_URL/api/session (401), $PROD_APP_URL/ (200)"
else
  curl -fsS --max-time 15 -o /dev/null "$PROD_APP_URL/health" && echo "ok   /health"
  code=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' "$PROD_APP_URL/api/session")
  [ "$code" = 401 ] || die "FAIL /api/session answered $code, expected 401 for an unauthenticated request"
  echo "ok   /api/session 401"
  code=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' "$PROD_APP_URL/")
  [ "$code" = 200 ] || die "FAIL $PROD_APP_URL/ answered $code, expected 200"
  echo "ok   page 200"
fi
echo "Web app deploy complete."
