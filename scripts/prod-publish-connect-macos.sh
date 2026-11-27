#!/usr/bin/env bash
# Publishes the macOS build from scripts/prod-build-connect-macos.sh to the Homebrew tap
# nohainc/homebrew-tap: a formula (syntila-connect: CLI and Worker Engine) and a cask
# (syntila-connect-app: desktop app). Both download the GitHub Release assets, so run
# scripts/prod-release-connect-macos.sh first.
#
#   scripts/prod-publish-connect-macos.sh [--create-tap] [--prune-legacy] [--yes] [--dry-run] [--allow-dirty]
#
# --create-tap creates the public tap repository when it does not exist.
# --prune-legacy removes the old Workspace cask (syntila-workspace-preview) from the tap.
# Install: brew install nohainc/tap/syntila-connect
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
PROD_EXTRA_FLAGS="--create-tap --prune-legacy"
parse_flags "$@"
create_tap=0; prune=0; for a in "$@"; do case "$a" in --create-tap) create_tap=1;; --prune-legacy) prune=1;; esac; done
require git; require gh
version=$(connect_version)
owner_repo=$(git -C "$ROOT" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
owner=${owner_repo%%/*}; repo=${owner_repo#*/}
say "Publish Connect $version to Homebrew: $(git_state)"
require_clean_main

publish_homebrew() {
  check_connect_build macos "$version"
  local tap="homebrew-tap" dir="$CONNECT_RELEASE_DIR/macos" tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  local arch tarball app url_base="https://github.com/$owner_repo/releases/download/connect-v$version"
  arch=$(sed -n 's/.*"arch": *"\([^"]*\)".*/\1/p' "$dir/build.json")
  [ "$arch" = arm64 ] || die "The macOS build is $arch; the formula supports Apple silicon (arm64) only."
  tarball="Syntila-Connect-$version-macos-$arch.tar.gz"
  [ "$DRY_RUN" = 1 ] || gh release view "connect-v$version" --json assets --jq '.assets[].name' 2>/dev/null | grep -qx "$tarball" || die "Release connect-v$version has no $tarball. Run scripts/prod-release-connect-macos.sh first."
  if ! gh repo view "$owner/$tap" >/dev/null 2>&1; then
    [ "$create_tap" = 1 ] || die "The tap $owner/$tap does not exist. Run again with --create-tap to create it (public)."
    confirm "Create the public repository $owner/$tap."
    run gh repo create "$owner/$tap" --public --description "Homebrew tap for Syntila Connect"
  fi
  if [ "$DRY_RUN" = 1 ] && ! gh repo view "$owner/$tap" >/dev/null 2>&1; then
    mkdir -p "$tmp/tap"; git -C "$tmp/tap" init -q
  else
    gh repo clone "$owner/$tap" "$tmp/tap" -- -q 2>/dev/null || { mkdir -p "$tmp/tap"; git -C "$tmp/tap" init -q -b main; git -C "$tmp/tap" remote add origin "https://github.com/$owner/$tap.git"; }
  fi
  mkdir -p "$tmp/tap/Formula" "$tmp/tap/Casks"
  [ "$prune" = 0 ] || rm -f "$tmp/tap/Casks/syntila-workspace-preview.rb"
  local sha; sha=$(shasum -a 256 "$dir/$tarball" | cut -d' ' -f1)
  sed -e "s#@VERSION@#$version#" -e "s#@URL@#$url_base/$tarball#" -e "s#@SHA256@#$sha#" \
    "$ROOT/packaging/homebrew/syntila-connect.rb.tmpl" > "$tmp/tap/Formula/syntila-connect.rb"
  local zip="Syntila-Connect-$version-macos-$arch-app.zip"
  if [ -f "$dir/$zip" ]; then
    app=$(unzip -Z1 "$dir/$zip" | head -1 | cut -d/ -f1)
    sed -e "s#@VERSION@#$version#" -e "s#@URL@#$url_base/$zip#" -e "s#@SHA256@#$(shasum -a 256 "$dir/$zip" | cut -d' ' -f1)#" -e "s#@APP@#$app#" \
      "$ROOT/packaging/homebrew/syntila-connect-app.rb.tmpl" > "$tmp/tap/Casks/syntila-connect-app.rb"
  else
    rm -f "$tmp/tap/Casks/syntila-connect-app.rb"
  fi
  ruby -c "$tmp/tap/Formula/syntila-connect.rb" >/dev/null || die "The generated formula is not valid Ruby."
  ( cd "$tmp/tap" && git add -A && git status --short )
  confirm "Push the formula and cask for Syntila Connect $version to $owner/$tap."
  if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] would commit and push to $owner/$tap"
  else
    ( cd "$tmp/tap" && git -c user.name="Syntila Releases" -c user.email="support@conclaveax.com" commit -q -m "Syntila Connect $version" \
        && git push origin HEAD:main )
    echo "Install: brew install $owner/tap/syntila-connect    (desktop app: brew install --cask $owner/tap/syntila-connect-app)"
  fi
}

publish_homebrew
