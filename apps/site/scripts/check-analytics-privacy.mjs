import { readFile } from "node:fs/promises";

const source = await readFile(
  new URL("../public/scripts/site-analytics.js", import.meta.url),
  "utf8",
);
const layout = await readFile(
  new URL("../src/layouts/SiteLayout.astro", import.meta.url),
  "utf8",
);
const allowedEvents = [
  "landing.page_view",
  "cta.open_app",
  "cta.download",
  "navigation.downloads",
  "navigation.how_it_works",
  "section.workspace_reached",
  "section.workers_reached",
];
const forbiddenPayloadFields = [
  "chat",
  "message",
  "credential",
  "secret",
  "token",
  "accountId",
  "userId",
  "workspaceId",
];

for (const event of allowedEvents) {
  if (!source.includes(`"${event}"`))
    throw new Error(`Missing allowlisted event: ${event}`);
}
for (const field of forbiddenPayloadFields) {
  if (source.includes(`{${field}`) || source.includes(` ${field}:`))
    throw new Error(`Forbidden analytics payload field: ${field}`);
}
if (!source.includes('credentials: "omit"'))
  throw new Error("Analytics requests must omit credentials");
if (!layout.includes("PUBLIC_SITE_ANALYTICS_ENDPOINT"))
  throw new Error("Analytics endpoint must be explicit opt-in");

console.log(
  "Analytics privacy checks passed: allowlisted events only, no credentials or application identifiers.",
);
