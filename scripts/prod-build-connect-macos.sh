#!/usr/bin/env bash
# Builds Syntila Connect for macOS (this Mac's architecture) for a release:
# the CLI and Worker Engine as native executables with the production Profile
# trust roots, plus the desktop app, packaged in dist/connect/release/macos/.
#
#   scripts/prod-build-connect-macos.sh [--skip-gui] [--dry-run] [--allow-dirty]
#
# Output (Git-derived version and architecture from this Mac):
#   Syntila-Connect-<v>-macos-<arch>.tar.gz   syntila-connect + syntila-worker
#   Syntila-Connect-<v>-macos-<arch>-app.zip  the desktop app (unless --skip-gui)
#   SHA256SUMS, build.json
# Binaries are ad-hoc signed, not notarized. --dry-run checks the prerequisites
# and prints the plan; it builds nothing.
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
PROD_EXTRA_FLAGS="--skip-gui"
parse_flags "$@"
gui=1; for a in "$@"; do [ "$a" = --skip-gui ] && gui=0; done
[ "$(uname -s)" = Darwin ] || die "This build must run on macOS."
require node; require dart; [ "$gui" = 0 ] || require flutter

version=$(connect_version); arch=$(uname -m)
say "Connect for macOS $version ($arch): $(git_state)"
require_clean_main
roots=$(connect_trust_roots)
out="$CONNECT_RELEASE_DIR/macos"
if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] would run scripts/build-connect-macos.sh --prod (GUI: $([ "$gui" = 1 ] && echo yes || echo no)) and write to $out"
  exit 0
fi
export SYNTILA_CONNECT_VERSION="$version" SYNTILA_PROFILE_TRUST_ROOTS="$roots" SYNTILA_UPDATE_KEYS="${SYNTILA_UPDATE_KEYS:-}"
skip=(); [ "$gui" = 1 ] || skip=(--skip-gui)
"$ROOT/scripts/build-connect-macos.sh" --prod ${skip[@]+"${skip[@]}"}

built="$ROOT/dist/connect/macos-production"
rm -rf "$out"; mkdir -p "$out"
name="Syntila-Connect-$version-macos-$arch"
tar -C "$built" -czf "$out/$name.tar.gz" syntila-connect syntila-worker
if [ "$gui" = 1 ]; then
  app=$(ls -d "$built"/gui/*.app | head -1)
  ditto -c -k --keepParent "$app" "$out/$name-app.zip"
fi
( cd "$out" && shasum -a 256 Syntila-Connect-* > SHA256SUMS )
printf '{"version":"%s","commit":"%s","arch":"%s","builtAt":"%s"}\n' "$version" "$(git -C "$ROOT" rev-parse HEAD)" "$arch" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$out/build.json"
say "Built"; ls -l "$out"
echo "Next: scripts/prod-release-connect-macos.sh"
