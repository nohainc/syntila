#!/usr/bin/env bash
# Tests the prod-*.sh scripts without touching production: every script runs in a
# throwaway copy of the repo with --dry-run against stub ssh, rsync, curl, pnpm,
# flutter, node, bun and wrangler on PATH. Asserts the step order and that a
# failing gate stops the run before anything is deployed.
#   scripts/test-prod-scripts.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails+1)); }

# Throwaway repo with the real scripts and stubbed build inputs.
R="$T/repo"; mkdir -p "$R/apps/site" "$R/apps/backend/scripts" "$R/apps/backend/migrations" "$R/apps/app/build/web" "$R/infra/vps" "$R/infra/cloudflare" "$T/bin" "$T/home"
cp -R "$SRC/scripts" "$R/scripts"
touch "$R/apps/backend/migrations/0001_initial.sql"
printf '#!/bin/sh\necho "build.sh" >>"$LOG"\n' > "$R/apps/backend/scripts/build.sh"
for s in test-all.sh regenerate-schema-lock.sh; do
  printf '#!/bin/sh\necho "%s $*" >>"$LOG"\ncase "$FAIL_ON" in *%s*) exit 1;; esac\n' "$s" "$s" > "$R/scripts/$s"; chmod +x "$R/scripts/$s"
done
# Stub every external tool: log the call, fail when FAIL_ON matches it.
for tool in ssh rsync curl pnpm flutter node bun wrangler dart gh; do
  cat > "$T/bin/$tool" <<STUB
#!/bin/sh
echo "$tool \$*" >>"\$LOG"
case "\$FAIL_ON" in "") ;; *) case "$tool \$*" in *"\$FAIL_ON"*) exit 1;; esac;; esac
case "$tool" in
  ssh) printf '20260102T000000Z (current)\n20260101T000000Z\n';;
  gh) case "\$*" in "release view"*) exit 1;; esac;;
  curl) case "\$*" in *"-w"*) case "\$*" in *api/session*) printf 401;; *) printf 200;; esac;; esac;;
esac
exit 0
STUB
  chmod +x "$T/bin/$tool"
done
mkdir -p "$R/apps/connect"; printf 'name: syntila_connect\nversion: 0.1.0\n' > "$R/apps/connect/pubspec.yaml"
git -C "$R" init -q -b main && git -C "$R" remote add origin https://github.com/test/repo.git && git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm t
# Fake Connect builds of this commit for the release scripts.
head=$(git -C "$R" rev-parse HEAD)
for platform in macos linux; do
  d="$R/dist/connect/release/$platform"; mkdir -p "$d"; echo pkg > "$d/Syntila-Connect-0.1.0-$platform.tar.gz"
  ( cd "$d" && shasum -a 256 * > SHA256SUMS )
  printf '{"version":"0.1.0","commit":"%s","arch":"arm64"}\n' "$head" > "$d/build.json"
done

# run_case <name> <script> [args...]; sets OUT, CODE, LOG
run_case() {
  local name="$1"; shift
  export LOG="$T/$name.log"; : > "$LOG"
  OUT=$(cd "$R" && HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" \
    SYNTILA_PROFILE_TRUST_ROOTS='{"k":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}' CLOUDFLARE_API_TOKEN=x CLOUDFLARE_ACCOUNT_ID=x BETTER_AUTH_SECRET=x SYNTILA_AUTH_GITHUB_CLIENT_ID=x \
    SYNTILA_AUTH_GITHUB_CLIENT_SECRET=x SYNTILA_AUTH_GOOGLE_CLIENT_ID=x SYNTILA_AUTH_GOOGLE_CLIENT_SECRET=x \
    "${@}" 2>&1); CODE=$?
}
in_order() { # in_order <text> <pattern>... : the patterns appear in this order
  local text="$1" prev=0 n; shift
  for p in "$@"; do
    n=$(printf '%s\n' "$text" | grep -n -m1 -F -- "$p" | cut -d: -f1)
    [ -n "$n" ] && [ "$n" -ge "$prev" ] || return 1
    prev=$n
  done
}

# 1. every script succeeds in --dry-run
for s in prod-deploy-backend prod-deploy-web-app prod-deploy-frontend prod-deploy-all prod-migrate-db prod-status prod-rollback-backend; do
  args=(--dry-run); [ "$s" = prod-migrate-db ] && args=(apply --dry-run)
  FAIL_ON="" run_case "$s" "$R/scripts/$s.sh" "${args[@]}"
  [ "$CODE" = 0 ] && ok "$s --dry-run" || { fail "$s --dry-run (exit $CODE)"; printf '%s\n' "$OUT" | tail -8; }
done
FAIL_ON="" run_case reset "$R/scripts/prod-reset-db.sh" --i-understand-this-deletes-all-data --dry-run
[ "$CODE" = 0 ] && ok "prod-reset-db --dry-run" || { fail "prod-reset-db --dry-run"; printf '%s\n' "$OUT" | tail -5; }
FAIL_ON="" run_case reset2 "$R/scripts/prod-reset-db.sh" --dry-run
[ "$CODE" != 0 ] && ok "prod-reset-db refuses without the flag" || fail "prod-reset-db ran without the flag"

for s in prod-build-connect-macos prod-build-connect-linux prod-release-connect-macos prod-release-connect-linux; do
  FAIL_ON="" run_case "$s" "$R/scripts/$s.sh" --dry-run
  [ "$CODE" = 0 ] && ok "$s --dry-run" || { fail "$s --dry-run (exit $CODE)"; printf '%s\n' "$OUT" | tail -6; }
done
FAIL_ON="" run_case relmac "$R/scripts/prod-release-connect-macos.sh" --dry-run
printf '%s' "$OUT" | grep -q "gh release create connect-v0.1.0" && ok "macOS release names the tag and uploads the build" || fail "macOS release plan"
echo stale > "$R/dist/connect/release/linux/Syntila-Connect-0.1.0-linux.tar.gz"
FAIL_ON="" run_case relstale "$R/scripts/prod-release-connect-linux.sh" --dry-run
[ "$CODE" != 0 ] && printf '%s' "$OUT" | grep -q "Checksum verification failed" && ok "release refuses artifacts that do not match SHA256SUMS" || fail "checksum check"
echo pkg > "$R/dist/connect/release/linux/Syntila-Connect-0.1.0-linux.tar.gz"
echo extra > "$R/dist/connect/release/linux/extra.deb"
FAIL_ON="" run_case relextra "$R/scripts/prod-release-connect-linux.sh" --dry-run
[ "$CODE" != 0 ] && printf '%s' "$OUT" | grep -q "not listed in SHA256SUMS" && ok "release refuses files that are not in SHA256SUMS" || fail "unlisted artifact check"
rm -f "$R/dist/connect/release/linux/extra.deb"
FAIL_ON="" run_case pubflag "$R/scripts/prod-publish-connect-linux.sh" --create-tap --dry-run
[ "$CODE" != 0 ] && ok "each publish script rejects the other platform's flags" || fail "publish flag check"

# 2. web app step order, and nothing mutating ran in the dry run
FAIL_ON="" run_case web "$R/scripts/prod-deploy-web-app.sh" --dry-run
in_order "$(cat "$LOG")" "pnpm --dir apps/cloud types:check" "pnpm --dir apps/cloud test" "flutter analyze" "flutter test" "flutter build web" "node scripts/assert-no-browser-secrets.mjs" "pnpm production:preflight" "pnpm email:config-check" "wrangler d1 migrations list" \
  && in_order "$OUT" "== Gates" "== Build Flutter web" "== Auth D1 migrations" "== Sync Worker secrets" "== Deploy the Worker" "== Public checks" \
  && ok "web app step order" || fail "web app step order"
grep -qE "wrangler (deploy|d1 migrations apply|secret)|^rsync|ssh .*sudo" "$LOG" && fail "dry run changed production" || ok "dry run changes nothing"

# 3. a failing gate or check stops the run before the D1 step and the deploy
for f in "types:check" "flutter analyze" "flutter test" "assert-no-browser-secrets" "production:preflight" "email:config-check"; do
  FAIL_ON="$f" run_case "web-$f" "$R/scripts/prod-deploy-web-app.sh" --dry-run
  if [ "$CODE" != 0 ] && ! printf '%s' "$OUT" | grep -q "== Auth D1 migrations"; then ok "web app stops when '$f' fails"; else fail "web app did not stop on '$f'"; fi
done
FAIL_ON="flutter build" run_case webbuild "$R/scripts/prod-deploy-web-app.sh" --dry-run
[ "$CODE" != 0 ] && ! grep -q "assert-no-browser" "$LOG" && ok "web app stops when the build fails" || fail "web app continued after a failed build"

# 4. missing secrets stop everything before any gate
export LOG="$T/missing.log"; : > "$LOG"
OUT=$(cd "$R" && HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" FAIL_ON="" env -u BETTER_AUTH_SECRET -u SYNTILA_AUTH_GOOGLE_CLIENT_ID \
  CLOUDFLARE_API_TOKEN=x CLOUDFLARE_ACCOUNT_ID=x SYNTILA_AUTH_GITHUB_CLIENT_ID=x SYNTILA_AUTH_GITHUB_CLIENT_SECRET=x SYNTILA_AUTH_GOOGLE_CLIENT_SECRET=x \
  "$R/scripts/prod-deploy-web-app.sh" --dry-run 2>&1); CODE=$?
[ "$CODE" != 0 ] && printf '%s' "$OUT" | grep -q "Missing secrets: BETTER_AUTH_SECRET SYNTILA_AUTH_GOOGLE_CLIENT_ID" && [ ! -s "$LOG" ] \
  && ok "missing secrets are listed and nothing runs" || fail "missing secrets handling"

# 5. deploy-all order, and a failing backend gate stops the rest
FAIL_ON="" run_case all "$R/scripts/prod-deploy-all.sh" --dry-run --site
in_order "$OUT" "Production backend deploy" "Production web app deploy" "Production public site deploy" "Dry run complete" && ok "deploy-all order: backend, web app, site" || fail "deploy-all order"
FAIL_ON="test-all.sh" run_case allfail "$R/scripts/prod-deploy-all.sh" --dry-run --site
if [ "$CODE" != 0 ] && printf '%s' "$OUT" | grep -q "Deployed:     nothing" && ! printf '%s' "$OUT" | grep -q "Production web app deploy"; then ok "deploy-all stops at the first failure"; else fail "deploy-all did not stop"; fi
FAIL_ON="flutter analyze" run_case allweb "$R/scripts/prod-deploy-all.sh" --dry-run --site
printf '%s' "$OUT" | grep -q "Deployed:     backend" && printf '%s' "$OUT" | grep -q "Not deployed: web-app site" && ok "deploy-all reports what is deployed" || fail "deploy-all report"

# 6. deploys refuse a dirty tree unless --allow-dirty (real, not dry-run, stopped before any tool runs)
echo x > "$R/dirty"
FAIL_ON="" run_case dirty "$R/scripts/prod-deploy-backend.sh" --yes --skip-tests
[ "$CODE" != 0 ] && printf '%s' "$OUT" | grep -q "Refusing to deploy" && ! grep -q "^rsync\|^ssh" "$LOG" && ok "dirty tree is refused" || fail "dirty tree was not refused"
rm "$R/dirty"

[ "$fails" = 0 ] && echo "All prod script tests passed." || { echo "$fails failure(s)"; exit 1; }
