#!/usr/bin/env bash
# P11 scale scenarios against a running backend (see apps/backend/scripts/scale.ts).
#   scripts/test-scale.sh [scenario...] [--sockets N] [--senders N] [--messages N] [--storms N] [--soak-minutes N] [--json out.json]
# Start the backend with rate limits off (SYNTILA_RATE_LIMIT_PER_MINUTE=0 SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE=0), as for scripts/load.ts.
# Env: SCALE_URL (default http://localhost:8788), SCALE_JWK (private JWK file; default: the key in apps/cloud/.dev.vars), SERVER_PID (backend pid for memory), PG* (outbox/lock metrics).
# Run it on the target VPS size, not on a laptop, before drawing the ADR-039 conclusion.
set -euo pipefail
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="${SCALE_URL:-http://localhost:8788}"
JWK="${SCALE_JWK:-}"
if [[ -z "$JWK" ]]; then # the local backend's signing key lives in apps/cloud/.dev.vars
  JWK="$(mktemp)"; trap 'rm -f "$JWK"' EXIT
  sed -n 's/^SYNTILA_BACKEND_SIGNING_KEY=//p' "$ROOT/apps/cloud/.dev.vars" | head -1 > "$JWK"
  [[ -s "$JWK" ]] || { echo "No signing key in apps/cloud/.dev.vars (set SCALE_JWK to a private JWK file)." >&2; exit 2; }
fi
cd "$ROOT/apps/backend"
bun scripts/scale.ts "$URL" "$JWK" "$@"
