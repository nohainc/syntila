#!/usr/bin/env bash
set -euo pipefail

# Builds "Syntila Workspace.app": the manifest-driven Flutter GUI with the
# signed syntila bundle (CLI + Worker Engine) embedded at
# Contents/Resources/syntila, where the GUI looks for it first.
#
# Options are passed to build-workspace-macos.sh (--local, --prod, --version,
# --sign). SYNTILA_MACOS_SIGN_IDENTITY and SYNTILA_MACOS_NOTARY_PROFILE work
# the same way as there. --cli-bundle DIR skips that build and embeds an
# existing bundle directory (containing the syntila executable).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUI_DIR="$ROOT/apps/workspace_gui"
ENTITLEMENTS="$GUI_DIR/macos/Runner/Release.entitlements"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Syntila Workspace GUI builds must run on macOS." >&2
  exit 1
fi
command -v flutter >/dev/null 2>&1 || {
  echo "Flutter is required." >&2
  exit 1
}

TARGET_ENV="production"
SIGN_EXPLICIT="0"
CLI_BUNDLE=""
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--cli-bundle" ]]; then
    CLI_BUNDLE="$(cd "$2" && pwd)"
    shift 2
    continue
  fi
  PASSTHROUGH+=("$1")
  shift
done
for arg in ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}; do
  case "$arg" in
    --local) TARGET_ENV="local" ;;
    --version|-v) ;;
    --debug|--all|--install)
      echo "$arg is not supported for the GUI build." >&2
      exit 1
      ;;
    --sign) SIGN_EXPLICIT="1" ;;
  esac
done
[[ -n "${SYNTILA_MACOS_SIGN_IDENTITY:-}" ]] && SIGN_EXPLICIT="1"

# 1. CLI + Worker Engine (signed by the Workspace build).
if [[ -z "$CLI_BUNDLE" ]]; then
  bash "$ROOT/scripts/build-workspace-macos.sh" --release ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
  CLI_BUNDLE="$ROOT/dist/syntila/macos/syntila"
  if [[ "$TARGET_ENV" == "local" ]]; then
    CLI_BUNDLE="$ROOT/dist/syntila/macos-local/syntila-local"
  fi
fi
[[ -x "$CLI_BUNDLE/syntila" ]] || {
  echo "Workspace bundle missing: $CLI_BUNDLE" >&2
  exit 1
}

# 2. GUI.
VERSION="$(awk '/^version:/ {print $2; exit}' "$ROOT/apps/workspace/pubspec.yaml")"
cd "$GUI_DIR"
flutter pub get
flutter build macos --release \
  --build-name="${SYNTILA_WORKSPACE_VERSION:-${VERSION%%+*}}"
APP="$GUI_DIR/build/macos/Build/Products/Release/Syntila Workspace.app"

# 3. Embed the CLI bundle.
rm -rf "$APP/Contents/Resources/syntila"
ditto "$CLI_BUNDLE" "$APP/Contents/Resources/syntila"

# 4. Re-seal the app (the nested binaries keep their own signatures).
IDENTITY="${SYNTILA_MACOS_SIGN_IDENTITY:-Apple Development: vitalii@nohainc.com (7X62W6499P)}"
if ! security find-identity -v -p codesigning | /usr/bin/grep -F -- "$IDENTITY" >/dev/null; then
  if [[ "$SIGN_EXPLICIT" == "1" ]]; then
    echo "The requested signing identity is not available in Keychain." >&2
    exit 1
  fi
  IDENTITY=""
fi
SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS")
if [[ -n "$IDENTITY" ]]; then
  echo "Signing the app with configured Apple identity"
  SIGN_ARGS+=(--timestamp --sign "$IDENTITY")
else
  echo "Sealing the app with an ad-hoc signature."
  SIGN_ARGS+=(--sign -)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --deep "$APP"
"$APP/Contents/Resources/syntila/syntila" --gui-manifest=1 >/dev/null

SUFFIX=""
[[ "$TARGET_ENV" == "local" ]] && SUFFIX="-local"
DIST_DIR="$ROOT/dist/syntila-workspace-gui/macos$SUFFIX"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ditto "$APP" "$DIST_DIR/Syntila Workspace.app"
ZIP="$DIST_DIR/Syntila-Workspace-GUI-${SYNTILA_WORKSPACE_VERSION:-$VERSION}-macos$SUFFIX.zip"
ditto -c -k --sequesterRsrc --keepParent "$DIST_DIR/Syntila Workspace.app" "$ZIP"

if [[ -n "${SYNTILA_MACOS_NOTARY_PROFILE:-}" ]]; then
  [[ -n "$IDENTITY" ]] || {
    echo "Notarization requires an Apple signing identity." >&2
    exit 1
  }
  echo "Submitting to Apple notarization"
  xcrun notarytool submit "$ZIP" \
    --keychain-profile "$SYNTILA_MACOS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DIST_DIR/Syntila Workspace.app"
  ditto -c -k --sequesterRsrc --keepParent "$DIST_DIR/Syntila Workspace.app" "$ZIP"
fi

echo "Built app: $DIST_DIR/Syntila Workspace.app"
echo "Built distribution archive: $ZIP"
