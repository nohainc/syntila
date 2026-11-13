#!/usr/bin/env bash
# Builds the deployable backend: one bundled server and migration runner plus
# the SQL migrations. The VPS needs only Bun — no node_modules.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf dist && mkdir -p dist
bun build src/server.ts src/migrate.ts --target=bun --outdir=dist --minify-syntax --sourcemap=linked
# Operational scripts (smoke, resilience, load, keys) run on the VPS as-is.
bun build scripts/smoke.ts scripts/resilience.ts scripts/load.ts scripts/dev-keys.ts scripts/mint-token.ts \
  --target=bun --outdir=dist/scripts --minify-syntax
echo "built: $(du -sh dist | cut -f1) in apps/backend/dist (+ migrations/)"
