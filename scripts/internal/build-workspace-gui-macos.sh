#!/usr/bin/env bash
set -euo pipefail

# Builds "Syntila Workspace.app" (the manifest-driven Flutter GUI) into the
# same bundle folder as the syntila CLI and Worker Engine, then re-creates the
# distribution archive so it contains both:
#
#   dist/syntila/macos/syntila/
#     syntila                       CLI + service
#     assets/engines/syntila-agent  Worker Engine
#     Syntila Workspace.app         GUI (finds ../syntila)
#
# Builds the CLI bundle first with build-workspace-macos.sh (options are
# passed through: --local, --prod, --version, --sign). --gui-only reuses an
# existing bundle folder. SYNTILA_MACOS_SIGN_IDENTITY and
# SYNTILA_MACOS_NOTARY_PROFILE work as in build-workspace-macos.sh.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUI_DIR="$ROOT/apps/workspace_gui"
ENTITLEMENTS="$GUI_DIR/macos/Runner/Release.entitlements"
APP_NAME="Syntila Workspace.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Syntila Workspace GUI builds must run on macOS." >&2
  exit 1
fi
command -v flutter >/dev/null 2>&1 || {
  echo "Flutter is required." >&2
  exit 1
}
[[ -f "$GUI_DIR/macos/Runner.xcodeproj/project.pbxproj" ]] || {
  echo "Workspace GUI macOS project is missing: $GUI_DIR/macos" >&2
  exit 1
}

TARGET_ENV="production"
SIGN_EXPLICIT="0"
GUI_ONLY="0"
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gui-only) GUI_ONLY="1"; shift ;;
    --local) TARGET_ENV="local"; PASSTHROUGH+=("$1"); shift ;;
    --prod|--production) TARGET_ENV="production"; PASSTHROUGH+=("$1"); shift ;;
    --version|-v) SYNTILA_WORKSPACE_VERSION="$2"; PASSTHROUGH+=("$1" "$2"); shift 2 ;;
    --sign) SYNTILA_MACOS_SIGN_IDENTITY="$2"; SIGN_EXPLICIT="1"; PASSTHROUGH+=("$1" "$2"); shift 2 ;;
    --help|-h)
      sed -n '4,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ -n "${SYNTILA_MACOS_SIGN_IDENTITY:-}" ]] && SIGN_EXPLICIT="1"

DIST_DIR="$ROOT/dist/syntila/macos"
BUNDLE_NAME="syntila"
SUFFIX=""
if [[ "$TARGET_ENV" == "local" ]]; then
  DIST_DIR="$ROOT/dist/syntila/macos-local"
  BUNDLE_NAME="syntila-local"
  SUFFIX="-local"
fi
BUNDLE="$DIST_DIR/$BUNDLE_NAME"

# 1. CLI + Worker Engine into the shared folder.
if [[ "$GUI_ONLY" != "1" ]]; then
  bash "$ROOT/scripts/build-workspace-macos.sh" --release ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
fi
[[ -x "$BUNDLE/syntila" ]] || {
  echo "CLI bundle missing: $BUNDLE (build it with build-workspace-macos.sh)." >&2
  exit 1
}

# 2. GUI. Release builds do not embed a CLI; the app uses ../syntila.
VERSION="${SYNTILA_WORKSPACE_VERSION:-$(awk '/^version:/ {print $2; exit}' "$ROOT/apps/workspace/pubspec.yaml")}"
cd "$GUI_DIR"
flutter pub get
flutter build macos --release --build-name="${VERSION%%+*}"
BUILT_APP="$GUI_DIR/build/macos/Build/Products/Release/$APP_NAME"
APP="$BUNDLE/$APP_NAME"
rm -rf "$APP"
ditto "$BUILT_APP" "$APP"

# Set the app and Dock icon before signing; Flutter's template otherwise uses
# its default icon asset. CFBundleIconName would take precedence over IconFile.
install -m 644 "$GUI_DIR/assets/icons/SyntilaWorkspace.icns" \
  "$APP/Contents/Resources/SyntilaWorkspace.icns"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$APP/Contents/Info.plist" 2>/dev/null || true
if /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile SyntilaWorkspace' "$APP/Contents/Info.plist"
else
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string SyntilaWorkspace' "$APP/Contents/Info.plist"
fi

# 3. Sign (Apple identity when available, otherwise ad-hoc) and verify.
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
# Sign inside-out with one identity: the hardened runtime refuses to load
# frameworks whose Team ID differs from the app's (Xcode leaves the Flutter
# frameworks ad-hoc signed).
FRAMEWORK_ARGS=(--force --options runtime --sign "${IDENTITY:--}")
[[ -n "$IDENTITY" ]] && FRAMEWORK_ARGS+=(--timestamp)
while IFS= read -r -d '' item; do
  codesign "${FRAMEWORK_ARGS[@]}" "$item"
done < <(find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 \
  \( -name '*.framework' -o -name '*.dylib' \) -print0 2>/dev/null)
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --deep "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")" == SyntilaWorkspace ]]
cmp "$GUI_DIR/assets/icons/SyntilaWorkspace.icns" "$APP/Contents/Resources/SyntilaWorkspace.icns"
# A signature mismatch only shows at launch; check every framework's Team ID.
APP_TEAM="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
while IFS= read -r -d '' item; do
  team="$(codesign -dv --verbose=4 "$item" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
  [[ "$team" == "$APP_TEAM" ]] || {
    echo "$(basename "$item") Team ID '$team' does not match the app's '$APP_TEAM'." >&2
    exit 1
  }
done < <(find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 -name '*.framework' -print0 2>/dev/null)
bash "$ROOT/scripts/verify-workspace-service-bundle.sh" "$BUNDLE"
"$BUNDLE/syntila" --gui-manifest=1 >/dev/null

# 4. One archive with CLI, Engine and GUI.
ZIP="$DIST_DIR/Syntila-Workspace-$VERSION-macos$SUFFIX.zip"
archive() {
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"
}
archive

if [[ -n "${SYNTILA_MACOS_NOTARY_PROFILE:-}" ]]; then
  [[ -n "$IDENTITY" ]] || {
    echo "Notarization requires an Apple signing identity." >&2
    exit 1
  }
  echo "Submitting to Apple notarization"
  xcrun notarytool submit "$ZIP" \
    --keychain-profile "$SYNTILA_MACOS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  archive
fi

echo "Built bundle: $BUNDLE"
echo "Built distribution archive: $ZIP"
