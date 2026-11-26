#!/usr/bin/env bash
# Applies the auth Worker's D1 migrations to the production auth database
# (syntila-auth). Product data migrations run on the VPS backend at deploy.
#
#   scripts/migrate-production-d1.sh [--yes] [--dry-run]
# Lists the pending migrations, asks, applies, lists again. --dry-run only lists.
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
parse_flags "$@"
require pnpm
database_name="${SYNTILA_PRODUCTION_D1_NAME:-syntila-auth}"
wrangler_config="${SYNTILA_WRANGLER_CONFIG:-${ROOT}/infra/cloudflare/app.wrangler.jsonc}"

cd "$ROOT"
say "Pending auth D1 migrations ($database_name)"
pnpm exec wrangler d1 migrations list "$database_name" --remote --config "$wrangler_config"
confirm "Apply the pending auth D1 migrations to PRODUCTION."
run pnpm exec wrangler d1 migrations apply "$database_name" --remote --config "$wrangler_config"
[ "$DRY_RUN" = 1 ] || pnpm exec wrangler d1 migrations list "$database_name" --remote --config "$wrangler_config"
echo "Production D1 migration step done."
