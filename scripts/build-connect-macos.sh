#!/usr/bin/env bash
set -euo pipefail

# Builds the Syntila Connect for macOS, with Syntila Connect (GUI):
#   - the Agent CLI (`syntila-connect`) and the Syntila Worker (the generic CLI Worker Engine) it
#     supervises, compiled to native executables;
#   - Syntila Connect (apps/connect_gui), a macOS app that bundles the Agent CLI.
# Everything lands in dist/connect/macos-<env>/. It does not touch the
# Workspace or Profile Lab engine copies.
#
#   scripts/build-connect-macos.sh           local build (default): trusts the local
#                                            Profile signing key from
#                                            .development/local-profile-signing
#   scripts/build-connect-macos.sh --prod    production build: needs
#                                            SYNTILA_PROFILE_TRUST_ROOTS (JSON) and
#                                            SYNTILA_UPDATE_KEYS (comma list) in the
#                                            environment
#   --sign IDENTITY                          codesign with this identity (default: ad hoc)
#   --skip-gui                               build only the CLI and engine (no Flutter)
#
# The GUI needs the Flutter SDK. On first build the script adds the macOS runner
# to apps/connect_gui and turns off the App Sandbox there: the sandbox would stop
# the app from starting the CLI and from reading the Worker's data directory.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_DIR="$ROOT/apps/connect"
ENGINE_DIR="$ROOT/engines/cli_worker"
GUI_DIR="$ROOT/apps/connect_gui"
TARGET_ENV="local"
SIGN_IDENTITY="-"
BUILD_GUI=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) TARGET_ENV="local"; shift ;;
    --prod|--production) TARGET_ENV="production"; shift ;;
    --sign) SIGN_IDENTITY="$2"; shift 2 ;;
    --skip-gui) BUILD_GUI=0; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "This build must run on macOS." >&2; exit 1; }
command -v dart >/dev/null 2>&1 || { echo "The Dart SDK is required." >&2; exit 1; }
if [[ "$BUILD_GUI" == 1 ]]; then
  command -v flutter >/dev/null 2>&1 || {
    echo "The Flutter SDK is required for the GUI (use --skip-gui to build the CLI only)." >&2
    exit 1
  }
fi

if [[ "$TARGET_ENV" == "local" ]]; then
  node "$ROOT/scripts/setup-local-profile-signing.mjs"
  TRUST_ROOTS="$(cat "$ROOT/.development/local-profile-signing/trust-roots.json")"
  UPDATE_KEYS="${SYNTILA_UPDATE_KEYS:-}"
else
  TRUST_ROOTS="${SYNTILA_PROFILE_TRUST_ROOTS:-}"
  UPDATE_KEYS="${SYNTILA_UPDATE_KEYS:-}"
  [[ -n "$TRUST_ROOTS" && -n "$UPDATE_KEYS" ]] || {
    echo "A production build needs SYNTILA_PROFILE_TRUST_ROOTS and SYNTILA_UPDATE_KEYS." >&2
    exit 1
  }
fi

ENGINE_VERSION="$(awk '/^version:/ {print $2; exit}' "$ENGINE_DIR/pubspec.yaml")"
AGENT_VERSION="$(sed -n "s/^const agentVersion = '\(.*\)';/\1/p" "$AGENT_DIR/lib/src/cli.dart")"
OUT="$ROOT/dist/connect/macos-$TARGET_ENV"
rm -rf "$OUT"
mkdir -p "$OUT/engine"

echo "Engine $ENGINE_VERSION"
(cd "$ENGINE_DIR" && dart pub get >/dev/null \
  && dart compile exe "-DENGINE_VERSION=$ENGINE_VERSION" bin/syntila_cli_worker.dart -o "$OUT/engine/syntila-worker")

echo "Agent $AGENT_VERSION ($TARGET_ENV)"
(cd "$AGENT_DIR" && dart pub get >/dev/null \
  && dart compile exe \
    "--define=SYNTILA_PROFILE_TRUST_ROOTS=$TRUST_ROOTS" \
    "--define=SYNTILA_UPDATE_KEYS=$UPDATE_KEYS" \
    bin/syntila_connect.dart -o "$OUT/syntila-connect")

chmod 755 "$OUT/syntila-connect" "$OUT/engine/syntila-worker"
for binary in "$OUT/syntila-connect" "$OUT/engine/syntila-worker"; do
  codesign --force --sign "$SIGN_IDENTITY" "$binary"
done
(cd "$OUT" && shasum -a 256 syntila-connect engine/syntila-worker > SHA256SUMS)

GUI_APP=""
if [[ "$BUILD_GUI" == 1 ]]; then
  echo "GUI (apps/connect_gui)"
  (
    cd "$GUI_DIR"
    if [[ ! -d macos ]]; then
      flutter create --platforms=macos --project-name syntila_connect_gui .
    fi
    for entitlements in macos/Runner/*.entitlements; do
      /usr/libexec/PlistBuddy -c "Set :com.apple.security.app-sandbox false" "$entitlements" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool false" "$entitlements"
    done
    flutter pub get >/dev/null
    flutter build macos --release
  )
  APP_SRC="$(ls -d "$GUI_DIR"/build/macos/Build/Products/Release/*.app | head -1)"
  mkdir -p "$OUT/gui"
  cp -R "$APP_SRC" "$OUT/gui/"
  GUI_APP="$OUT/gui/$(basename "$APP_SRC")"
  # The GUI finds the CLI at Contents/Resources/syntila-connect, so the app
  # and the CLI it runs are always the same build.
  cp "$OUT/syntila-connect" "$GUI_APP/Contents/Resources/syntila-connect"
  chmod 755 "$GUI_APP/Contents/Resources/syntila-connect"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$GUI_APP"
fi

cat <<DONE

Built: $OUT
  $OUT/syntila-connect              the Agent
  $OUT/engine/syntila-worker   the Syntila Worker Engine${GUI_APP:+
  $GUI_APP   the GUI (runs the Agent bundled inside it)}

First run (pairing code from Settings > Workers > the Worker's menu > Pair):
  export SYNTILA_WORKER_DATA_DIR="\$HOME/.syntila-worker-dev"
  $OUT/syntila-connect pair --pairing-code CODE --no-service
  $OUT/syntila-connect folders work-root "\$HOME/syntila-work"
  $OUT/syntila-connect folders add "\$HOME/some/project" --write

Start it:
  $OUT/syntila-connect run
Status:
  $OUT/syntila-connect status
DONE
