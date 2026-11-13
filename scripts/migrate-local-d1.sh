#!/usr/bin/env bash
# Applies the auth Worker's D1 migrations (apps/cloud/migrations) to the local
# auth database. Product data lives in PostgreSQL (apps/backend/migrations).
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
database_name="${SYNTILA_LOCAL_D1_NAME:-syntila-auth-development}"
wrangler_config="${SYNTILA_WRANGLER_CONFIG:-${repo_root}/apps/cloud/wrangler.jsonc}"
cd "$repo_root"
echo "Applying pending local auth migrations: $database_name"
echo y | pnpm exec wrangler d1 migrations apply "$database_name" --local --config "$wrangler_config"
echo "Local D1 migration complete."
