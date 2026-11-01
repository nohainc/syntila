#!/usr/bin/env bash
# Cross-compiles the headless install unit without touching native app assets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCH="${1:-x64}"
case "$ARCH" in x64|arm64) ;; *) echo "Usage: $0 [x64|arm64]" >&2; exit 2 ;; esac
if [[ "${SYNTILA_WORKSPACE_ENVIRONMENT:-production}" == local ]]; then
  export SYNTILA_WORKSPACE_PACKAGE_MANAGER=''
else
  export SYNTILA_WORKSPACE_PACKAGE_MANAGER=apt
fi
export SYNTILA_BUILD_TARGET_OS=linux SYNTILA_BUILD_TARGET_ARCH="$ARCH"
bash "$ROOT/scripts/internal/build-workspace-service.sh"
BUNDLE="$ROOT/dist/syntila/linux-$ARCH"
[[ "${SYNTILA_WORKSPACE_ENVIRONMENT:-production}" != local ]] || BUNDLE="${BUNDLE}-local"
cp "$ROOT/docs/operations/WORKSPACE_LINUX.md" "$BUNDLE/README.md"
ARCHIVE="$ROOT/dist/syntila/syntila-workspace-headless-linux-$ARCH.tar.gz"
[[ "${SYNTILA_WORKSPACE_ENVIRONMENT:-production}" != local ]] || ARCHIVE="$ROOT/dist/syntila/syntila-workspace-headless-linux-$ARCH-local.tar.gz"
# The GUI (gui/, from build-workspace-gui-linux.sh) shares this folder but is
# not part of the headless archive.
COPYFILE_DISABLE=1 tar --no-xattrs --exclude=./gui -C "$BUNDLE" -czf "$ARCHIVE" .
echo "Built headless Linux bundle: $ARCHIVE"
