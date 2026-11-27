#!/usr/bin/env bash
# Publishes the Linux build from scripts/prod-build-connect-linux.sh as the GitHub
# Release connect-linux-v<version> (needs the gh CLI, logged in).
#
#   scripts/prod-release-connect-linux.sh [--yes] [--dry-run] [--allow-dirty]
# Refuses when the build is from another commit or version, when the checksums
# do not verify, or when the release already exists.
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
parse_flags "$@"
version=$(connect_version)
say "Release Connect for Linux $version: $(git_state)"
require_clean_main
check_connect_build linux "$version"
dir="$CONNECT_RELEASE_DIR/linux"
files=(); for f in "$dir"/*.deb "$dir"/Syntila-Connect-*.tar.gz "$dir/SHA256SUMS"; do [ -f "$f" ] && files+=("$f"); done
create_connect_release linux "connect-linux-v$version" "Syntila Connect $version for Linux" \
  "Syntila Connect $version for Linux (amd64 and arm64): .deb packages and tarballs. Install from the APT repository or download a .deb; verify downloads with SHA256SUMS." \
  "${files[@]}"
echo "Next: scripts/prod-publish-connect-linux.sh"
