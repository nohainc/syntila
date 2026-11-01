#!/usr/bin/env bash
# Run the native Windows build from Git for Windows Bash.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENVIRONMENT="${SYNTILA_WORKSPACE_ENVIRONMENT:-production}"
MODE=release
for arg in "$@"; do
  case "$arg" in
    --local) ENVIRONMENT=local ;;
    --prod|--production) ENVIRONMENT=production ;;
    --debug) MODE=debug ;;
    --release) MODE=release ;;
    --help|-h) echo 'Usage: build-workspace-windows.sh [--local|--prod] [--debug|--release]'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) echo 'Build the Windows GUI on a Windows host using Git Bash.' >&2; exit 1 ;; esac
[[ "$ENVIRONMENT" == local || "$ENVIRONMENT" == production ]] || { echo "Unknown environment: $ENVIRONMENT" >&2; exit 2; }
export SYNTILA_WORKSPACE_ENVIRONMENT="$ENVIRONMENT"
exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ROOT/scripts/internal/build-workspace-gui-windows.ps1" -Mode "$MODE"
