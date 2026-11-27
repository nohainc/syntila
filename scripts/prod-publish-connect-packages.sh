#!/usr/bin/env bash
# Publishes the built packages to the package managers:
#   --apt        the .deb files from scripts/prod-build-connect-linux.sh into the signed
#                APT repository (branch apt-repository of this repository, served by
#                GitHub Pages at https://nohainc.github.io/syntila)
#   --homebrew   a formula (CLI + Worker Engine) and a cask (desktop app) from
#                scripts/prod-build-connect-macos.sh into the tap nohainc/homebrew-syntila
# Run the release scripts first: the formula downloads the GitHub Release assets.
#
#   scripts/prod-publish-connect-packages.sh [--apt] [--homebrew] [--prune-legacy]
#                                            [--create-tap] [--yes] [--dry-run] [--allow-dirty]
#
# APT needs gpg and the repository signing key: either already in your gpg keyring or
# exported with SYNTILA_APT_PRIVATE_KEY_FILE (imported into a throwaway keyring).
# SYNTILA_APT_SIGNING_FINGERPRINT defaults to the current repository key.
# --prune-legacy removes the old Workspace packages (syntila, syntila-gui) from the repository.
# --create-tap creates the public tap repository when it does not exist.
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
PROD_EXTRA_FLAGS="--apt --homebrew --prune-legacy --create-tap"
parse_flags "$@"
apt=0; brew=0; prune=0; create_tap=0
for a in "$@"; do case "$a" in --apt) apt=1;; --homebrew) brew=1;; --prune-legacy) prune=1;; --create-tap) create_tap=1;; esac; done
[ "$apt$brew" != 00 ] || die "Choose --apt and/or --homebrew."
require git; require gh
version=$(connect_version)
owner_repo=$(git -C "$ROOT" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
owner=${owner_repo%%/*}; repo=${owner_repo#*/}
say "Publish Connect $version packages: $(git_state)"
require_clean_main

publish_apt() {
  require gpg; require python3
  check_connect_build linux "$version"
  local fp="${SYNTILA_APT_SIGNING_FINGERPRINT:-6EA013D12EF79CBDC34D66058182CCCFCF4175F2}"
  local base="https://$owner.github.io/$repo" tmp; tmp=$(mktemp -d)
  trap 'gpgconf --kill gpg-agent >/dev/null 2>&1 || true; rm -rf "$tmp"' RETURN
  if [ -n "${SYNTILA_APT_PRIVATE_KEY_FILE:-}" ]; then
    export GNUPGHOME="$tmp/gnupg"; mkdir -m 700 "$GNUPGHOME"
    gpg --batch --import "$SYNTILA_APT_PRIVATE_KEY_FILE" 2>/dev/null
  fi
  gpg --list-secret-keys "$fp" >/dev/null 2>&1 || die "The signing key $fp is not in your gpg keyring. Set SYNTILA_APT_PRIVATE_KEY_FILE to its exported private key."
  say "APT repository"
  git clone -q --single-branch --branch apt-repository "https://github.com/$owner_repo.git" "$tmp/repo"
  local prune_args=(); [ "$prune" = 1 ] && prune_args=(--prune syntila --prune syntila-gui)
  python3 "$ROOT/scripts/internal/build-apt-repository.py" --repo "$tmp/repo" --signing-key "$fp" \
    ${prune_args[@]+"${prune_args[@]}"} "$CONNECT_RELEASE_DIR"/linux/*.deb
  sed -e "s#@BASE_URL@#$base#g" -e "s#@FINGERPRINT@#$fp#g" -e "s#@VERSION@#$version#g" \
    "$ROOT/packaging/linux/apt-index.html" > "$tmp/repo/index.html"
  ( cd "$tmp/repo" && git add -A && git status --short | head -8 )
  confirm "Push syntila-connect $version to the APT repository branch of $owner_repo$([ "$prune" = 1 ] && echo ', removing the legacy Workspace packages')."
  if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] would commit and push to apt-repository"
  else
    ( cd "$tmp/repo" && git -c user.name="Syntila Releases" -c user.email="support@conclaveax.com" commit -q -m "Publish Syntila Connect $version" \
        && git push origin HEAD:apt-repository )
  fi
  local pages; pages=$(gh api "repos/$owner_repo/pages" --jq '.build_type + " " + (.source.branch // "")' 2>/dev/null || echo unknown)
  case "$pages" in
    "legacy apt-repository") echo "GitHub Pages serves the apt-repository branch: $base updates in a minute." ;;
    *) echo "NOTE: GitHub Pages is '$pages', not the apt-repository branch, so $base will not show this version yet." >&2
       echo "      One-time switch (changes the live site): gh api -X PUT repos/$owner_repo/pages -f build_type=legacy -f 'source[branch]=apt-repository' -f 'source[path]=/'" >&2 ;;
  esac
}

publish_homebrew() {
  check_connect_build macos "$version"
  local tap="homebrew-syntila" dir="$CONNECT_RELEASE_DIR/macos" tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  local arch tarball app url_base="https://github.com/$owner_repo/releases/download/connect-macos-v$version"
  arch=$(sed -n 's/.*"arch": *"\([^"]*\)".*/\1/p' "$dir/build.json")
  [ "$arch" = arm64 ] || die "The macOS build is $arch; the formula supports Apple silicon (arm64) only."
  tarball="Syntila-Connect-$version-macos-$arch.tar.gz"
  [ "$DRY_RUN" = 1 ] || gh release view "connect-macos-v$version" >/dev/null 2>&1 || die "Release connect-macos-v$version does not exist. Run scripts/prod-release-connect-macos.sh first."
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
    echo "Install: brew install $owner/syntila/syntila-connect    (desktop app: brew install --cask $owner/syntila/syntila-connect-app)"
  fi
}

[ "$apt" = 0 ] || publish_apt
[ "$brew" = 0 ] || publish_homebrew
