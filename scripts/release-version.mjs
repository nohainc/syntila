#!/usr/bin/env node
// Derive a release version from an annotated Syntila series tag and main history.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
function fail(message) { console.error(message); process.exit(1); }
function git(...args) { return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, GIT_TERMINAL_PROMPT: '0' } }).trim(); }
if (args.length) fail('Usage: node scripts/release-version.mjs');
try {
  if (git('rev-parse', '--is-shallow-repository') !== 'false') throw Error('A complete Git history is required; fetch the full history and tags.');
  if (git('status', '--porcelain', '--untracked-files=normal')) throw Error('Release version requires a clean working tree.');
  const sha = git('rev-parse', 'HEAD');
  const branch = git('branch', '--show-current');
  if (branch !== 'main') {
    if (!(process.env.GITHUB_ACTIONS === 'true' && process.env.GITHUB_REF === 'refs/heads/main' && process.env.GITHUB_SHA === sha)) throw Error('Release builds must run from main.');
  }
  try { git('fetch', '--quiet', '--tags', 'origin', 'main'); }
  catch { throw Error('Cannot fetch origin/main and tags; check the remote, network and Git credentials.'); }
  if (git('rev-parse', 'refs/remotes/origin/main') !== sha) throw Error('HEAD must match the fetched origin/main.');
  const series = readFileSync(resolve(root, 'release-versions/syntila'), 'utf8').trim();
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(series)) throw Error('Invalid Syntila series file.');
  const [major, minor] = series.split('.').map(BigInt);
  const knownTags = git('tag', '--list').split('\n').filter(Boolean);
  const tagPattern = /^(?:syntila-series-v|connect-v|web-v|syntila-v)(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\.(?:0|[1-9]\d*))?$/;
  for (const knownTag of knownTags) {
    const match = tagPattern.exec(knownTag);
    if (match && (BigInt(match[1]) > major || (BigInt(match[1]) === major && BigInt(match[2]) > minor))) {
      throw Error(`${knownTag} is newer than the configured Syntila series.`);
    }
  }
  const tag = `syntila-series-v${series}`;
  let tagType;
  try { tagType = git('cat-file', '-t', `refs/tags/${tag}`); }
  catch { throw Error(`Missing series tag ${tag}; establish it with scripts/set-version.sh.`); }
  if (tagType !== 'tag') throw Error(`${tag} must be an annotated tag.`);
  const anchor = git('rev-parse', `refs/tags/${tag}^{commit}`);
  const history = git('rev-list', '--first-parent', 'HEAD').split('\n');
  const revision = history.indexOf(anchor);
  if (revision < 0) throw Error(`${tag} is not on the first-parent history of main.`);
  const published = ['connect', 'web', 'syntila'].flatMap(name => git('tag', '--list', `${name}-v${series}.*`).split('\n').filter(Boolean));
  for (const release of published) {
    const suffix = release.slice(release.lastIndexOf('.') + 1);
    if (!/^(0|[1-9]\d*)$/.test(suffix)) continue;
    const number = BigInt(suffix);
    if (number > BigInt(revision)) throw Error(`${release} is newer than the calculated version; main history may have been rewritten.`);
    if (number === BigInt(revision) && git('rev-parse', `refs/tags/${release}^{commit}`) !== sha) throw Error(`${release} already refers to another commit.`);
  }
  process.stdout.write(`${series}.${revision}\n`);
} catch (error) { fail(`Cannot calculate Syntila version: ${error.message}`); }
