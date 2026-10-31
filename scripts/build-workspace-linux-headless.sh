#!/usr/bin/env bash
# Cross-compiles the headless install unit without touching native app assets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-x64}"
case "$ARCH" in x64|arm64) ;; *) echo "Usage: $0 [x64|arm64]" >&2; exit 2 ;; esac
export SYNTILA_WORKSPACE_PACKAGE_MANAGER=apt
export SYNTILA_BUILD_TARGET_OS=linux SYNTILA_BUILD_TARGET_ARCH="$ARCH"
bash "$ROOT/scripts/build-workspace-service.sh"
BUNDLE="$ROOT/dist/syntila/linux-$ARCH"
cp "$ROOT/docs/operations/WORKSPACE_LINUX.md" "$BUNDLE/README.md"
ARCHIVE="$ROOT/dist/syntila/syntila-workspace-headless-linux-$ARCH.tar.gz"
# The GUI (gui/, from build-workspace-gui-linux.sh) shares this folder but is
# not part of the headless archive.
COPYFILE_DISABLE=1 tar --no-xattrs --exclude=./gui -C "$BUNDLE" -czf "$ARCHIVE" .
echo "Built headless Linux bundle: $ARCHIVE"
