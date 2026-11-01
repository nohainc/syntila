#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_LAB_DIR="$ROOT/apps/profile_lab"
DIST_DIR="$ROOT/dist/syntila-profile-lab/macos"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Syntila Profile Lab macOS builds must run on macOS." >&2
  exit 1
fi

command -v flutter >/dev/null 2>&1 || {
  echo "Flutter is required." >&2
  exit 1
}
command -v ditto >/dev/null 2>&1 || {
  echo "ditto is required on macOS." >&2
  exit 1
}

MODE="release"
TARGET_ENV="${SYNTILA_PROFILE_LAB_ENVIRONMENT:-production}"
OPEN_APP="0"
PREPARED="0"
SIGN_APP="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepared)
      PREPARED="1"
      shift
      ;;
    --debug)
      MODE="debug"
      shift
      ;;
    --release)
      MODE="release"
      shift
      ;;
    --local)
      TARGET_ENV="local"
      shift
      ;;
    --prod|--production)
      TARGET_ENV="production"
      shift
      ;;
    --version|-v)
      SYNTILA_PROFILE_LAB_VERSION="$2"
      shift 2
      ;;
    --unsigned)
      SIGN_APP="0"
      shift
      ;;
    --sign)
      SIGN_APP="1"
      SYNTILA_MACOS_SIGN_IDENTITY="$2"
      shift 2
      ;;
    --open|-o)
      OPEN_APP="1"
      shift
      ;;
    --help|-h)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Builds the Syntila Profile Lab desktop application for macOS."
      echo "Run pnpm validate:profile-lab separately for analysis and tests."
      echo ""
      echo "Options:"
      echo "  --prepared         Reuse dependencies and Engine; skip clean (CI only)"
      echo "  --release          Build in release mode (default)"
      echo "  --debug            Build in debug mode"
      echo "  --local            Local development build: talks to http://localhost:8787,"
      echo "                     uses separate local state, shows a LOCAL banner"
      echo "  --prod             Production build (default): talks to https://syntila.app"
      echo "  --version, -v VER  Override Profile Lab version"
      echo "  --unsigned         Skip Developer ID signing and notarization (default)"
      echo "  --sign IDENTITY    Developer ID signing identity"
      echo "  --open, -o         Open the built application bundle after build"
      echo "  --help, -h         Show this help message"
      echo ""
      echo "Environment variables:"
      echo "  SYNTILA_PROFILE_LAB_ENVIRONMENT     local | production (default production)"
      echo "  SYNTILA_PROFILE_LAB_VERSION         Profile Lab version override"
      echo "  SYNTILA_MACOS_SIGN_IDENTITY         Signing identity"
      echo "  SYNTILA_MACOS_NOTARY_PROFILE        Keychain profile for notarization"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

case "$TARGET_ENV" in
  local|production) ;;
  *) echo "Unknown environment '$TARGET_ENV' (expected local or production)." >&2; exit 1 ;;
esac
if [[ "$TARGET_ENV" == "local" ]]; then
  DIST_DIR="$ROOT/dist/syntila-profile-lab/macos-local"
fi

VERSION="${SYNTILA_PROFILE_LAB_VERSION:-$(awk '/^version:/ {print $2; exit}' "$PROFILE_LAB_DIR/pubspec.yaml")}"
if [[ -z "$VERSION" ]]; then
  echo "Could not determine Syntila Profile Lab version." >&2
  exit 1
fi

echo "Building Syntila Profile Lab $VERSION for macOS (mode: $MODE, environment: $TARGET_ENV)"
cd "$PROFILE_LAB_DIR"
if [[ "$PREPARED" == "1" ]]; then
  [[ -f .dart_tool/package_config.json && -x assets/engines/syntila-agent ]] || {
    echo "Prepared build requires resolved app dependencies and a freshly built Engine." >&2
    exit 1
  }
else
  flutter clean
  flutter pub get
  bash "$ROOT/scripts/internal/build-cli-worker-engine.sh"
fi

if [[ "$MODE" == "debug" ]]; then
  flutter build macos --debug \
    --dart-define=SYNTILA_PROFILE_LAB_VERSION="$VERSION" \
    --dart-define=SYNTILA_PROFILE_LAB_ENVIRONMENT="$TARGET_ENV"
  APP="$PROFILE_LAB_DIR/build/macos/Build/Products/Debug/Syntila Profile Lab.app"
else
  flutter build macos --release \
    --dart-define=SYNTILA_PROFILE_LAB_VERSION="$VERSION" \
    --dart-define=SYNTILA_PROFILE_LAB_ENVIRONMENT="$TARGET_ENV"
  APP="$PROFILE_LAB_DIR/build/macos/Build/Products/Release/Syntila Profile Lab.app"
fi

if [[ ! -d "$APP" ]]; then
  echo "Expected app bundle was not produced: $APP" >&2
  exit 1
fi

if [[ "$SIGN_APP" == "1" && -n "${SYNTILA_MACOS_SIGN_IDENTITY:-}" ]]; then
  echo "Signing with configured Developer ID identity"
  codesign --force --deep --options runtime --timestamp \
    --sign "$SYNTILA_MACOS_SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "SYNTILA_MACOS_SIGN_IDENTITY is not set; producing an unsigned development artifact."
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ZIP_SUFFIX=""
[[ "$TARGET_ENV" == "local" ]] && ZIP_SUFFIX="-local"
ZIP="$DIST_DIR/Syntila-Profile-Lab-$VERSION-macos$ZIP_SUFFIX.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ "$SIGN_APP" == "1" && -n "${SYNTILA_MACOS_NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${SYNTILA_MACOS_SIGN_IDENTITY:-}" ]]; then
    echo "Notarization requires SYNTILA_MACOS_SIGN_IDENTITY." >&2
    exit 1
  fi
  echo "Submitting to Apple notarization"
  xcrun notarytool submit "$ZIP" \
    --keychain-profile "$SYNTILA_MACOS_NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

echo "Built app bundle: $APP"
echo "Built distribution archive: $ZIP"

if [[ "$OPEN_APP" == "1" ]]; then
  echo "Opening $APP..."
  open "$APP"
fi
