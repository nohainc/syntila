#!/usr/bin/env bash
# Runs the object-storage self-check on the VPS with the production
# credentials (they never leave the server):  bash apps/backend/scripts/check-storage.sh
set -euo pipefail
host="${SYNTILA_HOST:-syntila@46.225.103.109}"
here="$(cd "$(dirname "$0")" && pwd)"
bundle="$(mktemp -d)/check-storage.js"
bun build "$here/check-storage.ts" --target=bun --outfile="$bundle" >/dev/null
scp -q "$bundle" "$host:/tmp/check-storage.js"
# The env file is readable by root only; sudo prompts on the terminal.
ssh -t "$host" "sudo bash -c 'set -a; . /etc/syntila/backend.env; set +a; /home/syntila/.bun/bin/bun /tmp/check-storage.js'; status=\$?; rm -f /tmp/check-storage.js; exit \$status"
