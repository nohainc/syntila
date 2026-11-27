#!/usr/bin/env bash
# Builds Syntila Connect for Linux (x64 and arm64) for a release, from this Mac or
# any host with the Dart SDK: the CLI and Worker Engine are cross-compiled with
# the production Profile trust roots, then packaged in dist/connect/release/linux/.
#
#   scripts/prod-build-connect-linux.sh [--dry-run] [--allow-dirty]
#
# Output (v = apps/connect/pubspec.yaml version):
#   syntila-connect_<v>_amd64.deb, syntila-connect_<v>_arm64.deb
#       /usr/bin/syntila-connect and /usr/bin/syntila-worker (the Engine sits beside the CLI)
#   Syntila-Connect-<v>-linux-x64.tar.gz, ...-linux-arm64.tar.gz   the same two binaries
#   SHA256SUMS, build.json
# The .deb files are built with scripts/internal/make-deb.py (no dpkg needed).
# --dry-run checks the prerequisites and prints the plan; it builds nothing.
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
parse_flags "$@"
require dart; require python3
version=$(connect_version)
say "Connect for Linux $version: $(git_state)"
require_clean_main
roots=$(connect_trust_roots)
out="$CONNECT_RELEASE_DIR/linux"
if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] would cross-compile syntila-connect and syntila-worker for linux x64 and arm64, build two .deb files and two tarballs in $out"
  exit 0
fi
engine_version=$(awk '/^version:/ {print $2; exit}' "$ROOT/engines/cli_worker/pubspec.yaml")
maintainer="${SYNTILA_PACKAGE_MAINTAINER:-Syntila <support@conclaveax.com>}"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
rm -rf "$out"; mkdir -p "$out"
( cd "$ROOT/engines/cli_worker" && dart pub get >/dev/null )
( cd "$ROOT/apps/connect" && dart pub get >/dev/null )
for pair in "x64 amd64" "arm64 arm64"; do
  set -- $pair; darch=$1; debarch=$2
  say "linux-$darch"
  bin="$work/$darch/usr/bin"; mkdir -p "$bin"
  ( cd "$ROOT/engines/cli_worker" && dart compile exe --target-os linux --target-arch "$darch" \
      "-DENGINE_VERSION=$engine_version" bin/syntila_cli_worker.dart -o "$bin/syntila-worker" )
  ( cd "$ROOT/apps/connect" && dart compile exe --target-os linux --target-arch "$darch" \
      "--define=SYNTILA_PROFILE_TRUST_ROOTS=$roots" "--define=SYNTILA_UPDATE_KEYS=${SYNTILA_UPDATE_KEYS:-}" \
      bin/syntila_connect.dart -o "$bin/syntila-connect" )
  chmod 755 "$bin/syntila-connect" "$bin/syntila-worker"
  python3 "$ROOT/scripts/internal/make-deb.py" --root "$work/$darch" --output "$out/syntila-connect_${version}_${debarch}.deb" \
    --package syntila-connect --version "$version" --arch "$debarch" --maintainer "$maintainer" \
    --homepage "https://syntila.app" --depends "libc6 (>= 2.31)" \
    --description "Syntila Connect: runs your Workers on this computer" >/dev/null
  tar -C "$bin" -czf "$out/Syntila-Connect-$version-linux-$darch.tar.gz" syntila-connect syntila-worker
done
( cd "$out" && shasum -a 256 *.deb *.tar.gz > SHA256SUMS )
printf '{"version":"%s","commit":"%s","builtAt":"%s"}\n' "$version" "$(git -C "$ROOT" rev-parse HEAD)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$out/build.json"
say "Built"; ls -l "$out"
echo "Next: scripts/prod-release-connect-linux.sh"
