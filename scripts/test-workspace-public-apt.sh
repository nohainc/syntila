#!/usr/bin/env bash
# Acceptance against the public HTTPS repository, on a fresh Ubuntu runner.
set -euo pipefail
: "${SYNTILA_APT_URL:?}" "${SYNTILA_APT_SIGNING_FINGERPRINT:?}" "${SYNTILA_WORKSPACE_VERSION:?}"
[[ "$SYNTILA_APT_URL" == https://* ]] || { echo 'Public repository must use HTTPS.' >&2; exit 1; }
if dpkg-query -W -f='${Status}' syntila 2>/dev/null | grep -q 'install ok installed'; then
  echo 'Use a fresh test host; Syntila Workspace is already installed.' >&2
  exit 1
fi
TEMP="$(mktemp -d /tmp/syntila-public-apt.XXXXXX)"
chmod 755 "$TEMP"
service_pid=''
installed=0
cleanup() {
  if [[ -n "$service_pid" ]]; then kill "$service_pid" 2>/dev/null || true; wait "$service_pid" 2>/dev/null || true; fi
  if [[ "$installed" == 1 ]]; then sudo apt-get remove -y syntila >/dev/null 2>&1 || true; fi
  rm -rf "$TEMP"
}
trap cleanup EXIT
curl --fail --silent --show-error --location --retry 12 --retry-all-errors --retry-delay 5 \
  "${SYNTILA_APT_URL%/}/syntila-archive-keyring.gpg" -o "$TEMP/keyring.gpg"
FINGERPRINT="$(gpg --show-keys --with-colons "$TEMP/keyring.gpg" | awk -F: '$1=="fpr" {print $10; exit}')"
[[ "$FINGERPRINT" == "$SYNTILA_APT_SIGNING_FINGERPRINT" ]] || { echo 'Unexpected public signing key.' >&2; exit 1; }
curl --fail --silent --show-error --location --retry 12 --retry-all-errors --retry-delay 5 \
  "${SYNTILA_APT_URL%/}/dists/stable/InRelease" -o "$TEMP/InRelease"
gpgv --keyring "$TEMP/keyring.gpg" "$TEMP/InRelease"
cat > "$TEMP/syntila.sources" <<SOURCES
Types: deb
URIs: $SYNTILA_APT_URL
Suites: stable
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: $TEMP/keyring.gpg
SOURCES
APT_ARGS=(-o "Dir::Etc::sourcelist=$TEMP/syntila.sources" -o 'Dir::Etc::sourceparts=-' -o Acquire::Retries=5)
sudo apt-get "${APT_ARGS[@]}" update
sudo apt-get "${APT_ARGS[@]}" install --no-install-recommends -y "syntila=$SYNTILA_WORKSPACE_VERSION"
installed=1
# Check CLI behavior as well as the version: a version define alone cannot
# prove the newer command specification was included in the public package.
/usr/lib/syntila/syntila --data-dir "$TEMP/help-state" --help > "$TEMP/help.txt"
grep -F 'Create workspace.nano with defaults if it is missing' "$TEMP/help.txt"
mkdir -p "$TEMP/home"
HOME="$TEMP/home" SYNTILA_WORKSPACE_SECRET_STORE='file' syntila run --data-dir "$TEMP/state" > "$TEMP/service.log" 2>&1 &
service_pid=$!
ready=0
for _ in $(seq 1 60); do
  if syntila --data-dir "$TEMP/state" --json status > "$TEMP/health.json" 2>/dev/null &&
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("service", {}).get("serviceHealthy") is True else 1)' "$TEMP/health.json"; then ready=1; break; fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then cat "$TEMP/service.log"; exit 1; fi
syntila --data-dir "$TEMP/state" --json version > "$TEMP/version.json"
python3 - "$TEMP" "$SYNTILA_WORKSPACE_VERSION" <<'PY'
import json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
assert json.loads((root / 'health.json').read_text())['service']['serviceHealthy'] is True
assert json.loads((root / 'version.json').read_text())['version'] == sys.argv[2]
engine_path = '/usr/lib/syntila/assets/engines/syntila-agent'
engine = subprocess.run([engine_path], capture_output=True, text=True, timeout=10)
assert engine.returncode == 64 and 'Engine options are incomplete or invalid' in engine.stderr
PY
# Verify a runtime command's text rendering, not only help/version metadata.
syntila --data-dir "$TEMP/state" slots > "$TEMP/slots.txt"
syntila --data-dir "$TEMP/state" --json slots > "$TEMP/slots.json"
python3 - "$TEMP" <<'PYTEST'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
slots = json.loads((root / 'slots.json').read_text())
expected = ''.join(f"{key}\t{slots[key] if slots[key] is not None else '-'}\n"
                   for key in ('active', 'queued', 'limit'))
assert (root / 'slots.txt').read_text() == expected
assert 'workers' in slots and 'activeAssignmentIds' in slots
PYTEST
kill "$service_pid"
wait "$service_pid"
service_pid=''
echo "Public APT signature, installation, service version/status and Engine startup verified: $SYNTILA_WORKSPACE_VERSION ($(dpkg --print-architecture))."
