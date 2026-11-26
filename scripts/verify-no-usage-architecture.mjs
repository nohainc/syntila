import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const roots = [
  "apps/app/lib",
  "apps/cloud/src",
  "apps/backend/src",
  "apps/connect/lib",
  "packages",
];

const ignored = new Set([]);

const forbidden = [
  ["StudioRouteKind.usage", /\bStudioRouteKind\.usage\b/],
  ["StudioUsageReport", /\bStudioUsageReport\b/],
  ["StudioUsageSummary", /\bStudioUsageSummary\b/],
  ["StudioUsageRow", /\bStudioUsageRow\b/],
  ["handleSpaceUsage", /\bhandleSpaceUsage\b/],
  ["handleWorkspaceUsage", /\bhandleWorkspaceUsage\b/],
  ["recordV5AssignmentUsage", /\brecordV5AssignmentUsage\b/],
  ["assertV5BudgetAvailable", /\bassertV5BudgetAvailable\b/],
  ["assertV4BudgetAvailable", /\bassertV4BudgetAvailable\b/],
  ["CREATE TABLE usage", /CREATE\s+TABLE\s+usage\b/i],
  ["CREATE TABLE budgets", /CREATE\s+TABLE\s+budgets\b/i],
];

function scanFiles(entry) {
  if (!fs.existsSync(entry)) return [];
  const relative = path.relative(root, entry);
  if (
    ignored.has(relative) ||
    [...ignored].some((item) => relative.startsWith(`${item}/`))
  )
    return [];
  const stat = fs.lstatSync(entry);
  if (stat.isSymbolicLink()) return [];
  if (stat.isDirectory()) {
    return fs
      .readdirSync(entry)
      .flatMap((name) => scanFiles(path.join(entry, name)));
  }
  return /\.(?:ts|tsx|dart|js|mjs|sql)$/.test(entry) &&
    !entry.includes(`${path.sep}test${path.sep}`)
    ? [entry]
    : [];
}

const violations = [];
for (const file of roots.flatMap((dir) => scanFiles(path.join(root, dir)))) {
  const source = fs
    .readFileSync(file, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/\/\/.*$/gm, "")
    .replace(/--.*$/gm, "");

  for (const [label, pattern] of forbidden) {
    if (pattern.test(source)) {
      violations.push(`${label}: ${path.relative(root, file)}`);
    }
  }
}

if (violations.length > 0) {
  console.error("Usage architecture guard failed:");
  for (const violation of violations) {
    console.error(`- ${violation}`);
  }
  process.exit(1);
}

console.log(
  "Usage architecture guard passed: no active product usage infrastructure found.",
);
