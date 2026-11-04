#!/usr/bin/env bash
set -euo pipefail

# Builds the complete Workspace app for macOS: the CLI, service, GUI and
# generic CLI Worker Engine. Flutter requires a native macOS host.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$ROOT/apps/workspace"
ENTITLEMENTS="$ROOT/packaging/macos/workspace-helper.entitlements"
DIST_DIR="$ROOT/dist/syntila/macos"  # suffixed with -local for local builds below

# --all builds the production bundle and then the local one with the remaining
# options, so both end up in their own dist folders (and are installed with
# --install). Each build is a separate invocation of this script.
PASSTHROUGH=()
BUILD_ALL="0"
for arg in "$@"; do
  case "$arg" in
    --all) BUILD_ALL="1" ;;
    --local|--prod|--production) ;;
    *) PASSTHROUGH+=("$arg") ;;
  esac
done
if [[ "$BUILD_ALL" == "1" ]]; then
  bash "$0" --prod ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
  bash "$0" --local ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Syntila Workspace macOS builds must run on macOS." >&2
  exit 1
fi

command -v dart >/dev/null 2>&1 || {
  echo "The Dart SDK is required." >&2
  exit 1
}
command -v ditto >/dev/null 2>&1 || {
  echo "ditto is required on macOS." >&2
  exit 1
}

MODE="release"
TARGET_ENV="${SYNTILA_WORKSPACE_ENVIRONMENT:-production}"
INSTALL_BUNDLE="0"
PREPARED="0"
SIGN_EXPLICIT="0"
[[ -n "${SYNTILA_MACOS_SIGN_IDENTITY:-}" ]] && SIGN_EXPLICIT="1"
DEFAULT_SYNTILA_MACOS_SIGN_IDENTITY='Apple Development: vitalii@nohainc.com (7X62W6499P)'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepared) PREPARED="1"; shift ;;
    --debug) MODE="debug"; shift ;;
    --release) MODE="release"; shift ;;
    --local) TARGET_ENV="local"; shift ;;
    --prod|--production) TARGET_ENV="production"; shift ;;
    --version|-v) SYNTILA_WORKSPACE_VERSION="$2"; shift 2 ;;
    --sign) SYNTILA_MACOS_SIGN_IDENTITY="$2"; SIGN_EXPLICIT="1"; shift 2 ;;
    --all) shift ;;
    --install) INSTALL_BUNDLE="1"; shift ;;
    --help|-h)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Builds the complete Syntila Workspace app for macOS."
      echo "Run pnpm validate:workspace separately for analysis and tests."
      echo ""
      echo "Options:"
      echo "  --prepared         Reuse dependencies and Engine; skip pub get (CI only)"
      echo "  --release          Release build (default); signs with the Apple identity if available"
      echo "  --debug            Ad-hoc signed build; never uses an Apple identity"
      echo "  --local            Local development build: talks to http://localhost:8787 and"
      echo "                     uses separate local state"
      echo "  --prod             Production build (default): talks to https://syntila.app"
      echo "  --version, -v VER  Override workspace version"
      echo "  --sign IDENTITY    Apple signing identity (an unavailable identity is an error)"
      echo "  --all              Build the production bundle, then the local one"
      echo "  --install          Install into ~/.local/lib and link into ~/.local/bin"
      echo "  --help, -h         Show this help message"
      echo ""
      echo "Environment variables:"
      echo "  SYNTILA_WORKSPACE_ENVIRONMENT       local | production (default production)"
      echo "  SYNTILA_WORKSPACE_VERSION           Workspace version override"
      echo "  SYNTILA_MACOS_SIGN_IDENTITY         Signing identity override"
      echo "  SYNTILA_MACOS_NOTARY_PROFILE        Keychain profile for notarization"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

case "$TARGET_ENV" in
  local|production) ;;
  *) echo "Unknown environment '$TARGET_ENV' (expected local or production)." >&2; exit 1 ;;
esac

# A release build uses the default Apple Development identity when it is in
# the keychain; otherwise (and for --debug) the binaries are ad-hoc signed.
# The service is a plain user LaunchAgent, so no Apple identity is required to
# run it; the hardened-runtime entitlements are applied either way.
if [[ "$MODE" == "release" && -z "${SYNTILA_MACOS_SIGN_IDENTITY:-}" ]]; then
  SYNTILA_MACOS_SIGN_IDENTITY="$DEFAULT_SYNTILA_MACOS_SIGN_IDENTITY"
fi
if [[ "$MODE" == "debug" && "$SIGN_EXPLICIT" != "1" ]]; then
  SYNTILA_MACOS_SIGN_IDENTITY=""
fi
if [[ -n "${SYNTILA_MACOS_SIGN_IDENTITY:-}" ]]; then
  if ! security find-identity -v -p codesigning | /usr/bin/grep -F -- "$SYNTILA_MACOS_SIGN_IDENTITY" >/dev/null; then
    if [[ "$SIGN_EXPLICIT" == "1" ]]; then
      echo "The requested signing identity is not available as a valid code-signing identity in Keychain." >&2
      exit 1
    fi
    echo "Default signing identity not found in Keychain; using ad-hoc signatures."
    SYNTILA_MACOS_SIGN_IDENTITY=""
  fi
fi

BUNDLE_NAME="syntila"
ZIP_SUFFIX=""
if [[ "$TARGET_ENV" == "local" ]]; then
  DIST_DIR="$ROOT/dist/syntila/macos-local"
  BUNDLE_NAME="syntila-local"
  ZIP_SUFFIX="-local"
fi

VERSION="${SYNTILA_WORKSPACE_VERSION:-$(awk '/^version:/ {print $2; exit}' "$WORKSPACE_DIR/pubspec.yaml")}"
if [[ -z "$VERSION" ]]; then
  echo "Could not determine Syntila Workspace version." >&2
  exit 1
fi

PUBLIC_RELEASE_ROOTS="$(node "$ROOT/scripts/resolve-build-release-trust.mjs")"
echo "Building Syntila Workspace $VERSION for macOS (mode: $MODE, environment: $TARGET_ENV)"
cd "$WORKSPACE_DIR"
if [[ "$PREPARED" == "1" ]]; then
  [[ -f .dart_tool/package_config.json && -x assets/engines/syntila-agent ]] || {
    echo "Prepared build requires resolved app dependencies and a freshly built Engine." >&2
    exit 1
  }
else
  dart pub get
  bash "$ROOT/scripts/internal/build-cli-worker-engine.sh"
fi
ENGINE="$WORKSPACE_DIR/assets/engines/syntila-agent"
if [[ ! -x "$ENGINE" ]]; then
  echo "The generic CLI Worker Engine is missing: $ENGINE" >&2
  exit 1
fi

BUNDLE="$DIST_DIR/$BUNDLE_NAME"
# Keep a GUI app already built into the shared folder.
rm -rf "$BUNDLE/syntila" "$BUNDLE/workspace" "$BUNDLE/assets" "$DIST_DIR"/*.zip
mkdir -p "$BUNDLE/assets/engines"
dart compile exe \
  --define="SYNTILA_WORKSPACE_VERSION=$VERSION" \
  --define="SYNTILA_WORKSPACE_ENVIRONMENT=$TARGET_ENV" \
  --define="SYNTILA_RELEASE_TRUST_KEYS_JSON=$PUBLIC_RELEASE_ROOTS" \
  --define="SYNTILA_ENTITLEMENT_TRUST_KEYS_JSON=${SYNTILA_ENTITLEMENT_TRUST_KEYS_JSON:-{\}}" \
  --packages="$WORKSPACE_DIR/.dart_tool/package_config.json" \
  "$WORKSPACE_DIR/bin/syntila_workspace.dart" \
  -o "$BUNDLE/syntila"
cp "$ENGINE" "$BUNDLE/assets/engines/syntila-agent"
chmod 755 "$BUNDLE/syntila" "$BUNDLE/assets/engines/syntila-agent"

SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS")
if [[ -n "${SYNTILA_MACOS_SIGN_IDENTITY:-}" ]]; then
  echo "Signing with configured Apple identity"
  SIGN_ARGS+=(--timestamp --sign "$SYNTILA_MACOS_SIGN_IDENTITY")
else
  echo "Sealing the bundle with ad-hoc signatures."
  SIGN_ARGS+=(--sign -)
fi
# Dart AOT executables map executable memory; the hardened runtime needs the
# helper entitlements or launchd kills them with OS_REASON_CODESIGNING.
codesign "${SIGN_ARGS[@]}" --identifier "syntila-agent" "$BUNDLE/assets/engines/syntila-agent"
codesign "${SIGN_ARGS[@]}" --identifier "syntila" "$BUNDLE/syntila"

bash "$ROOT/scripts/verify-workspace-service-bundle.sh" "$BUNDLE"
SYNTILA_WORKSPACE_ENVIRONMENT="$TARGET_ENV" node "$ROOT/scripts/workspace-build-manifest.mjs" record "$BUNDLE" "$VERSION"

ZIP="$DIST_DIR/Syntila-Workspace-$VERSION-macos$ZIP_SUFFIX.zip"
# The public platform builder always includes the GUI. The internal helper
# reuses this service bundle and re-creates the final, signed archive.
GUI_ARGS=(--gui-only "--$TARGET_ENV" --version "$VERSION")
[[ -z "${SYNTILA_MACOS_SIGN_IDENTITY:-}" ]] || GUI_ARGS+=(--sign "$SYNTILA_MACOS_SIGN_IDENTITY")
bash "$ROOT/scripts/internal/build-workspace-gui-macos.sh" "${GUI_ARGS[@]}"

echo "Built bundle: $BUNDLE"
echo "Built distribution archive: $ZIP"

if [[ "$INSTALL_BUNDLE" == "1" ]]; then
  INSTALL_ROOT="$HOME/.local/lib/$BUNDLE_NAME"
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$HOME/.local/lib" "$BIN_DIR"
  rm -rf "$INSTALL_ROOT"
  ditto "$BUNDLE" "$INSTALL_ROOT"
  if [[ "$TARGET_ENV" == "local" ]]; then
    ln -sf "$INSTALL_ROOT/syntila" "$BIN_DIR/syntila-local"
  else
    ln -sf "$INSTALL_ROOT/syntila" "$BIN_DIR/syntila"
    rm -f "$BIN_DIR/workspace"
  fi
  echo "Installed: $INSTALL_ROOT (links in $BIN_DIR; make sure it is on PATH)"
  echo "Restart a running service with: $BIN_DIR/syntila$([[ "$TARGET_ENV" == "local" ]] && echo -local) service restart"
fi
