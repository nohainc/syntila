import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

const dist = new URL("../dist/", import.meta.url).pathname;
const requiredFiles = [
  "index.html",
  "404.html",
  "how-it-works/index.html",
  "workers/index.html",
  "use-cases/index.html",
  "security/index.html",
  "privacy/index.html",
  "terms/index.html",
  "downloads/index.html",
  "favicon.svg",
  "social-preview.svg",
  "social-preview.png",
  "site.webmanifest",
  "robots.txt",
  "sitemap.xml",
];

const forbiddenLegacy = /\b(?:studio|plugin)\b/i;
const forbiddenPublicArchitectureVersion = /\b(?:architecture\s+)?v\d+\b/i;
const errors = [];

for (const file of requiredFiles) {
  try {
    await readFile(join(dist, file));
  } catch {
    errors.push(`missing release artifact: ${file}`);
  }
}

/** @param {string} directory @returns {Promise<string[]>} */
async function htmlFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await htmlFiles(path)));
    else if (path.endsWith(".html")) files.push(path);
  }
  return files;
}

for (const file of await htmlFiles(dist)) {
  const source = await readFile(file, "utf8");
  const relative = file.replace(dist, "");

  if (forbiddenLegacy.test(source)) {
    errors.push(`${relative}: legacy product terminology found`);
  }
  if (forbiddenPublicArchitectureVersion.test(source)) {
    errors.push(`${relative}: public architecture-version terminology found`);
  }
  const githubLinks = [
    ...source.matchAll(/https:\/\/github\.com\/nohainc\/syntila[^"'\s]*/gi),
  ].map(([link]) => link);
  const approvedDownloads =
    relative === "downloads/index.html" &&
    githubLinks.length > 0 &&
    githubLinks.every(
      (link) => link === "https://github.com/nohainc/syntila/releases/latest",
    );
  if (githubLinks.length > 0 && !approvedDownloads) {
    errors.push(`${relative}: public GitHub repository link found`);
  }
}

const home = await readFile(join(dist, "index.html"), "utf8");
const requiredHomepageContent = [
  "Bring your people and AI together.",
  "Threads",
  "One conversation. Everyone stays in context.",
  "Open Syntila",
];
for (const content of requiredHomepageContent) {
  if (!home.includes(content))
    errors.push(`homepage: missing release content: ${content}`);
}
if ((home.match(/href="https:\/\/syntila\.app/g) ?? []).length < 3) {
  errors.push("homepage: expected direct app CTA links");
}
for (const link of ["/privacy/", "/terms/", "/security/", "/use-cases/"]) {
  if (!home.includes(`href="${link}"`))
    errors.push(`homepage: missing footer/nav link ${link}`);
}

const workerSource = await readFile(
  new URL("../src/worker.ts", import.meta.url),
  "utf8",
);
for (const marker of [
  "www.conclaveax.com",
  "conclaveax.com",
  "308",
  "location",
]) {
  if (!workerSource.includes(marker))
    errors.push(`deployment: missing ${marker} redirect contract`);
}

if (errors.length)
  throw new Error(`Landing-page release gate failed:\n${errors.join("\n")}`);

console.log(
  "Landing-page release gate passed: routes, Shared AI Workspace product model, repository privacy posture, terminology, metadata artifacts, and domain redirect contract verified.",
);
