#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrangler_config="${SYNTILA_WRANGLER_CONFIG:-${repo_root}/infra/cloudflare/app.wrangler.jsonc}"

if [[ ! -f "$wrangler_config" ]]; then
  echo "Wrangler config not found: $wrangler_config" >&2
  exit 1
fi

cd "$repo_root"

# Ensure assets directory exists for wrangler config schema requirement
mkdir -p apps/app/build/web
if [[ ! -f apps/app/build/web/index.html ]]; then
  echo "Flutter web assets are missing from apps/app/build/web." >&2
  echo "Build the web app first with: (cd apps/app && flutter build web --release --dart-define=SYNTILA_API_URL=/api)" >&2
  exit 1
fi

echo "Deploying the Syntila auth Worker and web app (syntila-app)..."
pnpm exec wrangler deploy --config "$wrangler_config" "$@"

# The auth Worker answers /health itself; the product API is the VPS backend.
echo "Checking https://syntila.app/health and https://api.syntila.app/health/ready..."
curl -fsS --max-time 15 https://syntila.app/health >/dev/null && echo "ok   auth Worker"
curl -fsS --max-time 15 https://api.syntila.app/health/ready >/dev/null && echo "ok   backend" \
  || echo "warn backend not ready (deploy it with infra/vps/deploy-backend.sh)"

echo "Syntila API deployment complete."
