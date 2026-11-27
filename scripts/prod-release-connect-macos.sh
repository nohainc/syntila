#!/usr/bin/env bash
# Publishes the macOS build from scripts/prod-build-connect-macos.sh as the GitHub
# Release connect-macos-v<version> (needs the gh CLI, logged in).
#
#   scripts/prod-release-connect-macos.sh [--yes] [--dry-run] [--allow-dirty]
# Refuses when the build is from another commit or version, when the checksums
# do not verify, or when the release already exists.
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
parse_flags "$@"
version=$(connect_version)
say "Release Connect for macOS $version: $(git_state)"
require_clean_main
check_connect_build macos "$version"
dir="$CONNECT_RELEASE_DIR/macos"
files=(); for f in "$dir"/Syntila-Connect-*.tar.gz "$dir"/Syntila-Connect-*-app.zip "$dir/SHA256SUMS"; do [ -f "$f" ] && files+=("$f"); done
create_connect_release macos "connect-macos-v$version" "Syntila Connect $version for macOS" \
  "Syntila Connect $version for macOS. Ad-hoc signed, not notarized: if macOS blocks the app, run xattr -dr com.apple.quarantine on it. Verify downloads with SHA256SUMS." \
  "${files[@]}"
echo "Next: scripts/prod-publish-connect-macos.sh"
