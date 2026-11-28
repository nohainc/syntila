#!/usr/bin/env bash
# Publishes the verified Connect build to the public R2 releases bucket.
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
parse_flags "$@"
version=$(connect_version)
say "Release Connect for macOS $version: $(git_state)"
require_clean_main
check_connect_build macos "$version"
dir="$CONNECT_RELEASE_DIR/macos"
files=(); for f in "$dir"/Syntila-Connect-*.tar.gz "$dir"/Syntila-Connect-*-app.zip "$dir/SHA256SUMS"; do [ -f "$f" ] && files+=("$f"); done
create_connect_release macos "Syntila Connect $version" \
  "Syntila Connect $version for Windows, macOS and Linux. Each platform adds its own files to this release: Windows installer and portable zip, macOS tar.gz and app zip, Linux .deb and tarballs. Builds are not notarized or code signed (Windows SmartScreen and macOS Gatekeeper may warn). Verify downloads with SHA256SUMS-<platform>." \
  "${files[@]}"
echo "Next: scripts/prod-publish-connect-macos.sh"
