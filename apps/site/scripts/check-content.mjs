import { readFile } from "node:fs/promises";

const dist = new URL("../dist/", import.meta.url).pathname;
const routes = new Map([
  ["/", "index.html"],
  ["/how-it-works/", "how-it-works/index.html"],
  ["/workers/", "workers/index.html"],
  ["/use-cases/", "use-cases/index.html"],
  ["/security/", "security/index.html"],
  ["/privacy/", "privacy/index.html"],
  ["/terms/", "terms/index.html"],
  ["/refunds/", "refunds/index.html"],
  ["/downloads/", "downloads/index.html"],
  ["/faq/", "faq/index.html"],
]);

/** @param {string | undefined} [str] @returns {string} */
function decodeHtml(str) {
  if (!str) return "";
  return str
    .replace(/&amp;/g, "&")
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&#x27;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">");
}

/** @type {Record<string, {title: string, heading: string, content: string[]}>} */
const expected = {
  "/refunds/": {
    title: "Refund Policy — Syntila",
    heading: "Refund Policy",
    content: ["14 days", "Cancellation", "Paddle"],
  },
  "/": {
    title: "Syntila — Bring your projects, people, and AI together",
    heading: "Bring your projects, people, and AI together.",
    content: [
      "Threads",
      "ONE SPACE. PEOPLE + AI.",
      "Your projects and AI, together in one Space.",
      "When a chat isn't enough",
      "Made for your projects and your people.",
      "Free to start.",
      "Open Syntila",
    ],
  },
  "/how-it-works/": {
    title: "How Syntila works — Shared Spaces for people and AI",
    heading: "From shared ideas to verified results.",
    content: [
      "Create a Space",
      "Invite others when you want",
      "Connect & share AI",
      "open a Thread",
      "Collaborate and choose a Workflow",
      "What the person who connects a computer needs.",
    ],
  },
  "/workers/": {
    title: "AI & Workers — Syntila",
    heading: "Connect and share your favorite AI models.",
    content: [
      "ChatGPT",
      "Claude",
      "Gemini",
      "MCP",
      "MCP Servers",
      "Check your plan before you share a Worker.",
    ],
  },
  "/use-cases/": {
    title: "Use Cases — Syntila",
    heading: "Make progress with AI, on your own or together.",
    content: [
      "Friends & Family",
      "Teams & Companies",
      "Software & Engineering Teams",
    ],
  },
  "/security/": {
    title: "Security — Syntila",
    heading: "Share AI access without sharing your secrets.",
    content: [
      "Space Membership",
      "Local execution, not a sandbox",
      "What Syntila Cloud stores",
      "Sharing a Worker means trusting the people you share it with.",
    ],
  },
  "/privacy/": {
    title: "Privacy — Syntila",
    heading: "Privacy follows the same boundaries as the product.",
    content: [
      "Human identity and Spaces",
      "Workspaces and local execution",
      "AI Accounts",
      "Data we collect",
      "Your rights",
    ],
  },
  "/downloads/": {
    title: "Install — Syntila",
    heading: "Run Syntila Workers on your computer.",
    content: ["Syntila Workspace", "Download", "macOS", "Windows", "Linux"],
  },
  "/faq/": {
    title: "FAQ — Syntila",
    heading: "Questions people ask first.",
    content: [
      "Can other people use my AI subscription through Syntila?",
      "What happens when the host computer is off or asleep?",
      "What does Syntila cost?",
    ],
  },
  "/terms/": {
    title: "Terms — Syntila",
    heading: "Terms of Service",
    content: [
      "Connected Workspaces",
      "Third-party AI providers",
      "Work outputs",
      "Governing law",
    ],
  },
};

const errors = [];
const sources = new Map();

for (const [route, file] of routes) {
  const source = await readFile(`${dist}${file}`, "utf8");
  sources.set(route, source);
  const contract = expected[route];
  const rawTitle = source.match(/<title>([^<]+)<\/title>/i)?.[1]?.trim();
  const title = decodeHtml(rawTitle);
  const description = decodeHtml(
    source.match(/<meta\b[^>]*name="description"[^>]*content="([^"]+)"/i)?.[1],
  );
  const canonical = source.match(
    /<link\b[^>]*rel="canonical"[^>]*href="([^"]+)"/i,
  )?.[1];
  const ogImage = source.match(
    /<meta\b[^>]*property="og:image"[^>]*content="([^"]+)"/i,
  )?.[1];
  const rawHeading = source.match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i)?.[1];
  const heading = decodeHtml(rawHeading);
  const visibleText = decodeHtml(
    source
      .replace(/<script[\s\S]*?<\/script>/gi, "")
      .replace(/<style[\s\S]*?<\/style>/gi, "")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " "),
  );

  if (title !== contract.title)
    errors.push(
      `${route}: title changed or missing (found: "${title}", expected: "${contract.title}")`,
    );
  if (!description?.trim()) errors.push(`${route}: description missing`);
  if (!canonical?.startsWith("https://syntila.app/"))
    errors.push(`${route}: canonical URL is malformed`);
  if (ogImage !== "https://syntila.app/social-preview.png")
    errors.push(
      `${route}: OpenGraph image URL must use https://syntila.app/social-preview.png (found: "${ogImage}")`,
    );
  if (!heading?.includes(contract.heading))
    errors.push(
      `${route}: critical h1 content changed or missing (found: "${heading}", expected to contain: "${contract.heading}")`,
    );
  for (const phrase of contract.content) {
    if (!visibleText.includes(phrase))
      errors.push(`${route}: required content missing: ${phrase}`);
  }
  if (/conclave/i.test(visibleText))
    errors.push(`${route}: the hosting domain must not appear in visible copy`);
  if (/secure vault/i.test(visibleText))
    errors.push(
      `${route}: must not claim Syntila stores provider credentials in a central vault`,
    );
}

const home = sources.get("/");
const appLinks = [...home.matchAll(/href="(https:\/\/app\.syntila\.app[^"]*)"/g)];
if (appLinks.length < 3)
  errors.push("homepage: expected at least three direct Open Syntila links");
if (!home.includes('id="plans"'))
  errors.push("homepage: Plans section anchor is missing");

for (const [route, source] of sources) {
  const githubLinks = [
    ...source.matchAll(/https:\/\/github\.com\/nohainc\/syntila[^"'\s]*/gi),
  ].map(([link]) => link);
  const approvedDownloads =
    route === "/downloads/" &&
    githubLinks.length > 0 &&
    githubLinks.every(
      (link) => link === "https://github.com/nohainc/syntila/releases/latest",
    );
  if (githubLinks.length > 0 && !approvedDownloads)
    errors.push(`${route}: public GitHub repository link must not be present`);
  if (/\b(?:architecture\s+)?v\d+\b/i.test(source))
    errors.push(
      `${route}: architecture version language must not be public product copy`,
    );

  for (const [, href] of source.matchAll(
    /<a\b[^>]*href="([^"#]+)(#[^"]+)?"/g,
  )) {
    if (!href.startsWith("/")) continue;
    const target = href.endsWith("/") ? href : `${href}/`;
    if (!routes.has(target) && target !== "/scripts/")
      errors.push(`${route}: internal link has no generated route: ${href}`);
  }
}

if (errors.length)
  throw new Error(`Content regression checks failed:\n${errors.join("\n")}`);

console.log(
  `Content regression checks passed: ${routes.size} critical routes, Thread terminology, CTA targets, private-repository posture, and metadata verified.`,
);
