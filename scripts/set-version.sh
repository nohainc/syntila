#!/usr/bin/env bash
# Start the shared Syntila version series, tag it and atomically push main and the tag.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Usage: scripts/set-version.sh <major.minor>" >&2; exit 2
fi
series="$1"; tag="syntila-series-v${series}"
[ "$(git rev-parse --is-shallow-repository)" = false ] || { echo 'Fetch the complete Git history before setting a version.' >&2; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo 'Set versions on main.' >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=normal)" ] || { echo 'Commit or save all working tree changes before setting a version.' >&2; exit 1; }
git fetch --tags origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo 'main must match origin/main.' >&2; exit 1; }
node - "$series" <<'JS'
const fs=require('fs'), cp=require('child_process');
const [series]=process.argv.slice(2); const wanted=series.split('.').map(Number);
const tags=cp.execFileSync('git',['tag','--list'],{encoding:'utf8'}).trim().split('\n');
const prefix=/^(?:syntila-series-v|connect-v|web-v|syntila-v)(\d+)\.(\d+)(?:\.\d+)?$/;
for(const tag of tags){ const m=prefix.exec(tag); if(m && (Number(m[1]) > wanted[0] || (Number(m[1]) === wanted[0] && Number(m[2]) >= wanted[1]))) { console.error(`Version ${series} must exceed existing ${tag}.`); process.exit(1); } }
const current=fs.readFileSync('release-versions/syntila','utf8').trim().split('.').map(Number);
if(wanted[0] < current[0] || (wanted[0] === current[0] && wanted[1] <= current[1])) { console.error('Version must exceed the current series.'); process.exit(1); }
JS
printf '%s\n' "$series" > "release-versions/syntila"
git add -- "release-versions/syntila"
git commit -m "Start Syntila version series $series" -- "release-versions/syntila"
if ! git tag -a "$tag" -m "Start Syntila version series $series"; then
  echo "The version commit was created but tag $tag failed; inspect HEAD and create or correct the tag before pushing." >&2
  exit 1
fi
if ! git push --atomic origin HEAD:refs/heads/main "refs/tags/$tag:refs/tags/$tag"; then
  echo "Atomic push failed. Local commit and tag $tag remain; after resolving the failure, retry: git push --atomic origin main refs/tags/$tag" >&2
  exit 1
fi
echo "Pushed $tag and its version commit to origin/main."
