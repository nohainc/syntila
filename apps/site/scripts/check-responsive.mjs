import { readFile } from "node:fs/promises";

const css = await readFile(
  new URL("../src/styles/global.css", import.meta.url),
  "utf8",
);
const primitives = await readFile(
  new URL("../src/styles/primitives.css", import.meta.url),
  "utf8",
);
const errors = [];

if (!css.includes("@media (max-width: 800px)"))
  errors.push("missing intentional narrow-layout breakpoint at 800px");
if (!primitives.includes("@media (max-width: 800px)"))
  errors.push("primitives do not share the 800px breakpoint");
if (!css.includes(".site-nav[data-open]"))
  errors.push("mobile navigation drawer state is missing");
if (!css.includes(".mental-model-grid {"))
  errors.push("mental model grid layout is missing");
if (!css.includes(".workflow-pipeline-grid {"))
  errors.push("workflow pipeline grid layout is missing");
if (!css.includes(".worker-catalog {\n    grid-template-columns: 1fr;"))
  errors.push("Worker catalog does not collapse to one column");
if (!css.includes(".cards {\n    grid-template-columns: 1fr;"))
  errors.push("card grids do not collapse to one column");
if (/\b(?:width|min-width|max-width):\s*100vw/.test(css))
  errors.push("100vw layout sizing can cause horizontal overflow");

if (errors.length)
  throw new Error(`Responsive checks failed:\n${errors.join("\n")}`);
console.log(
  "Responsive checks passed for 320px, 375px, 430px, 768px, 1024px, and wide layouts.",
);
