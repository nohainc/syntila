#!/usr/bin/env bash
# Build the full Workspace bundle on a Linux host of the target architecture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENVIRONMENT="${SYNTILA_WORKSPACE_ENVIRONMENT:-production}"
for arg in "$@"; do
  case "$arg" in
    --local) ENVIRONMENT=local ;;
    --prod|--production) ENVIRONMENT=production ;;
    --release) ;;
    --help|-h) echo 'Usage: build-workspace-linux.sh [--local|--prod]'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Linux ]] || { echo 'Build the Linux GUI on a Linux host.' >&2; exit 1; }
case "$(uname -m)" in
  x86_64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported Linux architecture: $(uname -m)" >&2; exit 1 ;;
esac
[[ "$ENVIRONMENT" == local || "$ENVIRONMENT" == production ]] || { echo "Unknown environment: $ENVIRONMENT" >&2; exit 2; }
export SYNTILA_WORKSPACE_ENVIRONMENT="$ENVIRONMENT"
bash "$ROOT/scripts/internal/build-workspace-linux-headless.sh" "$ARCH"
bash "$ROOT/scripts/internal/build-workspace-gui-linux.sh" --gui-only
