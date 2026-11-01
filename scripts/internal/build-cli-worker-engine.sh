#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE_DIR="$ROOT/engines/cli_worker"
OUTPUT_DIR="$ROOT/apps/workspace/assets/engines"
DART_BIN="${SYNTILA_DART_EXECUTABLE:-$(command -v dart || true)}"

if [[ -z "$DART_BIN" ]]; then
  echo "Dart SDK is required to build the CLI Worker Engine." >&2
  exit 1
fi
DART_DIR="$(cd "$(dirname "$DART_BIN")" && pwd)"
if [[ -z "${SYNTILA_DART_EXECUTABLE:-}" && -x "$DART_DIR/cache/dart-sdk/bin/dart" ]]; then
  DART_BIN="$DART_DIR/cache/dart-sdk/bin/dart"
fi

TARGET_FLAGS=()
CROSS_BUILD=0
if [[ -n "${SYNTILA_BUILD_TARGET_OS:-}${SYNTILA_BUILD_TARGET_ARCH:-}" ]]; then
  [[ "${SYNTILA_BUILD_TARGET_OS:-}" == linux ]] || { echo "Only Linux cross-builds are supported." >&2; exit 2; }
  case "${SYNTILA_BUILD_TARGET_ARCH:-}" in x64|arm64) ;; *) echo "Target architecture must be x64 or arm64." >&2; exit 2 ;; esac
  TARGET_FLAGS=(--target-os=linux "--target-arch=$SYNTILA_BUILD_TARGET_ARCH")
  CROSS_BUILD=1
  OUTPUT_DIR="$ROOT/dist/cli-worker-engine/linux-$SYNTILA_BUILD_TARGET_ARCH"
fi

VERSION="$(awk '/^version:/ {print $2; exit}' "$ENGINE_DIR/pubspec.yaml")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "CLI Worker Engine version must be stable semantic version text." >&2
  exit 1
fi
if [[ ! -f "$ENGINE_DIR/.dart_tool/package_config.json" ]]; then
  (cd "$ENGINE_DIR" && "$DART_BIN" pub get --enforce-lockfile)
fi

mkdir -p "$OUTPUT_DIR"
if [[ "$CROSS_BUILD" == 0 ]]; then mkdir -p "$ROOT/apps/profile_lab/assets/engines"; fi
if [[ "$CROSS_BUILD" == 0 && "$(uname -s)" =~ ^(MINGW|MSYS|CYGWIN) ]]; then
  OUTPUT="$OUTPUT_DIR/syntila-agent.exe"
  PROFILE_LAB_OUTPUT="$ROOT/apps/profile_lab/assets/engines/syntila-agent.exe"
else
  OUTPUT="$OUTPUT_DIR/syntila-agent"
  PROFILE_LAB_OUTPUT="$ROOT/apps/profile_lab/assets/engines/syntila-agent"
fi
(cd "$ENGINE_DIR" && "$DART_BIN" compile exe ${TARGET_FLAGS[@]+"${TARGET_FLAGS[@]}"} \
  "-DENGINE_VERSION=$VERSION" \
  bin/syntila_cli_worker.dart \
  -o "$OUTPUT")
cp "$OUTPUT" "$PROFILE_LAB_OUTPUT" 2>/dev/null || true
if [[ "$CROSS_BUILD" == 1 ]]; then
  chmod 755 "$OUTPUT"
  echo "Built generic CLI Worker Engine $VERSION: $OUTPUT"
  exit 0
fi
# The Engine is built once from engines/cli_worker. Workspace and Profile Lab
# only receive materialized copies of that same artifact; they must never drift
# into independently maintained binaries.
cp "$OUTPUT" "$PROFILE_LAB_OUTPUT"
if command -v shasum >/dev/null 2>&1; then
  OUTPUT_DIGEST="$(shasum -a 256 "$OUTPUT")"
  PROFILE_LAB_DIGEST="$(shasum -a 256 "$PROFILE_LAB_OUTPUT")"
elif command -v sha256sum >/dev/null 2>&1; then
  OUTPUT_DIGEST="$(sha256sum "$OUTPUT")"
  PROFILE_LAB_DIGEST="$(sha256sum "$PROFILE_LAB_OUTPUT")"
else
  echo "shasum or sha256sum is required to verify Engine materializations." >&2
  exit 1
fi
if [[ "${OUTPUT_DIGEST%% *}" != "${PROFILE_LAB_DIGEST%% *}" ]]; then
  echo "Engine materializations differ after the canonical build." >&2
  exit 1
fi
if [[ "$OUTPUT" != *.exe ]]; then
  chmod 755 "$OUTPUT"
  chmod 755 "$PROFILE_LAB_OUTPUT"
  if [[ "$(uname -s)" == "Darwin" ]] && command -v codesign >/dev/null 2>&1; then
    codesign -s - --force "$OUTPUT" >/dev/null 2>&1 || true
    codesign -s - --force "$PROFILE_LAB_OUTPUT" >/dev/null 2>&1 || true
  fi
fi
echo "Built generic CLI Worker Engine $VERSION: $OUTPUT and $PROFILE_LAB_OUTPUT"
