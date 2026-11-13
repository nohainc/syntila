#!/usr/bin/env bash
# ==============================================================================
# Syntila - Local Stack Launcher
# ==============================================================================
# Launches dedicated terminal windows in parallel:
#   1. Backend: Bun + local PostgreSQL on :8788 (product API, realtime, Workspaces)
#   2. Auth: Cloudflare Wrangler (Better Auth, desktop sign-in, backend tokens,
#      email relay) with the local auth-only D1 database on :8787
#   3. AX web app: Flutter run with Hot Reload ('r'/'R') + Google Chrome
#
# Prints 2 concise status lines on the main terminal and exits immediately.
#
# Optional environment:
#   EXTRA_DART_DEFINES  Space-separated KEY=VALUE pairs passed to Flutter as
#                       extra --dart-define flags.
#   LOCAL_LOG_DIR       Also save each window's output to api.log and web.log
#                       in this folder (relative paths are from the repo root).
# ==============================================================================

set -euo pipefail

# ANSI color codes
BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
RESET=$'\033[0m'

PORT="${PORT:-8787}"
# Keep the server bind address separate from the browser-facing hostname.
# `localhost` and `127.0.0.1` are different cookie sites, so using one for
# the API and the other for Flutter causes Better Auth's session cookie to be
# omitted from the follow-up /api/session request.
IP="${IP:-127.0.0.1}"
API_HOST="${API_HOST:-localhost}"
DEVICE="${DEVICE:-chrome}"
WEB_PORT="${WEB_PORT:-3000}"
BACKEND_PORT="${BACKEND_PORT:-8788}"
ISOLATED=true
WEB_BUILD_MODE=debug

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  echo "Usage: pnpm start:local [--proxy] [--isolated] [--web-release] [-p port] [-d device] [-i ip] [--web-port port] [--api-host host]"
}

option_value() {
  local option="$1"
  if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
    echo "Error: ${option} requires a value." >&2
    usage >&2
    exit 2
  fi
}

# Parse optional arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --web-release)
      WEB_BUILD_MODE=release
      shift
      ;;
    --isolated)
      ISOLATED=true
      shift
      ;;
    --proxy)
      ISOLATED=false
      shift
      ;;
    -d|--device)
      option_value "$@"
      DEVICE="$2"
      shift 2
      ;;
    -p|--port)
      option_value "$@"
      PORT="$2"
      shift 2
      ;;
    -i|--ip)
      option_value "$@"
      IP="$2"
      shift 2
      ;;
    --api-host)
      option_value "$@"
      API_HOST="$2"
      shift 2
      ;;
    --web-port)
      option_value "$@"
      WEB_PORT="$2"
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

API_URL="http://${API_HOST}:${PORT}"
BACKEND_URL="http://${API_HOST}:${BACKEND_PORT}"
EXTRA_DART_DEFINE_FLAGS=""
for define in ${EXTRA_DART_DEFINES:-}; do
  if [[ "${define}" != *=* ]]; then
    echo "Error: EXTRA_DART_DEFINES entries must be KEY=VALUE (got '${define}')." >&2
    exit 2
  fi
  EXTRA_DART_DEFINE_FLAGS+=" --dart-define=${define}"
done
API_LOG_PIPE=""
WEB_LOG_PIPE=""
if [[ -n "${LOCAL_LOG_DIR:-}" ]]; then
  [[ "${LOCAL_LOG_DIR}" == /* ]] || LOCAL_LOG_DIR="${ROOT_DIR}/${LOCAL_LOG_DIR}"
  mkdir -p "${LOCAL_LOG_DIR}"
  API_LOG_PIPE=" 2>&1 | tee \"${LOCAL_LOG_DIR}/api.log\""
  WEB_LOG_PIPE=" 2>&1 | tee \"${LOCAL_LOG_DIR}/web.log\""
fi
WEB_URL="http://localhost:${WEB_PORT}"
FLUTTER_BIN="${FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "${FLUTTER_BIN}" && -x "/Users/${USER}/development/flutter/bin/flutter" ]]; then
  FLUTTER_BIN="/Users/${USER}/development/flutter/bin/flutter"
fi
if [[ -z "${FLUTTER_BIN}" || ! -x "${FLUTTER_BIN}" ]]; then
  echo "Error: Flutter SDK was not found. Set FLUTTER_BIN to its flutter executable." >&2
  exit 1
fi
FLUTTER_ROOT="$(cd "$(dirname "${FLUTTER_BIN}")/.." && pwd)"
FLUTTER_ENGINE_VERSION="$(<"${FLUTTER_ROOT}/bin/internal/engine.version")"
if [[ "$ISOLATED" == true ]]; then
  node "$ROOT_DIR/scripts/setup-development-auth.mjs"
  for provider in GOOGLE GITHUB; do
    if ! grep -Eq "^SYNTILA_AUTH_${provider}_CLIENT_ID=.+" "$ROOT_DIR/apps/cloud/.dev.vars" 2>/dev/null; then
      label="$(printf '%s' "${provider:0:1}${provider:1}" | tr '[:upper:]' '[:lower:]')"
      echo "Note: ${label} sign-in is not configured for this local backend (see docs/deployment/CLOUDFLARE.md#${label}-sign-in)."
    fi
  done
  node "$ROOT_DIR/scripts/setup-local-backend.mjs"
  bash "$ROOT_DIR/scripts/migrate-local-d1.sh" >/dev/null
  API_CONFIG="$ROOT_DIR/apps/cloud/wrangler.jsonc"
  API_MODE="local auth (D1) + local backend (PostgreSQL)"
else
  API_CONFIG="$ROOT_DIR/scripts/local-cloud-proxy.wrangler.jsonc"
  API_MODE="production Cloud gateway — live accounts and data"
  # Production backend; it must list http://localhost:${WEB_PORT} in ALLOWED_ORIGINS.
  BACKEND_URL="https://api.syntila.app"
fi

# 1. Runner Script for Backend API
RUNNER_API="/tmp/syntila-api-dev-${PORT}.sh"
cat << EOF > "${RUNNER_API}"
#!/usr/bin/env bash
set -euo pipefail
cd "${ROOT_DIR}"
echo -e "\033[1m\033[0;34m[Syntila API Backend Logs]\033[0m ${API_MODE} | Base: ${API_URL}\n"
pnpm exec wrangler dev \\
  --config "${API_CONFIG}" \\
  --port "${PORT}" \\
  --ip "${IP}" \\
  --var "BETTER_AUTH_URL:${API_URL}" \\
  --var "SYNTILA_APP_URL:${WEB_URL}" \\
  --var "SYNTILA_BACKEND_URL:${BACKEND_URL}" \\
  --var "BETTER_AUTH_TRUSTED_ORIGINS:${API_URL},${WEB_URL},http://localhost:${PORT},http://127.0.0.1:${PORT},https://syntila.app"${API_LOG_PIPE}
EOF
chmod +x "${RUNNER_API}"

# 2. Runner Script for Frontend Web App
if [[ "$WEB_BUILD_MODE" == release ]]; then
  WEB_CONTROLS="Release rendering | [q] Quit | stop and relaunch to rebuild"
else
  WEB_CONTROLS="Controls: [r] Reload | [R] Restart | [q] Quit"
fi
# Flutter starts Chrome with a throwaway profile, so the session cookie is lost
# on every launch and you sign in again each time. A persistent profile under
# the git-ignored .development folder keeps the local sign-in between runs.
# Set LOCAL_CHROME_PROFILE=off for a clean browser, or to a path to relocate it.
WEB_BROWSER_FLAGS=""
if [[ "${DEVICE}" == "chrome" || "${DEVICE}" == "web-server" ]] && [[ "${LOCAL_CHROME_PROFILE:-}" != "off" ]]; then
  CHROME_PROFILE_DIR="${LOCAL_CHROME_PROFILE:-${ROOT_DIR}/.development/chrome-profile}"
  mkdir -p "${CHROME_PROFILE_DIR}"
  WEB_BROWSER_FLAGS="--web-browser-flag=--user-data-dir=${CHROME_PROFILE_DIR}"
fi
RUNNER_FLUTTER="/tmp/syntila-flutter-dev-${PORT}.sh"
cat << EOF > "${RUNNER_FLUTTER}"
#!/usr/bin/env bash
set -euo pipefail
cd "${ROOT_DIR}/apps/app"
echo -e "\033[1m\033[0;32m[Syntila Flutter Web]\033[0m ${WEB_CONTROLS}\n"
export FLUTTER_PREBUILT_ENGINE_VERSION="${FLUTTER_ENGINE_VERSION}"
"${FLUTTER_BIN}" run --${WEB_BUILD_MODE} -d "${DEVICE}" --web-port="${WEB_PORT}" ${WEB_BROWSER_FLAGS} --dart-define="SYNTILA_API_URL=${API_URL}/api" --dart-define="SYNTILA_BACKEND_API_URL=${BACKEND_URL}/api"${EXTRA_DART_DEFINE_FLAGS}${WEB_LOG_PIPE}
EOF
chmod +x "${RUNNER_FLUTTER}"

# Function to spawn a terminal
spawn_terminal() {
  local script_path="$1"
  local title="$2"
  if [[ "$OSTYPE" == "darwin"* ]] && command -v osascript >/dev/null 2>&1; then
    osascript -e "tell application \"Terminal\" to do script \"${script_path}\"" >/dev/null 2>&1
    osascript -e "tell application \"Terminal\" to activate" >/dev/null 2>&1
  elif command -v x-terminal-emulator >/dev/null 2>&1; then
    x-terminal-emulator -T "${title}" -e "${script_path}" &
  elif command -v gnome-terminal >/dev/null 2>&1; then
    gnome-terminal --title="${title}" -- "${script_path}" &
  elif command -v konsole >/dev/null 2>&1; then
    konsole --title "${title}" -e "${script_path}" &
  elif command -v kitty >/dev/null 2>&1; then
    kitty --title "${title}" "${script_path}" &
  elif command -v alacritty >/dev/null 2>&1; then
    alacritty --title "${title}" -e "${script_path}" &
  else
    "${script_path}" &
  fi
}

# Launch the terminals in parallel
if [[ "$ISOLATED" == true ]]; then
  RUNNER_BACKEND="/tmp/syntila-backend-dev-${BACKEND_PORT}.sh"
  printf '#!/usr/bin/env bash\nBACKEND_PORT=%q AUTH_PORT=%q WEB_PORT=%q exec bash %q\n' \
    "${BACKEND_PORT}" "${PORT}" "${WEB_PORT}" "${ROOT_DIR}/scripts/start-local-backend.sh" > "${RUNNER_BACKEND}"
  chmod +x "${RUNNER_BACKEND}"
  spawn_terminal "${RUNNER_BACKEND}" "Syntila - Backend"
fi
spawn_terminal "${RUNNER_API}" "Syntila - Auth"
spawn_terminal "${RUNNER_FLUTTER}" "Syntila - Web App"

echo -e "${GREEN}✓ Syntila started in new terminals (Backend, Auth & Web App in parallel).${RESET}"
echo -e "${CYAN}• Web App:${RESET} ${BOLD}${WEB_URL}${RESET} | ${CYAN}Auth:${RESET} ${BOLD}${API_URL}${RESET} | ${CYAN}Backend:${RESET} ${BOLD}${BACKEND_URL}${RESET} (${API_MODE})"
