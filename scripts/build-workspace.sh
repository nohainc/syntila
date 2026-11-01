#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="release"
MODE_EXPLICIT=0
VERSION=""
TARGET_ENV="${SYNTILA_WORKSPACE_ENVIRONMENT:-production}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) MODE=debug; MODE_EXPLICIT=1; shift ;;
    --release) MODE=release; MODE_EXPLICIT=1; shift ;;
    --local) TARGET_ENV=local; shift ;;
    --prod|--production) TARGET_ENV=production; shift ;;
    --version|-v) VERSION="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--debug|--release] [--local|--prod] [--version X.Y.Z]"
      echo "Builds the complete Workspace app for the current host."
      echo "Linux builds the complete app; explicit --debug is unavailable there."
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

export SYNTILA_WORKSPACE_ENVIRONMENT="$TARGET_ENV"
[[ -z "$VERSION" ]] || export SYNTILA_WORKSPACE_VERSION="$VERSION"
OS="$(uname -s)"
case "$OS" in
  Darwin)
    args=("--$MODE")
    [[ "$TARGET_ENV" == "local" ]] && args+=(--local)
    [[ -n "$VERSION" ]] && args+=(--version "$VERSION")
    exec bash "$ROOT/scripts/build-workspace-macos.sh" "${args[@]}"
    ;;
  Linux)
    if [[ "$MODE_EXPLICIT" == 1 && "$MODE" == debug ]]; then
      echo "Linux headless builds do not support --debug." >&2
      exit 2
    fi
    case "$(uname -m)" in
      x86_64) arch=x64 ;;
      aarch64|arm64) arch=arm64 ;;
      *) echo "Unsupported Linux architecture: $(uname -m)" >&2; exit 1 ;;
    esac
    exec bash "$ROOT/scripts/build-workspace-linux.sh" "--$TARGET_ENV"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    exec bash "$ROOT/scripts/build-workspace-windows.sh" "--$TARGET_ENV" "--$MODE"
    ;;
  *) echo "Unsupported desktop build machine: $OS" >&2; exit 1 ;;
esac
