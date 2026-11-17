import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import {
  EMAIL_PREVIEW_ORIGIN,
  emailPreviewFixtures,
  emailTemplateCatalog,
  renderEmail,
} from "../packages/email/src/index.ts";

const outputArgumentIndex = process.argv.indexOf("--out");
const outputDirectory = resolve(
  outputArgumentIndex >= 0
    ? (process.argv[outputArgumentIndex + 1] ?? ".email-preview")
    : ".email-preview",
);

function slug(templateId) {
  return templateId.replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "");
}

function escapeHtml(value) {
  return String(value).replace(
    /[&<>"']/g,
    (character) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      })[character],
  );
}

await mkdir(outputDirectory, { recursive: true });
const entries = [];
for (const template of emailTemplateCatalog) {
  const rendered = renderEmail(template.id, emailPreviewFixtures[template.id], {
    approvedOrigins: [EMAIL_PREVIEW_ORIGIN],
  });
  const baseName = slug(template.id);
  await writeFile(resolve(outputDirectory, `${baseName}.html`), rendered.html);
  await writeFile(resolve(outputDirectory, `${baseName}.txt`), rendered.text);
  entries.push({
    id: template.id,
    subject: rendered.subject,
    html: `${baseName}.html`,
    text: `${baseName}.txt`,
    availability: template.availability,
  });
}

const index = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Syntila email previews</title><style>body{margin:0;padding:32px;background:#f3f4f7;color:#172033;font:16px Arial,Helvetica,sans-serif}main{max-width:760px;margin:0 auto;background:#fff;padding:28px 32px;border-radius:12px}li{margin:14px 0}a{color:#6f5bd3}small{color:#687080}</style></head><body><main><h1>Syntila email previews</h1><p>Synthetic data only. No email transport was used.</p><ul>${entries.map((entry) => `<li><a href="${entry.html}">${escapeHtml(entry.id)}</a> <small>(${escapeHtml(entry.availability)}) — ${escapeHtml(entry.subject)} · <a href="${entry.text}">plain text</a></small></li>`).join("")}</ul></main></body></html>`;
await writeFile(resolve(outputDirectory, "index.html"), index);
console.log(`Rendered ${entries.length} email previews to ${outputDirectory}`);
