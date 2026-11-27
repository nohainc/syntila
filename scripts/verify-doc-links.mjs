import { readdir, readFile, stat } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

// Checks that documentation does not point at things that no longer exist:
//  1. relative Markdown links resolve to a file or directory;
//  2. `#anchor` fragments match a heading in the target Markdown file;
//  3. repository paths written in `inline code` exist;
//  4. migration files named like `0042_name.sql` exist.

const roots = [
  "README.md",
  "ARCHITECTURE.md",
  "ROADMAP.md",
  "AGENTS.md",
  "docs",
];
const pathRoots = [
  "apps",
  "packages",
  "engines",
  "scripts",
  "docs",
  "infra",
  "e2e",
  "examples",
  "packaging",
];

async function exists(path) {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

async function markdownFiles(path) {
  if (!(await exists(path))) return [];
  const metadata = await stat(path);
  if (metadata.isFile()) return path.endsWith(".md") ? [path] : [];

  const entries = await readdir(path, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    files.push(...(await markdownFiles(join(path, entry.name))));
  }
  return files;
}

function stripCode(contents) {
  return contents.replace(/^(```|~~~)[^\n]*\n[\s\S]*?^\1[^\n]*$/gm, "");
}

// GitHub-style heading slug.
function slug(heading) {
  return heading
    .toLowerCase()
    .replace(/<[^>]+>/g, "")
    .replace(/[`*_~]/g, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[^\p{L}\p{N}\s-]/gu, "")
    .trim()
    .replace(/\s/g, "-");
}

const anchorCache = new Map();
async function anchorsOf(file) {
  if (anchorCache.has(file)) return anchorCache.get(file);
  const text = stripCode(await readFile(file, "utf8"));
  const seen = new Map();
  const anchors = new Set();
  for (const match of text.matchAll(/^#{1,6}\s+(.+?)\s*#*\s*$/gm)) {
    const base = slug(match[1]);
    const count = seen.get(base) ?? 0;
    seen.set(base, count + 1);
    anchors.add(count === 0 ? base : `${base}-${count}`);
  }
  anchorCache.set(file, anchors);
  return anchors;
}

const migrationFiles = new Set([
  ...(await readdir("apps/backend/migrations").catch(() => [])),
  ...(await readdir("apps/cloud/migrations").catch(() => [])),
]);
const migrationName = /\b(\d{4}_[a-z0-9_]+\.sql)\b/g;

const files = (await Promise.all(roots.map(markdownFiles))).flat();
const problems = [];
const markdownLink = /\[[^\]]+\]\(([^)\s]+)\)/g;
const inlinePath = new RegExp(
  "`((?:" + pathRoots.join("|") + ")/[A-Za-z0-9_./@+\\-]*[A-Za-z0-9_/\\-])`",
  "g",
);

for (const file of files) {
  const raw = await readFile(file, "utf8");
  const contents = stripCode(raw);

  for (const match of contents.matchAll(markdownLink)) {
    const [target, fragment] = match[1].split("#");
    if (/^(https?:|mailto:)/.test(target)) continue;
    const resolved = target === "" ? file : resolve(dirname(file), target);
    if (!(await exists(resolved))) {
      problems.push(`${file}: broken link -> ${match[1]}`);
      continue;
    }
    if (fragment && resolved.endsWith(".md")) {
      const anchors = await anchorsOf(resolved);
      if (!anchors.has(decodeURIComponent(fragment).toLowerCase())) {
        problems.push(`${file}: missing anchor -> ${match[1]}`);
      }
    }
  }

  for (const match of contents.matchAll(migrationName)) {
    if (!migrationFiles.has(match[1])) {
      problems.push(`${file}: missing migration -> ${match[1]}`);
    }
  }

  for (const match of contents.matchAll(inlinePath)) {
    const path = match[1];
    if (/[*<>{}]|\.\.\./.test(path)) continue; // globs and placeholders
    if (path.startsWith(".")) continue;
    if (!(await exists(resolve(path)))) {
      problems.push(`${file}: missing repository path -> ${path}`);
    }
  }
}

if (problems.length > 0) {
  console.error("Documentation problems:");
  console.error([...new Set(problems)].join("\n"));
  process.exit(1);
}

console.log(`Documentation check passed: ${files.length} files scanned`);
