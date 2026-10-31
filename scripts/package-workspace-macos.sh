#!/usr/bin/env bash
set -euo pipefail

# Packages a built macOS Workspace bundle (syntila, the `workspace`
# alias, the CLI Worker Engine and, when built, "Syntila Workspace.app") into
# an installer .pkg that installs under /usr/local/lib, links the commands into
# /usr/local/bin and the GUI into /Applications. The installer does
# not register or start the service; run `syntila service install`
# afterwards. Existing Application Support state (installation ID, credentials,
# Work Root, sessions) is never touched.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ENV="production"
BUNDLE=""
BUILD="0"
FORMATS="pkg"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) TARGET_ENV="local"; shift ;;
    --prod|--production) TARGET_ENV="production"; shift ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    --build) BUILD="1"; shift ;;
    --format) FORMATS="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $(basename "$0") [options]"
      echo ""
      echo "Packages the built Workspace bundle into an installer .pkg."
      echo ""
      echo "Options:"
      echo "  --build            Run build-workspace-macos.sh first"
      echo "  --local | --prod   Which built variant to package (default prod)"
      echo "  --bundle PATH      Package this bundle directory instead of the dist copy"
      echo "  --format pkg       Only pkg is supported (the zip comes from the build)"
      echo ""
      echo "Environment variables:"
      echo "  SYNTILA_MACOS_INSTALLER_SIGN_IDENTITY  'Developer ID Installer: ...' for the .pkg"
      echo "  SYNTILA_MACOS_NOTARY_PROFILE           notarytool keychain profile"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$FORMATS" != "pkg" ]]; then
  echo "Only --format pkg is supported; the zip archive is produced by build-workspace-macos.sh." >&2
  exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS installers must be built on macOS." >&2
  exit 1
fi

DIST_DIR="$ROOT/dist/syntila/macos"
BUNDLE_NAME="syntila"
PKG_ID="com.syntila.workspace.pkg"
SUFFIX=""
if [[ "$TARGET_ENV" == "local" ]]; then
  DIST_DIR="$ROOT/dist/syntila/macos-local"
  BUNDLE_NAME="syntila-local"
  PKG_ID="com.syntila.workspace.local.pkg"
  SUFFIX="-local"
fi

if [[ "$BUILD" == "1" ]]; then
  bash "$ROOT/scripts/build-workspace-macos.sh" "--$TARGET_ENV"
fi

BUNDLE="${BUNDLE:-$DIST_DIR/$BUNDLE_NAME}"
if [[ ! -d "$BUNDLE" ]]; then
  echo "Bundle not found: $BUNDLE" >&2
  echo "Build it first: pnpm workspace:build:macos (or pass --build)." >&2
  exit 1
fi

# Refuse to ship a bundle without the service binary and Engine.
bash "$ROOT/scripts/verify-workspace-service-bundle.sh" "$BUNDLE"

VERSION="${SYNTILA_WORKSPACE_VERSION:-$(awk '/^version:/ {print $2; exit}' "$ROOT/apps/workspace/pubspec.yaml")}"
PKG="$DIST_DIR/Syntila-Workspace-$VERSION-macos$SUFFIX.pkg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
LIB="$STAGING/root/usr/local/lib/$BUNDLE_NAME"
BIN="$STAGING/root/usr/local/bin"
mkdir -p "$LIB" "$BIN"
ditto "$BUNDLE" "$LIB"
if [[ "$TARGET_ENV" == "local" ]]; then
  ln -s "../lib/$BUNDLE_NAME/syntila" "$BIN/syntila-local"
else
  ln -s "../lib/$BUNDLE_NAME/syntila" "$BIN/syntila"
fi
GUI_APP="Syntila Workspace.app"
if [[ -d "$LIB/$GUI_APP" ]]; then
  APP_LINK="$GUI_APP"
  [[ "$TARGET_ENV" == "local" ]] && APP_LINK="Syntila Workspace (local).app"
  mkdir -p "$STAGING/root/Applications"
  ln -s "/usr/local/lib/$BUNDLE_NAME/$GUI_APP" "$STAGING/root/Applications/$APP_LINK"
else
  echo "No GUI in the bundle; packaging the CLI only (run build-workspace-gui-macos.sh first to include it)."
fi
xattr -crs "$STAGING/root"

COMPONENT="$STAGING/component.pkg"
COPYFILE_DISABLE=1 pkgbuild --root "$STAGING/root" \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  --install-location / \
  "$COMPONENT" >/dev/null
SIGN_ARGS=()
if [[ -n "${SYNTILA_MACOS_INSTALLER_SIGN_IDENTITY:-}" ]]; then
  SIGN_ARGS=(--sign "$SYNTILA_MACOS_INSTALLER_SIGN_IDENTITY" --timestamp)
else
  echo "SYNTILA_MACOS_INSTALLER_SIGN_IDENTITY is not set; the .pkg is unsigned."
fi
rm -f "$PKG"
productbuild --package "$COMPONENT" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$PKG" >/dev/null

if [[ -n "${SYNTILA_MACOS_NOTARY_PROFILE:-}" ]]; then
  echo "Notarizing $(basename "$PKG")"
  xcrun notarytool submit "$PKG" \
    --keychain-profile "$SYNTILA_MACOS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi
echo "Built installer package: $PKG"
