#!/usr/bin/env bash
# Syncs the Better Auth and OAuth secrets to the production Worker.
#
# Fails closed: every secret must be present in the environment, and every
# secret must be listed on the Worker after the sync. Run from apps/cloud.
#
# Usage: sync-worker-secrets.sh <wrangler-config>
set -euo pipefail

config="${1:?usage: sync-worker-secrets.sh <wrangler-config>}"
names=(
  BETTER_AUTH_SECRET
  SYNTILA_AUTH_GITHUB_CLIENT_ID
  SYNTILA_AUTH_GITHUB_CLIENT_SECRET
  SYNTILA_AUTH_GOOGLE_CLIENT_ID
  SYNTILA_AUTH_GOOGLE_CLIENT_SECRET
)

missing=()
for name in "${names[@]}"; do
  [[ -n "${!name:-}" ]] || missing+=("$name")
done
if (( ${#missing[@]} > 0 )); then
  echo "Missing secrets (set them in the shell or ~/.config/syntila/prod.env): ${missing[*]}" >&2
  exit 1
fi

for name in "${names[@]}"; do
  printf '%s' "${!name}" | pnpm exec wrangler secret put "$name" --config "$config"
done

list_file="$(mktemp)"
trap 'rm -f "$list_file"' EXIT
pnpm exec wrangler secret list --config "$config" > "$list_file"

node --input-type=module - "$list_file" "${names[@]}" <<'NODE'
import { readFileSync } from 'node:fs';

const [file, ...required] = process.argv.slice(2);
const raw = readFileSync(file, 'utf8');
const start = raw.indexOf('[');
const end = raw.lastIndexOf(']');
if (start === -1 || end < start) {
  console.error('Unable to parse wrangler secret list output.');
  process.exit(1);
}
const configured = new Set(JSON.parse(raw.slice(start, end + 1)).map((secret) => secret.name));
const missing = required.filter((name) => !configured.has(name));
if (missing.length > 0) {
  console.error(`Worker is missing secrets: ${missing.join(', ')}`);
  process.exit(1);
}
console.log('All production Worker secrets are configured.');
NODE
