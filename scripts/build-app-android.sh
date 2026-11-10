#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/apps/app"
DIST_DIR="$ROOT/dist/syntila-app/android"

command -v flutter >/dev/null 2>&1 || {
  echo "Flutter is required." >&2
  exit 1
}

MODE="release"
TARGET_ENV="${SYNTILA_APP_ENVIRONMENT:-production}"
API_URL="${SYNTILA_API_URL:-}"
PREPARED="0"
BUILD_AAB="0"
SPLIT_PER_ABI="0"

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
    --apk)
      BUILD_AAB="0"
      shift
      ;;
    --aab|--appbundle)
      BUILD_AAB="1"
      shift
      ;;
    --split-per-abi)
      SPLIT_PER_ABI="1"
      shift
      ;;
    --help|-h)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Builds the Syntila app (apps/app) for Android."
      echo "Run pnpm validate:app separately for analysis and tests."
      echo ""
      echo "Options:"
      echo "  --prepared           Reuse resolved dependencies and build/app (CI only)"
      echo "  --release            Build in release mode (default)"
      echo "  --profile            Build in profile mode"
      echo "  --debug              Build in debug mode"
      echo "  --local              Local development build: talks to http://10.0.2.2:8787/api"
      echo "                       (the Android emulator's alias for the host's localhost)"
      echo "  --prod               Production build (default): talks to https://syntila.app/api"
      echo "  --api-url URL        Override the Cloud API base URL"
      echo "  --version, -v VER    Override app version"
      echo "  --apk                Build an installable universal APK (default)"
      echo "  --aab                Build an Android App Bundle for Google Play"
      echo "  --split-per-abi      Build one APK per ABI instead of a universal APK"
      echo "  --help, -h           Show this help message"
      echo ""
      echo "Release builds are signed with android/key.properties when present"
      echo "(storeFile, storePassword, keyAlias, keyPassword); otherwise with the"
      echo "debug keys, which are installable but not accepted by Google Play."
      echo ""
      echo "Environment variables:"
      echo "  SYNTILA_APP_ENVIRONMENT     local | production (default production)"
      echo "  SYNTILA_API_URL             Cloud API base URL override"
      echo "  SYNTILA_APP_VERSION         App version override"
      echo "  ANDROID_HOME                Android SDK location (auto-detected when unset)"
      echo "  JAVA_HOME                   JDK 17+ location (auto-detected when unset)"
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
    API_URL="http://10.0.2.2:8787/api"
  else
    API_URL="https://syntila.app/api"
  fi
fi
if [[ "$BUILD_AAB" == "1" && "$SPLIT_PER_ABI" == "1" ]]; then
  echo "--split-per-abi cannot be combined with --aab." >&2
  exit 1
fi
if [[ "$BUILD_AAB" == "1" && "$MODE" == "debug" ]]; then
  echo "--aab requires --release or --profile." >&2
  exit 1
fi

if [[ -z "${ANDROID_HOME:-}" ]]; then
  for CANDIDATE in \
    "${ANDROID_SDK_ROOT:-}" \
    "$HOME/Library/Android/sdk" \
    "$HOME/Android/Sdk" \
    /opt/homebrew/share/android-commandlinetools \
    /usr/local/share/android-commandlinetools; do
    if [[ -n "$CANDIDATE" && -d "$CANDIDATE/platforms" ]]; then
      export ANDROID_HOME="$CANDIDATE"
      break
    fi
  done
fi
if [[ -z "${ANDROID_HOME:-}" || ! -d "$ANDROID_HOME" ]]; then
  echo "Android SDK is required. Install it and set ANDROID_HOME." >&2
  exit 1
fi

if [[ -z "${JAVA_HOME:-}" ]]; then
  for CANDIDATE in \
    /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
    /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
    if [[ -x "$CANDIDATE/bin/java" ]]; then
      export JAVA_HOME="$CANDIDATE"
      break
    fi
  done
fi
if [[ -n "${JAVA_HOME:-}" ]]; then
  export PATH="$JAVA_HOME/bin:$PATH"
fi
java -version >/dev/null 2>&1 || {
  echo "A JDK (17 or newer) is required. Install one and set JAVA_HOME." >&2
  exit 1
}

VERSION="${SYNTILA_APP_VERSION:-$(awk '/^version:/ {print $2; exit}' "$APP_DIR/pubspec.yaml")}"
if [[ -z "$VERSION" ]]; then
  echo "Could not determine Syntila app version." >&2
  exit 1
fi
BUILD_NAME="${VERSION%%+*}"

# Plain HTTP is allowed only when the API itself is plain HTTP (local Cloud).
if [[ "$API_URL" == http://* ]]; then
  export SYNTILA_ANDROID_CLEARTEXT="true"
else
  export SYNTILA_ANDROID_CLEARTEXT="false"
fi

FORMAT="apk"
[[ "$BUILD_AAB" == "1" ]] && FORMAT="aab"
echo "Building Syntila $VERSION for Android (mode: $MODE, format: $FORMAT, API: $API_URL)"
cd "$APP_DIR"
if [[ "$PREPARED" == "1" ]]; then
  [[ -f .dart_tool/package_config.json ]] || {
    echo "Prepared build requires resolved app dependencies." >&2
    exit 1
  }
else
  # Clear only Android output: build/web holds the assets deploy-api.sh publishes.
  rm -rf build/app
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

if [[ "$MODE" == "release" && ! -f android/key.properties ]]; then
  echo "No android/key.properties; signing the release build with the debug keys."
fi

SUFFIX=""
[[ "$MODE" != "release" ]] && SUFFIX="-$MODE"
[[ "$TARGET_ENV" == "local" ]] && SUFFIX="$SUFFIX-local"
mkdir -p "$DIST_DIR"

if [[ "$BUILD_AAB" == "1" ]]; then
  flutter build appbundle "${BUILD_ARGS[@]}"
  BUNDLE="$APP_DIR/build/app/outputs/bundle/$MODE/app-$MODE.aab"
  if [[ ! -f "$BUNDLE" ]]; then
    echo "Expected app bundle was not produced: $BUNDLE" >&2
    exit 1
  fi
  ARTIFACT="$DIST_DIR/Syntila-$BUILD_NAME-android$SUFFIX.aab"
  rm -f "$ARTIFACT"
  cp "$BUNDLE" "$ARTIFACT"
  echo "Built distribution bundle: $ARTIFACT"
  exit 0
fi

APK_DIR="$APP_DIR/build/app/outputs/flutter-apk"
if [[ "$SPLIT_PER_ABI" == "1" ]]; then
  flutter build apk "${BUILD_ARGS[@]}" --split-per-abi
  FOUND="0"
  for APK in "$APK_DIR"/app-*-"$MODE".apk; do
    [[ -f "$APK" ]] || continue
    ABI="$(basename "$APK")"
    ABI="${ABI#app-}"
    ABI="${ABI%-"$MODE".apk}"
    ARTIFACT="$DIST_DIR/Syntila-$BUILD_NAME-android-$ABI$SUFFIX.apk"
    rm -f "$ARTIFACT"
    cp "$APK" "$ARTIFACT"
    echo "Built distribution APK: $ARTIFACT"
    FOUND="1"
  done
  if [[ "$FOUND" != "1" ]]; then
    echo "Expected per-ABI APKs were not produced under $APK_DIR" >&2
    exit 1
  fi
  exit 0
fi

flutter build apk "${BUILD_ARGS[@]}"
APK="$APK_DIR/app-$MODE.apk"
if [[ ! -f "$APK" ]]; then
  echo "Expected APK was not produced: $APK" >&2
  exit 1
fi
ARTIFACT="$DIST_DIR/Syntila-$BUILD_NAME-android$SUFFIX.apk"
rm -f "$ARTIFACT"
cp "$APK" "$ARTIFACT"
echo "Built distribution APK: $ARTIFACT"
