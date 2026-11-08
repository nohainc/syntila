#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
database_name="${SYNTILA_LOCAL_D1_NAME:-syntila-development}"
wrangler_config="${SYNTILA_WRANGLER_CONFIG:-${repo_root}/apps/cloud/wrangler.jsonc}"

if [[ ! -f "$wrangler_config" ]]; then
  echo "Wrangler config not found: $wrangler_config" >&2
  exit 1
fi

cd "$repo_root"

# The Syntila rename renamed the baseline migration. Local databases created
# before it record the old name, so wrangler would re-run the baseline and fail
# with "table users already exists". Rename the record; the schema is the same.
if [[ -d apps/cloud/.wrangler/state/v3/d1 ]]; then
  pnpm exec wrangler d1 execute "$database_name" \
    --local --config "$wrangler_config" \
    --command "UPDATE d1_migrations SET name = '0001_syntila_v8.sql' WHERE name = '0001_conclave_v8.sql' AND NOT EXISTS (SELECT 1 FROM d1_migrations WHERE name = '0001_syntila_v8.sql');" \
    > /dev/null 2>&1 || true
fi

echo "Inspecting local D1 schema before migration: $database_name"
prepared_dir="$(mktemp -d "${TMPDIR:-/tmp}/syntila-local-d1-migration.XXXXXX")"
trap 'rm -rf "$prepared_dir"' EXIT

inspect_schema() {
  local inspection_status=0
  pnpm exec wrangler d1 execute "$database_name" \
    --local --config "$wrangler_config" --json \
    --command "SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' ORDER BY type,name; SELECT name FROM d1_migrations WHERE name = '0006_chat_workflow_admission.sql';" \
    > "$prepared_dir/schema.json" 2> "$prepared_dir/schema.stderr" || inspection_status=$?
  if [[ "$inspection_status" -ne 0 ]]; then
    echo "Local D1 schema inspection failed (exit $inspection_status): $database_name" >&2
    cat "$prepared_dir/schema.stderr" >&2
    cat "$prepared_dir/schema.json" >&2
    echo "Pending migrations were not applied. Resolve the inspection error before retrying." >&2
    return "$inspection_status"
  fi
}

if [[ -d apps/cloud/.wrangler/state ]]; then
  mkdir -p "$prepared_dir/.wrangler"
  cp -a apps/cloud/.wrangler/state "$prepared_dir/.wrangler/"
fi

inspect_schema

if ! node scripts/space-thread-schema-preflight.mjs "$prepared_dir/schema.json"; then
  node scripts/prepare-space-thread-cutover.mjs \
    "$prepared_dir/schema.json" "$wrangler_config" "$prepared_dir/cutover"
  echo "Applying Space/Thread cutover: $database_name (local)"
  pnpm exec wrangler d1 migrations apply "$database_name" \
    --local --config "$prepared_dir/cutover/wrangler.json"
  inspect_schema
  node scripts/space-thread-schema-preflight.mjs "$prepared_dir/schema.json"
fi

node scripts/prepare-chat-workflow-migration.mjs \
  "$prepared_dir/schema.json" "$wrangler_config" "$prepared_dir"

echo "Applying pending local migrations: $database_name"
echo y | pnpm exec wrangler d1 migrations apply "$database_name" \
  --local \
  --config "$prepared_dir/wrangler.json"

if [[ -d "$prepared_dir/.wrangler/state/v3/d1/miniflare-D1DatabaseObject" ]]; then
  mkdir -p apps/cloud/.wrangler/state/v3/d1/miniflare-D1DatabaseObject
  cp -a "$prepared_dir/.wrangler/state/v3/d1/miniflare-D1DatabaseObject/"* apps/cloud/.wrangler/state/v3/d1/miniflare-D1DatabaseObject/
fi

echo "Local D1 migration complete."
