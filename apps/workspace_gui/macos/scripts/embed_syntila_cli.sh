#!/usr/bin/env bash
set -euo pipefail

# Xcode build phase: puts the syntila CLI (and the Worker Engine when built)
# into Contents/Resources/syntila so every build of the app is self-contained.
#
# SYNTILA_CLI_BUNDLE=<dir> embeds a prebuilt bundle (release packaging does
# this). Otherwise apps/workspace is compiled; the result is cached and only
# rebuilt when Workspace or shared package sources change.

ROOT="$(cd "$SRCROOT/../../.." && pwd)"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/syntila"
DART="${FLUTTER_ROOT:+$FLUTTER_ROOT/bin/}dart"

if [[ -n "${SYNTILA_CLI_BUNDLE:-}" ]]; then
  rm -rf "$DEST"
  ditto "$SYNTILA_CLI_BUNDLE" "$DEST"
  exit 0
fi

WORKSPACE="$ROOT/apps/workspace"
CACHE="$ROOT/apps/workspace_gui/build/syntila_cli"
BIN="$CACHE/syntila"
mkdir -p "$CACHE"

if [[ ! -x "$BIN" ]] || [[ -n "$(find "$WORKSPACE/lib" "$WORKSPACE/bin" "$WORKSPACE/pubspec.yaml" "$ROOT/packages" \
    -newer "$BIN" \( -name '*.dart' -o -name 'pubspec.yaml' \) -print -quit 2>/dev/null)" ]]; then
  echo "Compiling syntila CLI for the app bundle"
  (cd "$WORKSPACE" && "$DART" pub get >/dev/null)
  "$DART" compile exe \
    --packages="$WORKSPACE/.dart_tool/package_config.json" \
    "$WORKSPACE/bin/syntila_workspace.dart" -o "$BIN.tmp"
  mv "$BIN.tmp" "$BIN"
fi

rm -rf "$DEST"
mkdir -p "$DEST/assets/engines"
cp "$BIN" "$DEST/syntila"
ENGINE="$WORKSPACE/assets/engines/syntila-agent"
if [[ -x "$ENGINE" ]]; then
  cp "$ENGINE" "$DEST/assets/engines/syntila-agent"
else
  echo "warning: Worker Engine not built ($ENGINE); run scripts/build-cli-worker-engine.sh to include it"
fi

# Hardened-runtime helpers need the Workspace entitlements (see
# scripts/build-workspace-macos.sh).
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -z "$IDENTITY" ]] && IDENTITY="-"
for exe in "$DEST/assets/engines/syntila-agent" "$DEST/syntila"; do
  [[ -f "$exe" ]] || continue
  codesign --force --options runtime \
    --entitlements "$ROOT/packaging/macos/workspace-helper.entitlements" \
    --sign "$IDENTITY" "$exe"
done
