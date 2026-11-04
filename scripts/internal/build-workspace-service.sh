#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKSPACE_DIR="$ROOT/apps/workspace"
OUT_DIR="$ROOT/dist/syntila"
ENVIRONMENT="${SYNTILA_WORKSPACE_ENVIRONMENT:-production}"

for arg in "$@"; do
  case "$arg" in
    --local)
      ENVIRONMENT="local"
      ;;
    --production)
      ENVIRONMENT="production"
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: scripts/internal/build-workspace-service.sh [--local|--production]

Builds the unified Syntila Workspace service and bundled CLI Worker Engine.

Options:
  --local       Build for local Cloud development (http://localhost:8787).
                Can also be set via SYNTILA_WORKSPACE_ENVIRONMENT=local.
  --production  Build for production Cloud (https://syntila.app) [default].
                Can also be set via SYNTILA_WORKSPACE_ENVIRONMENT=production.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

TARGET_FLAGS=()
if [[ -n "${SYNTILA_BUILD_TARGET_OS:-}${SYNTILA_BUILD_TARGET_ARCH:-}" ]]; then
  [[ "${SYNTILA_BUILD_TARGET_OS:-}" == linux ]] || { echo "Only Linux cross-builds are supported." >&2; exit 2; }
  case "${SYNTILA_BUILD_TARGET_ARCH:-}" in x64|arm64) ;; *) echo "Target architecture must be x64 or arm64." >&2; exit 2 ;; esac
  TARGET_FLAGS=(--target-os=linux "--target-arch=$SYNTILA_BUILD_TARGET_ARCH")
  OUT_DIR="$ROOT/dist/syntila/linux-$SYNTILA_BUILD_TARGET_ARCH"
  [[ "$ENVIRONMENT" != local ]] || OUT_DIR="${OUT_DIR}-local"
fi
ENGINE_NAME="syntila-agent"
OUTPUT_NAME="syntila"
if [[ -z "${SYNTILA_BUILD_TARGET_OS:-}" ]] && [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
  ENGINE_NAME="syntila-agent.exe"
  OUTPUT_NAME="syntila.exe"
fi

command -v dart >/dev/null 2>&1 || {
  echo "Dart SDK is required to compile the Workspace service." >&2
  exit 1
}

VERSION="${SYNTILA_WORKSPACE_VERSION:-1.0.3}"
if [[ -z "${SYNTILA_WORKSPACE_VERSION:-}" ]]; then
  VERSION="$(awk '/^version:/ {print $2; exit}' "$WORKSPACE_DIR/pubspec.yaml")"
fi
PUBLIC_RELEASE_ROOTS="$(node "$ROOT/scripts/resolve-build-release-trust.mjs")"

cd "$WORKSPACE_DIR"
dart pub get
bash "$ROOT/scripts/internal/build-cli-worker-engine.sh"
mkdir -p "$OUT_DIR/assets/engines"
ENGINE_SOURCE="$WORKSPACE_DIR/assets/engines/$ENGINE_NAME"
if [[ -n "${SYNTILA_BUILD_TARGET_OS:-}" ]]; then
  ENGINE_SOURCE="$ROOT/dist/cli-worker-engine/linux-$SYNTILA_BUILD_TARGET_ARCH/$ENGINE_NAME"
fi
cp "$ENGINE_SOURCE" "$OUT_DIR/assets/engines/"
cp "$ENGINE_SOURCE" "$OUT_DIR/"
dart compile exe ${TARGET_FLAGS[@]+"${TARGET_FLAGS[@]}"} \
  --define="SYNTILA_WORKSPACE_VERSION=$VERSION" \
  --define="SYNTILA_WORKSPACE_ENVIRONMENT=$ENVIRONMENT" \
  --define="SYNTILA_WORKSPACE_PACKAGE_MANAGER=${SYNTILA_WORKSPACE_PACKAGE_MANAGER:-}" \
  --define="SYNTILA_RELEASE_TRUST_KEYS_JSON=$PUBLIC_RELEASE_ROOTS" \
  --define="SYNTILA_ENTITLEMENT_TRUST_KEYS_JSON=${SYNTILA_ENTITLEMENT_TRUST_KEYS_JSON:-{\}}" \
  --packages="$WORKSPACE_DIR/.dart_tool/package_config.json" \
  bin/syntila_workspace.dart \
  -o "$OUT_DIR/$OUTPUT_NAME"
echo "Built unified Syntila Workspace at $OUT_DIR/$OUTPUT_NAME"
if [[ "${SYNTILA_BUILD_TARGET_OS:-}" == linux ]]; then
  node "$ROOT/scripts/workspace-build-manifest.mjs" record "$OUT_DIR" "$VERSION"
fi
