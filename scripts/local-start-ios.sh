#!/usr/bin/env bash
# ==============================================================================
# Syntila - iOS Simulator Launcher
# ==============================================================================
# Installs and starts the built Syntila iOS app (apps/app) in the iOS Simulator.
# Builds the Simulator app first when it is missing or --build is passed.
#
# The local build talks to http://localhost:8787/api; start the backend
# separately (pnpm start:local) or pass --prod to use https://syntila.app/api.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP="${ROOT_DIR}/apps/app/build/ios/iphonesimulator/Runner.app"

DEVICE="${DEVICE:-}"
DEFAULT_DEVICE="iPhone 17"
BUILD=false
BUILD_ARGS=(--simulator --local)

usage() {
  echo "Usage: pnpm app:run:ios [--build] [--prod] [--api-url url] [-d device]"
  echo ""
  echo "  --build          Rebuild the Simulator app before starting it"
  echo "  --prod           Build against https://syntila.app/api (implies --build)"
  echo "  --api-url URL    Build against a custom Cloud API URL (implies --build)"
  echo "  -d, --device D   Simulator name or UDID (default: the booted simulator,"
  echo "                   otherwise ${DEFAULT_DEVICE})"
}

option_value() {
  local option="$1"
  if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
    echo "Error: ${option} requires a value." >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD=true
      shift
      ;;
    --prod|--production)
      BUILD=true
      BUILD_ARGS=(--simulator --prod)
      shift
      ;;
    --api-url)
      option_value "$@"
      BUILD=true
      BUILD_ARGS+=(--api-url "$2")
      shift 2
      ;;
    -d|--device)
      option_value "$@"
      DEVICE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: the iOS Simulator requires macOS." >&2
  exit 1
fi
command -v xcrun >/dev/null 2>&1 || {
  echo "Error: Xcode command line tools are required." >&2
  exit 1
}

if [[ "${BUILD}" == true || ! -d "${APP}" ]]; then
  if ! command -v flutter >/dev/null 2>&1 \
    && [[ -x "/Users/${USER}/development/flutter/bin/flutter" ]]; then
    PATH="/Users/${USER}/development/flutter/bin:${PATH}"
  fi
  bash "${SCRIPT_DIR}/build-app-ios.sh" "${BUILD_ARGS[@]}"
fi

# Resolve the target simulator to a UDID.
DEVICES="$(xcrun simctl list devices available)"
if [[ -z "${DEVICE}" ]]; then
  UDID="$(grep '(Booted)' <<<"${DEVICES}" | head -n 1 \
    | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' || true)"
  [[ -n "${UDID}" ]] || DEVICE="${DEFAULT_DEVICE}"
fi
if [[ -n "${DEVICE}" ]]; then
  UDID="$(grep -E "^ +${DEVICE} \(|\(${DEVICE}\)" <<<"${DEVICES}" | head -n 1 \
    | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' || true)"
  if [[ -z "${UDID}" ]]; then
    echo "Error: no available simulator matches '${DEVICE}'." >&2
    echo "List simulators with: xcrun simctl list devices available" >&2
    exit 1
  fi
fi

# The simulator window is Simulator.app in older Xcode releases and Device Hub
# in newer ones; neither is reliably registered by name.
show_simulator_window() {
  local xcode_contents viewer
  xcode_contents="$(dirname "$(xcode-select -p)")"
  for viewer in \
    "${xcode_contents}/Developer/Applications/Simulator.app" \
    "${xcode_contents}/Applications/Simulator.app" \
    "${xcode_contents}/Applications/DeviceHub.app"; do
    if [[ -d "${viewer}" ]]; then
      if [[ "${viewer}" == *Simulator.app ]]; then
        open "${viewer}" --args -CurrentDeviceUDID "$1" && return 0
      else
        open "${viewer}" && return 0
      fi
    fi
  done
  echo "Warning: could not open a simulator window; the app still runs headless." >&2
}

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Info.plist")"

xcrun simctl bootstatus "${UDID}" -b >/dev/null
show_simulator_window "${UDID}"
xcrun simctl install "${UDID}" "${APP}"
xcrun simctl launch --terminate-running-process "${UDID}" "${BUNDLE_ID}" >/dev/null

echo "Syntila (${BUNDLE_ID}) is running in simulator ${UDID}."
