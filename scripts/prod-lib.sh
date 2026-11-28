#!/usr/bin/env bash
# Shared settings and helpers for the prod-*.sh scripts. Source it; do not run it.
export PATH="$PATH:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Production backend host (override with the environment).
PROD_VPS="${PROD_VPS:-syntila@46.225.103.109}"
PROD_STAGE="${PROD_STAGE:-phase3-stage}"          # staging directory in the VPS home
PROD_API_URL="${PROD_API_URL:-https://api.syntila.app}"
PROD_APP_URL="${PROD_APP_URL:-https://syntila.app}"

# Secrets and settings kept outside the repository: the shell environment, or
# this gitignored file (see docs/operations/PRODUCTION_PROVISIONING.md).
PROD_ENV_FILE="${PROD_ENV_FILE:-$HOME/.config/syntila/prod.env}"
if [ -f "$PROD_ENV_FILE" ]; then set -a; . "$PROD_ENV_FILE"; set +a; fi

YES=0; SKIP_TESTS=0; DRY_RUN=0; ALLOW_DIRTY=0
parse_flags() { # shared flags; scripts with extra flags list them in $PROD_EXTRA_FLAGS
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) YES=1 ;;
      --skip-tests) SKIP_TESTS=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --allow-dirty) ALLOW_DIRTY=1 ;;
      *) case " ${PROD_EXTRA_FLAGS:-} " in *" $arg "*) ;; *) echo "Unknown option: $arg" >&2; exit 2;; esac ;;
    esac
  done
}

say() { printf '\n== %s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1" >&2; exit 1; }; }

# run <command...>: a command that changes production. With --dry-run it is
# only printed. Everything else (tests, builds, read-only checks) runs always.
run() {
  if [ "$DRY_RUN" = 1 ]; then printf '[dry-run] would run: %s\n' "$*"; return 0; fi
  "$@"
}

confirm() { # confirm "what will happen"
  [ "$DRY_RUN" = 1 ] && { printf '[dry-run] would ask: %s\n' "$1"; return 0; }
  [ "$YES" = 1 ] && return 0
  printf '\n%s\nContinue? [y/N] ' "$1"
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Cancelled."; exit 1; }
}

git_state() {
  local dirty; dirty=$(git -C "$ROOT" status --short | wc -l | tr -d ' ')
  echo "commit $(git -C "$ROOT" rev-parse --short HEAD), $dirty uncommitted change(s)"
}

# Deploys come from main, clean, equal to origin/main. --allow-dirty overrides
# (emergencies); --dry-run only warns.
require_clean_main() {
  local problems=() branch
  branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
  [ "$branch" = main ] || problems+=("branch is '$branch', not main")
  [ -z "$(git -C "$ROOT" status --short)" ] || problems+=("working tree has uncommitted changes")
  if git -C "$ROOT" fetch -q origin main 2>/dev/null; then
    [ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse origin/main)" ] || problems+=("HEAD is not origin/main")
  else
    problems+=("could not fetch origin/main")
  fi
  [ ${#problems[@]} -eq 0 ] && return 0
  printf 'Not deployable: %s\n' "${problems[@]}" >&2
  if [ "$ALLOW_DIRTY" = 1 ]; then echo "warning: continuing because of --allow-dirty" >&2; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then echo "warning: ignored in --dry-run" >&2; return 0; fi
  die "Refusing to deploy. Merge and push to main, or use --allow-dirty for an emergency."
}

# require_secrets NAME...: stops with the list of names that are not set.
require_secrets() {
  local missing=() n
  for n in "$@"; do [ -n "${!n:-}" ] || missing+=("$n"); done
  [ ${#missing[@]} -eq 0 ] || die "Missing secrets: ${missing[*]}
Set them in the shell or in $PROD_ENV_FILE (see docs/operations/PRODUCTION_PROVISIONING.md)."
}

# Secrets the web app deploy needs (names only; values never printed).
WEB_SECRETS=(CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID BETTER_AUTH_SECRET
  SYNTILA_AUTH_GITHUB_CLIENT_ID SYNTILA_AUTH_GITHUB_CLIENT_SECRET
  SYNTILA_AUTH_GOOGLE_CLIENT_ID SYNTILA_AUTH_GOOGLE_CLIENT_SECRET)

# Run a command on the VPS that only reads state.
vps_read() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$PROD_VPS" "$@"; }

run_tests() { # the quick gate: typecheck + backend suite + schema.lock
  [ "$SKIP_TESTS" = 1 ] && { echo "(tests skipped)"; return 0; }
  say "Tests (scripts/test-all.sh --quick)"
  "$ROOT/scripts/test-all.sh" --quick
  say "schema.lock matches the migrations"
  "$ROOT/scripts/regenerate-schema-lock.sh" --check
}

build_backend() { say "Build backend"; ( cd "$ROOT/apps/backend" && bash scripts/build.sh ); }

# Copies the built backend, migrations and VPS files to the staging directory.
stage_backend() {
  say "Upload to $PROD_VPS:$PROD_STAGE"
  run ssh "$PROD_VPS" "mkdir -p $PROD_STAGE/backend $PROD_STAGE/vps"
  run rsync -a --delete "$ROOT/apps/backend/dist/" "$PROD_VPS:$PROD_STAGE/backend/dist/"
  run rsync -a --delete "$ROOT/apps/backend/migrations/" "$PROD_VPS:$PROD_STAGE/backend/migrations/"
  run rsync -a --delete "$ROOT/infra/vps/" "$PROD_VPS:$PROD_STAGE/vps/"
}

# Migrations in the build that the production database has not applied yet.
# Reading the list needs sudo on the VPS (one password prompt); when that is
# not possible the function says so instead of listing every migration.
pending_migrations() {
  local applied
  # The login user cannot read the database password, so the query runs as the
  # postgres user over sudo, as in "prod-migrate-db.sh status". The password
  # prompt goes to the terminal (stdout may be captured by the caller) and the
  # result travels through a file in the home directory.
  ssh -t "$PROD_VPS" 'sudo -u postgres psql -XAtq -d syntila -c "SELECT version FROM schema_migrations ORDER BY version" > ~/.applied-migrations.txt' >/dev/tty 2>&1 </dev/tty || true
  applied=$(ssh -o BatchMode=yes "$PROD_VPS" 'cat ~/.applied-migrations.txt; rm -f ~/.applied-migrations.txt' 2>/dev/null \
    | grep -E '^[0-9]{4}_[a-z0-9_]+\.sql$' | sort || true)
  if [ -z "$applied" ]; then
    echo "unknown (could not read schema_migrations; the VPS run lists them before applying)"
    return 0
  fi
  ls "$ROOT/apps/backend/migrations" | grep -E '^[0-9]{4}_[a-z0-9_]+\.sql$' | sort | comm -23 - <(printf '%s\n' "$applied")
}

# Pending auth (D1) migrations as printed by wrangler.
d1_pending() {
  ( cd "$ROOT" && pnpm exec wrangler d1 migrations list "${SYNTILA_PRODUCTION_D1_NAME:-syntila-auth}" --remote \
      --config "${SYNTILA_WRANGLER_CONFIG:-$ROOT/infra/cloudflare/app.wrangler.jsonc}" 2>&1 )
}

# ---- Connect releases (macOS, Linux) ----

CONNECT_RELEASE_DIR="$ROOT/dist/connect/release"

connect_version() { node "$ROOT/scripts/release-version.mjs"; }

# Public Profile trust roots baked into a release build (JSON). From the
# environment, or the GitHub variable the Windows build uses.
connect_trust_roots() {
  local v="${SYNTILA_PROFILE_TRUST_ROOTS:-}"
  if [ -z "$v" ] && command -v gh >/dev/null 2>&1; then
    v=$(gh variable get SYNTILA_PROFILE_TRUST_ROOTS 2>/dev/null || true)
  fi
  [ -n "$v" ] || die "No Profile trust roots: set SYNTILA_PROFILE_TRUST_ROOTS to a flat public key map."
  printf '%s' "$v" | node "$ROOT/scripts/validate-connect-trust-roots.mjs"
}

# check_connect_build <platform> <version>: the artifacts in dist are the build of
# this commit and version, and their checksums verify. Prints nothing on success.
check_connect_build() {
  local platform="$1" version="$2" dir="$CONNECT_RELEASE_DIR/$1"
  [ -f "$dir/build.json" ] || die "No build in $dir. Run scripts/prod-build-connect-$platform.sh first."
  local built_version built_commit head
  built_version=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$dir/build.json")
  built_commit=$(sed -n 's/.*"commit": *"\([^"]*\)".*/\1/p' "$dir/build.json")
  head=$(git -C "$ROOT" rev-parse HEAD)
  [ "$built_version" = "$version" ] || die "The build is version $built_version, the checkout is $version. Rebuild."
  [ "$built_commit" = "$head" ] || [ "$ALLOW_DIRTY" = 1 ] || die "The build is from ${built_commit:0:8}, HEAD is ${head:0:8}. Rebuild."
  ( cd "$dir" && shasum -a 256 -c SHA256SUMS >/dev/null ) || die "Checksum verification failed in $dir."
  local f
  for f in "$dir"/*; do
    case "$(basename "$f")" in SHA256SUMS|build.json) continue;; esac
    grep -q "  $(basename "$f")\$" "$dir/SHA256SUMS" || die "$(basename "$f") is not listed in SHA256SUMS; rebuild."
  done
}

# Publish verified platform artifacts to the public releases bucket.
create_connect_release() {
  local platform="$1"; shift 3
  local version commit
  version=$(connect_version)
  commit=$(sed -n 's/.*"commit": *"\([^"]*\)".*/\1/p' "$CONNECT_RELEASE_DIR/$platform/build.json")
  require node
  require_secrets CLOUDFLARE_ACCOUNT_ID SYNTILA_RELEASE_R2_ACCESS_KEY_ID SYNTILA_RELEASE_R2_SECRET_ACCESS_KEY
  confirm "Publish Connect $version ($platform, commit ${commit:0:8}) to the public R2 releases bucket."
  run node "$ROOT/scripts/publish-connect-r2.mjs" "$platform" "$version" "$commit" "$@"
}
