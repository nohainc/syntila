#!/usr/bin/env bash
# Syntila Connect (apps/connect): format check, analysis and tests.
#   scripts/test-connect.sh [dart test args...]   e.g. scripts/test-connect.sh test/folders_artifacts_test.dart
set -euo pipefail
export PATH="$HOME/development/flutter/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/../apps/connect"
command -v dart >/dev/null 2>&1 || { echo "dart not found in PATH." >&2; exit 1; }
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze
dart test "$@"
