import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

const dist = new URL("../dist/", import.meta.url).pathname;

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
  const scripts = [...source.matchAll(/<script\b([^>]*)>/gi)];
  for (const [, attributes] of scripts) {
    if (!/\bsrc="\/[^"?]+\.js"/i.test(attributes)) {
      throw new Error(
        `${file}: inline or external third-party script detected`,
      );
    }
  }
  if (/\bon[a-z]+\s*=/i.test(source))
    throw new Error(`${file}: inline event handler detected`);
  if (/\bstyle\s*=/i.test(source))
    throw new Error(
      `${file}: inline style attribute detected (violates style-src 'self' CSP)`,
    );
}

console.log(
  "Public-site security checks passed: same-origin scripts only, no inline event handlers, and no inline style attributes.",
);
