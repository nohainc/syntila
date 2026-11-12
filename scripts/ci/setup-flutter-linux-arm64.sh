#!/usr/bin/env bash
# Official Flutter archives do not include Linux ARM64. Bootstrap the exact
# stable release from Flutter's source tag using its native ARM64 Dart SDK.
set -euo pipefail
: "${RUNNER_TEMP:?}" "${GITHUB_PATH:?}" "${GITHUB_OUTPUT:?}"
[[ "$(uname -s)" == Linux && "$(uname -m)" == aarch64 ]] || { echo 'This bootstrap requires Linux ARM64.' >&2; exit 1; }
MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT
curl --fail --silent --show-error --location --retry 3 \
  https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json -o "$MANIFEST"
read -r VERSION REVISION < <(python3 - "$MANIFEST" <<'PY'
import json, re, sys
manifest = json.load(open(sys.argv[1]))
target_version = '3.47.9'
release = next(item for item in manifest['releases'] if item['version'] == target_version and item['channel'] == 'stable')
revision = release['hash']
version = release['version']
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version)
assert re.fullmatch(r'[0-9a-f]{40}', revision)
print(version, revision)
PY
)
SDK="$RUNNER_TEMP/flutter-linux-arm64"
git clone --quiet --depth 1 --branch "$VERSION" https://github.com/flutter/flutter.git "$SDK"
[[ "$(git -C "$SDK" rev-parse HEAD)" == "$REVISION" ]] || { echo 'Flutter tag does not match the official stable release manifest.' >&2; exit 1; }
echo "$SDK/bin" >> "$GITHUB_PATH"
echo "version=$VERSION" >> "$GITHUB_OUTPUT"
"$SDK/bin/flutter" config --no-analytics
"$SDK/bin/flutter" --version
