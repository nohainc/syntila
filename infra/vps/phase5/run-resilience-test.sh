#!/usr/bin/env bash
# Bun restart / crash test with live user and Workspace connections against the
# production service. Uses a temporary signing key that is trusted only for the
# duration of the test and removed afterwards (also on failure).
# Usage: sudo bash run-resilience-test.sh
set -Eeuo pipefail
if [ "$(id -u)" -ne 0 ]; then echo 'Run with sudo.' >&2; exit 1; fi
bun=/home/syntila/.bun/bin/bun
release=/opt/syntila/current
keys=/etc/syntila/auth-public-keys
work=$(mktemp -d /root/resilience.XXXXXX)
cp "$keys" "$work/keys.orig"
restore() {
  cp "$work/keys.orig" "$keys"; chmod 0600 "$keys"
  systemctl restart syntila-backend
  shred -u "$work"/* 2>/dev/null || true; rm -rf "$work"
  for i in $(seq 1 30); do curl -fsS --max-time 2 http://127.0.0.1:3000/health/ready >/dev/null 2>&1 && break; sleep 1; done
  echo "Temporary test key removed; production keys restored."
}
trap restore EXIT

out=$("$bun" run "$release/dist/scripts/dev-keys.js")
printf '%s\n' "$out" | sed -n 5p > "$work/private.jwk"
python3 - "$work/keys.orig" "$(printf '%s\n' "$out" | sed -n 2p)" > "$keys" <<'PY'
import json, sys
print(json.dumps(json.load(open(sys.argv[1])) + json.loads(sys.argv[2])))
PY
systemctl restart syntila-backend
for i in $(seq 1 30); do curl -fsS --max-time 2 http://127.0.0.1:3000/health/ready >/dev/null 2>&1 && break; sleep 1; done

set -a; . /etc/syntila/backend.env; set +a
cd "$release"
echo '== Scenario 1: graceful restart (deploys, systemctl restart)'
"$bun" run dist/scripts/resilience.js http://127.0.0.1:3000 "$work/private.jwk" "systemctl restart syntila-backend"
echo '== Scenario 2: crash (SIGKILL, systemd restarts it)'
"$bun" run dist/scripts/resilience.js http://127.0.0.1:3000 "$work/private.jwk" "systemctl kill --signal=SIGKILL syntila-backend"
echo '== Scenario 3: PostgreSQL restart (backend must recover without its own restart)'
before=$(systemctl show syntila-backend -p NRestarts --value)
systemctl restart postgresql
ok=
for i in $(seq 1 30); do sleep 1; curl -fsS --max-time 2 http://127.0.0.1:3000/health/ready >/dev/null 2>&1 && { ok=1; break; }; done
after=$(systemctl show syntila-backend -p NRestarts --value)
if [ -z "$ok" ] || [ "$before" != "$after" ]; then
  echo "FAIL backend did not recover from PostgreSQL restart (ready=${ok:-no}, restarts $before -> $after)"
  journalctl -u syntila-backend -n 40 --no-pager
  exit 1
fi
"$bun" run dist/scripts/smoke.js http://127.0.0.1:3000 "$work/private.jwk" >/dev/null && echo "ok   backend recovered after ${i}s without restarting; smoke test passed"
echo 'ALL RESILIENCE SCENARIOS PASSED'
