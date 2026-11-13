#!/usr/bin/env bash
# Applies the auth Worker's D1 migrations to the production auth database
# (syntila-auth). Product data migrations run on the VPS backend at deploy.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
database_name="${SYNTILA_PRODUCTION_D1_NAME:-syntila-auth}"
wrangler_config="${SYNTILA_WRANGLER_CONFIG:-${repo_root}/infra/cloudflare/app.wrangler.jsonc}"

if [[ "${CONFIRM_PRODUCTION_MIGRATION:-}" != "YES" ]]; then
  cat >&2 <<'MSG'
Refusing to migrate production without explicit confirmation.
Review the pending migrations, then rerun with:
  CONFIRM_PRODUCTION_MIGRATION=YES ./scripts/migrate-production-d1.sh
MSG
  pnpm exec wrangler d1 migrations list "$database_name" --remote --config "$wrangler_config" || true
  exit 2
fi
cd "$repo_root"
pnpm exec wrangler d1 migrations apply "$database_name" --remote --config "$wrangler_config"
pnpm exec wrangler d1 migrations list "$database_name" --remote --config "$wrangler_config"
echo "Production D1 migration complete."
