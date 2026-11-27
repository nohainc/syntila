#!/usr/bin/env bash
# Publishes the Linux build from scripts/prod-build-connect-linux.sh as the GitHub
# Release connect-v<version> (needs the gh CLI, logged in). All platforms share that
# release: the first one creates it, the others add their files.
#
#   scripts/prod-release-connect-linux.sh [--yes] [--dry-run] [--allow-dirty]
# Refuses when the build is from another commit or version, when the checksums
# do not verify, when the release exists on another commit, or when it already has one of
# the files.
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
parse_flags "$@"
version=$(connect_version)
say "Release Connect for Linux $version: $(git_state)"
require_clean_main
check_connect_build linux "$version"
dir="$CONNECT_RELEASE_DIR/linux"
files=(); for f in "$dir"/*.deb "$dir"/Syntila-Connect-*.tar.gz "$dir/SHA256SUMS"; do [ -f "$f" ] && files+=("$f"); done
create_connect_release linux "Syntila Connect $version" \
  "Syntila Connect $version for Windows, macOS and Linux. Each platform adds its own files to this release: Windows installer and portable zip, macOS tar.gz and app zip, Linux .deb and tarballs. Builds are not notarized or code signed (Windows SmartScreen and macOS Gatekeeper may warn). Verify downloads with SHA256SUMS-<platform>." \
  "${files[@]}"
echo "Next: scripts/prod-publish-connect-linux.sh"
