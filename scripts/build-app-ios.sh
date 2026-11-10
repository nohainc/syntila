#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/apps/app"
DIST_DIR="$ROOT/dist/syntila-app/ios"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Syntila iOS builds must run on macOS." >&2
  exit 1
fi

command -v flutter >/dev/null 2>&1 || {
  echo "Flutter is required." >&2
  exit 1
}
command -v xcodebuild >/dev/null 2>&1 || {
  echo "Xcode is required." >&2
  exit 1
}

MODE="release"
TARGET_ENV="${SYNTILA_APP_ENVIRONMENT:-production}"
API_URL="${SYNTILA_API_URL:-}"
SIMULATOR="0"
PREPARED="0"
SIGN_APP="0"
BUILD_IPA="0"
EXPORT_METHOD="${SYNTILA_IOS_EXPORT_METHOD:-development}"

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
    --profile)
      MODE="profile"
      shift
      ;;
    --release)
      MODE="release"
      shift
      ;;
    --simulator)
      SIMULATOR="1"
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
    --api-url)
      API_URL="$2"
      shift 2
      ;;
    --version|-v)
      SYNTILA_APP_VERSION="$2"
      shift 2
      ;;
    --unsigned)
      SIGN_APP="0"
      shift
      ;;
    --sign)
      SIGN_APP="1"
      shift
      ;;
    --ipa)
      BUILD_IPA="1"
      SIGN_APP="1"
      shift
      ;;
    --export-method)
      EXPORT_METHOD="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Builds the Syntila app (apps/app) for iOS."
      echo "Run pnpm validate:app separately for analysis and tests."
      echo ""
      echo "Options:"
      echo "  --prepared           Reuse resolved dependencies and build/ios (CI only)"
      echo "  --release            Build in release mode (default)"
      echo "  --profile            Build in profile mode"
      echo "  --debug              Build in debug mode"
      echo "  --simulator          Build for the iOS Simulator (always debug mode)"
      echo "  --local              Local development build: talks to http://localhost:8787/api"
      echo "  --prod               Production build (default): talks to https://syntila.app/api"
      echo "  --api-url URL        Override the Cloud API base URL"
      echo "  --version, -v VER    Override app version"
      echo "  --unsigned           Skip code signing (default); not installable on devices"
      echo "  --sign               Sign with the Xcode project's signing configuration"
      echo "  --ipa                Build a signed .ipa archive (implies --sign)"
      echo "  --export-method M    IPA export method: development (default), ad-hoc,"
      echo "                       app-store, or enterprise"
      echo "  --help, -h           Show this help message"
      echo ""
      echo "Environment variables:"
      echo "  SYNTILA_APP_ENVIRONMENT     local | production (default production)"
      echo "  SYNTILA_API_URL             Cloud API base URL override"
      echo "  SYNTILA_APP_VERSION         App version override"
      echo "  SYNTILA_IOS_EXPORT_METHOD   IPA export method (default development)"
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
if [[ -z "$API_URL" ]]; then
  if [[ "$TARGET_ENV" == "local" ]]; then
    API_URL="http://localhost:8787/api"
  else
    API_URL="https://syntila.app/api"
  fi
fi

if [[ "$SIMULATOR" == "1" ]]; then
  if [[ "$BUILD_IPA" == "1" ]]; then
    echo "--ipa cannot be combined with --simulator." >&2
    exit 1
  fi
  # Flutter supports only debug (JIT) builds on the iOS Simulator.
  MODE="debug"
  SIGN_APP="0"
fi
if [[ "$BUILD_IPA" == "1" && "$MODE" == "debug" ]]; then
  echo "--ipa requires --release or --profile." >&2
  exit 1
fi

VERSION="${SYNTILA_APP_VERSION:-$(awk '/^version:/ {print $2; exit}' "$APP_DIR/pubspec.yaml")}"
if [[ -z "$VERSION" ]]; then
  echo "Could not determine Syntila app version." >&2
  exit 1
fi
BUILD_NAME="${VERSION%%+*}"

TARGET="device"
[[ "$SIMULATOR" == "1" ]] && TARGET="simulator"
echo "Building Syntila $VERSION for iOS (mode: $MODE, target: $TARGET, API: $API_URL)"
cd "$APP_DIR"
if [[ "$PREPARED" == "1" ]]; then
  [[ -f .dart_tool/package_config.json ]] || {
    echo "Prepared build requires resolved app dependencies." >&2
    exit 1
  }
else
  # Clear only iOS output: build/web holds the assets deploy-api.sh publishes.
  rm -rf build/ios
  flutter pub get
fi

BUILD_ARGS=(
  "--$MODE"
  "--build-name=$BUILD_NAME"
  "--dart-define=SYNTILA_API_URL=$API_URL"
  "--dart-define=SYNTILA_APP_VERSION=$BUILD_NAME"
)
if [[ "$VERSION" == *+* ]]; then
  BUILD_ARGS+=("--build-number=${VERSION##*+}")
fi

SUFFIX=""
[[ "$TARGET_ENV" == "local" ]] && SUFFIX="-local"
mkdir -p "$DIST_DIR"

if [[ "$BUILD_IPA" == "1" ]]; then
  flutter build ipa "${BUILD_ARGS[@]}" --export-method "$EXPORT_METHOD"
  IPA="$(find "$APP_DIR/build/ios/ipa" -maxdepth 1 -name '*.ipa' -print -quit)"
  if [[ -z "$IPA" ]]; then
    echo "Expected IPA was not produced under $APP_DIR/build/ios/ipa" >&2
    exit 1
  fi
  ARTIFACT="$DIST_DIR/Syntila-$BUILD_NAME-ios$SUFFIX.ipa"
  rm -f "$ARTIFACT"
  cp "$IPA" "$ARTIFACT"
  echo "Built distribution archive: $ARTIFACT"
  exit 0
fi

if [[ "$SIMULATOR" == "1" ]]; then
  flutter build ios "${BUILD_ARGS[@]}" --simulator
  APP="$APP_DIR/build/ios/iphonesimulator/Runner.app"
  SUFFIX="-simulator$SUFFIX"
else
  if [[ "$SIGN_APP" == "1" ]]; then
    flutter build ios "${BUILD_ARGS[@]}"
  else
    echo "Producing an unsigned artifact; pass --sign or --ipa for a device-installable build."
    flutter build ios "${BUILD_ARGS[@]}" --no-codesign
  fi
  APP="$APP_DIR/build/ios/iphoneos/Runner.app"
fi

if [[ ! -d "$APP" ]]; then
  echo "Expected app bundle was not produced: $APP" >&2
  exit 1
fi

ARTIFACT="$DIST_DIR/Syntila-$BUILD_NAME-ios$SUFFIX.zip"
rm -f "$ARTIFACT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARTIFACT"

echo "Built app bundle: $APP"
echo "Built distribution archive: $ARTIFACT"
