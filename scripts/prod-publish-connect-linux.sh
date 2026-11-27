#!/usr/bin/env bash
# Publishes the Linux .deb files from scripts/prod-build-connect-linux.sh to the signed
# APT repository (branch apt-repository of this repository, served by GitHub Pages at
# https://nohainc.github.io/syntila). Run scripts/prod-release-connect-linux.sh first.
#
#   scripts/prod-publish-connect-linux.sh [--prune-legacy] [--keep N] [--yes] [--dry-run] [--allow-dirty]
#
# Needs gpg and the repository signing key: either already in your gpg keyring or
# exported with SYNTILA_APT_PRIVATE_KEY_FILE (imported into a throwaway keyring); if neither,
# ~/.config/conclave/release-keys/apt-private-key.asc is used when it exists.
# SYNTILA_APT_SIGNING_FINGERPRINT defaults to the current repository key.
# --prune-legacy removes the old Workspace packages (syntila, syntila-gui).
# --keep N keeps only the newest N versions of syntila-connect in the repository (at least 1).
set -euo pipefail
source "$(dirname "$0")/prod-lib.sh"
PROD_EXTRA_FLAGS="--prune-legacy --keep"
keep=""; args=(); while [ $# -gt 0 ]; do
  case "$1" in --keep) [ $# -ge 2 ] || die "--keep needs a number"; keep="$2"; shift 2;; *) args+=("$1"); shift;; esac
done
parse_flags ${args[@]+"${args[@]}"}
case "$keep" in ""|[1-9]*) ;; *) die "--keep needs a number of at least 1";; esac
case "$keep" in *[!0-9]*) die "--keep needs a number of at least 1";; esac
prune=0; for a in ${args[@]+"${args[@]}"}; do [ "$a" = --prune-legacy ] && prune=1; done
require git; require gh
version=$(connect_version)
owner_repo=$(git -C "$ROOT" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
owner=${owner_repo%%/*}; repo=${owner_repo#*/}
say "Publish Connect $version to APT: $(git_state)"
require_clean_main

publish_apt() {
  require gpg; require python3
  check_connect_build linux "$version"
  local fp="${SYNTILA_APT_SIGNING_FINGERPRINT:-6EA013D12EF79CBDC34D66058182CCCFCF4175F2}"
  local base="https://$owner.github.io/$repo" tmp; tmp=$(mktemp -d)
  trap 'gpgconf --kill gpg-agent >/dev/null 2>&1 || true; rm -rf "$tmp"' RETURN
  # Where the key was exported when the repository was set up on this Mac.
  local default_key="$HOME/.config/conclave/release-keys/apt-private-key.asc"
  if [ -z "${SYNTILA_APT_PRIVATE_KEY_FILE:-}" ] && ! gpg --list-secret-keys "$fp" >/dev/null 2>&1 && [ -f "$default_key" ]; then
    SYNTILA_APT_PRIVATE_KEY_FILE="$default_key"
  fi
  if [ -n "${SYNTILA_APT_PRIVATE_KEY_FILE:-}" ]; then
    export GNUPGHOME="$tmp/gnupg"; mkdir -m 700 "$GNUPGHOME"
    gpg --batch --import "$SYNTILA_APT_PRIVATE_KEY_FILE" 2>/dev/null
  fi
  gpg --list-secret-keys "$fp" >/dev/null 2>&1 || die "The signing key $fp is not in your gpg keyring. Set SYNTILA_APT_PRIVATE_KEY_FILE to its exported private key."
  say "APT repository"
  git clone -q --single-branch --branch apt-repository "https://github.com/$owner_repo.git" "$tmp/repo"
  local prune_args=(); [ "$prune" = 1 ] && prune_args=(--prune syntila --prune syntila-gui)
  [ -z "$keep" ] || prune_args+=(--keep "$keep")
  python3 "$ROOT/scripts/internal/build-apt-repository.py" --repo "$tmp/repo" --signing-key "$fp" \
    ${prune_args[@]+"${prune_args[@]}"} "$CONNECT_RELEASE_DIR"/linux/*.deb
  sed -e "s#@BASE_URL@#$base#g" -e "s#@FINGERPRINT@#$fp#g" -e "s#@VERSION@#$version#g" \
    "$ROOT/packaging/linux/apt-index.html" > "$tmp/repo/index.html"
  ( cd "$tmp/repo" && git add -A && git status --short | head -8 )
  confirm "Push syntila-connect $version to the APT repository branch of $owner_repo$([ "$prune" = 1 ] && echo ', removing the legacy Workspace packages')$([ -z "$keep" ] || echo ", keeping only the newest $keep version(s)")."
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

publish_apt
