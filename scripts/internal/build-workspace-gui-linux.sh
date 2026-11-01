#!/usr/bin/env bash
# Builds the Linux Workspace GUI into the same bundle folder as the headless
# CLI and Worker Engine:
#
#   dist/syntila/linux-<arch>/
#     syntila                        CLI + service
#     assets/engines/syntila-agent   Worker Engine
#     gui/syntila-workspace-gui      GUI (Flutter bundle; finds ../syntila)
#
# Flutter desktop cannot cross-compile, so this runs on a Linux host of the
# target architecture. The CLI bundle is built first with
# build-workspace-linux-headless.sh unless --gui-only is given.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUI_DIR="$ROOT/apps/workspace_gui"
GUI_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --gui-only) GUI_ONLY=1 ;;
    *) echo "Usage: $0 [--gui-only]" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == "Linux" ]] || {
  echo "Build the Linux GUI on a Linux host (Flutter desktop cannot cross-compile)." >&2
  exit 1
}
case "$(uname -m)" in
  x86_64) ARCH="x64" ;;
  aarch64 | arm64) ARCH="arm64" ;;
  *) echo "Unsupported Linux architecture: $(uname -m)" >&2; exit 1 ;;
esac
command -v flutter >/dev/null 2>&1 || { echo "Flutter is required." >&2; exit 1; }

BUNDLE="$ROOT/dist/syntila/linux-$ARCH"
[[ "${SYNTILA_WORKSPACE_ENVIRONMENT:-production}" != local ]] || BUNDLE="${BUNDLE}-local"
if [[ "$GUI_ONLY" != 1 ]]; then
  bash "$ROOT/scripts/internal/build-workspace-linux-headless.sh" "$ARCH"
fi
[[ -x "$BUNDLE/syntila" ]] || {
  echo "CLI bundle missing: $BUNDLE (run build-workspace-linux-headless.sh $ARCH)." >&2
  exit 1
}

VERSION="${SYNTILA_WORKSPACE_VERSION:-$(awk '/^version:/ {print $2; exit}' "$ROOT/apps/workspace/pubspec.yaml")}"
cd "$GUI_DIR"
flutter pub get
flutter build linux --release --build-name="${VERSION%%[+~-]*}"
rm -rf "$BUNDLE/gui"
cp -R "$GUI_DIR/build/linux/$ARCH/release/bundle" "$BUNDLE/gui"
for file in gui/syntila-workspace-gui gui/lib/libapp.so gui/lib/libflutter_linux_gtk.so \
  gui/data/syntila-workspace.png; do
  [[ -e "$BUNDLE/$file" ]] || { echo "GUI bundle is missing $file" >&2; exit 1; }
done
"$BUNDLE/syntila" --gui-manifest=1 >/dev/null

ARCHIVE="$ROOT/dist/syntila/syntila-workspace-linux-$ARCH.tar.gz"
[[ "${SYNTILA_WORKSPACE_ENVIRONMENT:-production}" != local ]] || ARCHIVE="$ROOT/dist/syntila/syntila-workspace-linux-$ARCH-local.tar.gz"
COPYFILE_DISABLE=1 tar -C "$BUNDLE" -czf "$ARCHIVE" .
echo "Built Linux Workspace bundle with GUI: $BUNDLE"
echo "Built archive: $ARCHIVE"
