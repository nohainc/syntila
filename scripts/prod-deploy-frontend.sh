#!/usr/bin/env bash
# Builds and deploys the public site (apps/site, Astro) as the Cloudflare Worker
# syntila-site, using apps/site/wrangler.production.jsonc.
#
#   scripts/prod-deploy-frontend.sh [--yes] [--skip-tests] [--dry-run] [--allow-dirty]
# Tests here are the site's own checks (type check, unit tests, release check).
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
parse_flags "$@"
require pnpm

say "Production public site deploy: $(git_state)"
require_clean_main
cd "$ROOT/apps/site"
if [ "$SKIP_TESTS" = 0 ]; then
  say "Site checks"
  pnpm run check
  pnpm run test
fi
say "Build"
pnpm run build
if [ "$SKIP_TESTS" = 0 ]; then pnpm run check:release; fi
confirm "Deploy the public site to production (syntila.app, www.syntila.app, conclaveax.com)."
say "Deploy"
run ../../node_modules/.bin/wrangler deploy --config wrangler.production.jsonc
say "Public check"
if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] would check $PROD_APP_URL/"
else curl -fsS --max-time 15 -o /dev/null -w "%{http_code} $PROD_APP_URL/\n" "$PROD_APP_URL/"; fi
