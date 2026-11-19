#!/usr/bin/env node
/**
 * Worker-first P0 inventory: every table, column, foreign key, route and source
 * file that touches the legacy Workspace model (ADR-035).
 *
 *   node apps/backend/scripts/worker-first-inventory.mjs          print
 *   node apps/backend/scripts/worker-first-inventory.mjs --write  update the doc
 *   node apps/backend/scripts/worker-first-inventory.mjs --check  exit 1 when the doc differs from a fresh run
 *
 * The document is a snapshot: any change to the schema, routes or the counted
 * sources makes `--check` fail. It is for P1/P10 planning, not a CI gate.
 *
 * Inputs: migrations/schema.lock (tables, columns, constraints), the route table
 * (src/domain/routes/table.ts) and the TypeScript/Dart/Flutter sources. Plain
 * Node, no dependencies, so it runs anywhere the repository is checked out.
 * Route-to-table links are file-level: a handler "touches" a table when its
 * source file (or the files it imports from ./ in src/domain) names the table.
 */
import { readFileSync, writeFileSync, readdirSync, lstatSync, existsSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const backend = join(here, "..");
const root = join(backend, "..", "..");
const OUT = join(root, "docs", "roadmaps", "WORKER_FIRST_P0_INVENTORY.md");

/* ------------------------------------------------------------------ schema */

const lock = readFileSync(join(backend, "migrations", "schema.lock"), "utf8").split("\n");
const columns = []; // {table, column, type, notNull}
const constraints = []; // {table, name, kind, target, onDelete}
for (const line of lock) {
  let m = /^column (\w+)\.(\w+) (\S+)(.*)$/.exec(line);
  if (m) columns.push({ table: m[1], column: m[2], type: m[3], notNull: /not-null/.test(m[4]) });
  m = /^constraint (\w+)\.(\w+) (\S+)(?: -> (\w+) on-delete-(\S+))?/.exec(line);
  if (m) constraints.push({ table: m[1], name: m[2], kind: m[3], target: m[4], onDelete: m[5] });
}
const tables = [...new Set(columns.map((c) => c.table))].sort();

const LEGACY_TABLES = new Set(tables.filter((t) => t === "execution_workspaces" || t.startsWith("workspace_") || t === "thread_work_configs"));
const LEGACY_COLUMN = /(^|_)workspace_id$|^execution_workspace_id$|^primary_workspace_id$|runtime_identity_id|workspace_runtime_id|workspace_worker_id|workspace_space_grant_id|^workspace_id$/;
const FOCUS = [
  ["worker_assignments", "execution_workspace_id"],
  ["worker_assignments", "runtime_identity_id"],
  ["worker_activity_history", "workspace_id"],
];

/** Column guessed from a foreign-key name `<table>_<column>_fkey` (Postgres truncates long names). */
function fkColumn(c) {
  const stem = c.name.replace(/_fkey$/, "");
  return stem.startsWith(`${c.table}_`) ? stem.slice(c.table.length + 1) : stem;
}
const fks = constraints.filter((c) => c.kind === "foreign-key").map((c) => ({ ...c, column: fkColumn(c) }));

const legacyColumns = columns.filter((c) => !LEGACY_TABLES.has(c.table) && LEGACY_COLUMN.test(c.column));
const fksIntoLegacy = fks.filter((f) => LEGACY_TABLES.has(f.target) && !LEGACY_TABLES.has(f.table));
const fksBetweenLegacy = fks.filter((f) => LEGACY_TABLES.has(f.target) && LEGACY_TABLES.has(f.table));
const fksOutOfLegacy = fks.filter((f) => LEGACY_TABLES.has(f.table) && !LEGACY_TABLES.has(f.target));

/* ------------------------------------------------------------------ source */

function walk(dir, accept, skip = /(^|\/)(node_modules|dist|build|ephemeral|Pods|\.dart_tool|\.symlinks|_debug|_perf|_to_delete|\.git)(\/|$)/) {
  const out = [];
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (skip.test(relative(root, p))) continue;
    const s = lstatSync(p);
    if (s.isSymbolicLink()) continue;
    if (s.isDirectory()) out.push(...walk(p, accept, skip));
    else if (accept(p)) out.push(p);
  }
  return out;
}
const rel = (p) => relative(root, p).split("\\").join("/");
const backendSrc = walk(join(backend, "src"), (p) => p.endsWith(".ts"));
const text = new Map(backendSrc.map((p) => [p, readFileSync(p, "utf8")]));
const wordRe = (t) => new RegExp(`\\b${t}\\b`);

/** table -> backend files naming it (word match). */
const tableFiles = new Map();
for (const t of LEGACY_TABLES) {
  const re = wordRe(t);
  tableFiles.set(t, backendSrc.filter((p) => re.test(text.get(p))).map(rel).sort());
}
/** Backend files naming both the table and the column (a bare column such as workspace_id is too common alone). */
function columnFiles(table, col) {
  const tre = wordRe(table), cre = wordRe(col);
  return backendSrc.filter((p) => tre.test(text.get(p)) && cre.test(text.get(p))).map(rel).sort();
}

/* ------------------------------------------------------------------ routes */

const tableTs = readFileSync(join(backend, "src", "domain", "routes", "table.ts"), "utf8");
const routes = [];
for (const m of tableTs.matchAll(/r\(\s*"(\w+|\*)"\s*,\s*"([^"]+)"\s*,\s*([\s\S]*?)\)\s*,?\s*\n/g)) {
  const handler = /(?:call\(\s*"(handle\w+)")|\b(handle\w+)\(/.exec(m[3]);
  routes.push({ method: m[1] === "*" ? "ANY" : m[1], path: m[2], handler: handler ? handler[1] ?? handler[2] : "?" });
}
function handlerFile(name) {
  const re = new RegExp(`(?:function|const)\\s+${name}\\b`);
  const hit = backendSrc.find((p) => re.test(text.get(p)) && !p.endsWith("index.ts") && !p.endsWith("handlers.ts"));
  return hit ? rel(hit) : null;
}
const LEGACY_PATH = /workspace|worker|runtime|grant|workflow-workspace|mcp-(inventory|action)/;
const legacyRoutes = routes
  .map((r) => ({ ...r, file: handlerFile(r.handler) }))
  .map((r) => ({
    ...r,
    tables: r.file ? [...LEGACY_TABLES].filter((t) => wordRe(t).test(text.get(join(root, r.file)) ?? "")).sort() : [],
  }))
  .filter((r) => LEGACY_PATH.test(r.path) || r.tables.length);

/* ------------------------------------------------------------ other layers */

const TERMS = ["execution_workspace_id", "runtime_identity_id", "workspaceId", "workspace_id", "thread_work_configs", "workspace-runtime", "workspace-gateway"];
const LAYERS = [
  ["apps/backend (TypeScript)", join(root, "apps", "backend"), (p) => p.endsWith(".ts") && !/\/test\//.test(p)],
  ["apps/backend tests", join(root, "apps", "backend", "test"), (p) => p.endsWith(".ts")],
  ["apps/cloud (Cloudflare Worker)", join(root, "apps", "cloud"), (p) => p.endsWith(".ts") && !p.endsWith(".d.ts")],
  ["apps/workspace (Dart service + CLI)", join(root, "apps", "workspace"), (p) => p.endsWith(".dart")],
  ["apps/app (Flutter web/mobile)", join(root, "apps", "app"), (p) => p.endsWith(".dart")],
  ["packages/protocol", join(root, "packages", "protocol"), (p) => p.endsWith(".ts") || p.endsWith(".json")],
  ["packages/workspace-runtime-protocol", join(root, "packages", "workspace-runtime-protocol"), (p) => p.endsWith(".ts") || p.endsWith(".json")],
  ["packages/dart", join(root, "packages", "dart"), (p) => p.endsWith(".dart")],
  ["engines/cli_worker", join(root, "engines", "cli_worker"), (p) => p.endsWith(".dart")],
];
const layerRows = LAYERS.map(([name, dir, accept]) => {
  const files = walk(dir, accept);
  const counts = Object.fromEntries(TERMS.map((t) => [t, 0]));
  let touching = 0;
  for (const f of files) {
    const s = readFileSync(f, "utf8");
    let hit = false;
    for (const t of TERMS) {
      const n = s.split(t).length - 1;
      if (n) { counts[t] += n; hit = true; }
    }
    if (hit) touching++;
  }
  return { name, total: files.length, touching, counts };
});

/* ------------------------------------------------------------------ render */

const code = (s) => `\`${s}\``;
const list = (xs) => (xs.length ? xs.map(code).join(", ") : "none");
const lines = [];
const out = (s = "") => lines.push(s);

out("# Worker-first P0 inventory: legacy Workspace model");
out();
out("> Generated by `apps/backend/scripts/worker-first-inventory.mjs` from `apps/backend/migrations/schema.lock` and the sources. Do not edit by hand; run `node apps/backend/scripts/worker-first-inventory.mjs --write`. `--check` reports whether a fresh run differs; the file is a snapshot taken for P0.");
out();
out("Scope (P0 in `WORKER_FIRST_IMPLEMENTATION_PHASES.md`): `execution_workspaces`, every `workspace_*` table, `worker_assignments.execution_workspace_id` / `runtime_identity_id`, `worker_activity_history.workspace_id`, `thread_work_configs`, and every column or route that references them. Route-to-table links are file-level: a route is linked to a table when its handler's source file names that table. They show where to look, not proof of a query.");
out();
out("## Summary");
out();
out(`- Tables in scope: **${LEGACY_TABLES.size}**.`);
out(`- Columns outside those tables that reference them: **${legacyColumns.length}** in **${new Set(legacyColumns.map((c) => c.table)).size}** tables.`);
out(`- Foreign keys into the in-scope tables from other tables: **${fksIntoLegacy.length}**; between in-scope tables: **${fksBetweenLegacy.length}**; from in-scope tables to others: **${fksOutOfLegacy.length}**.`);
out(`- Routes that mention Workspace/Worker/runtime/grant or whose handler file names an in-scope table: **${legacyRoutes.length}** of ${routes.length}.`);
out();
out("## 1. Tables in scope");
out();
out("| Table | Columns | Foreign keys out | Foreign keys in | Backend files naming it |");
out("| --- | ---: | ---: | ---: | ---: |");
for (const t of [...LEGACY_TABLES].sort()) {
  out(`| ${code(t)} | ${columns.filter((c) => c.table === t).length} | ${fks.filter((f) => f.table === t).length} | ${fks.filter((f) => f.target === t).length} | ${tableFiles.get(t).length} |`);
}
out();
out("### Source files per table");
out();
for (const t of [...LEGACY_TABLES].sort()) {
  out(`- ${code(t)}: ${list(tableFiles.get(t).map((f) => f.replace(/^apps\/backend\/src\//, "")))}`);
}
out();
out("## 2. Focus columns named in P0");
out();
out("| Column | Type | NOT NULL | Foreign key | Backend files naming the table and the column |");
out("| --- | --- | :-: | --- | --- |");
for (const [t, c] of FOCUS) {
  const col = columns.find((x) => x.table === t && x.column === c);
  const fk = fks.find((f) => f.table === t && f.column === c);
  out(`| ${code(`${t}.${c}`)} | ${col ? col.type : "missing"} | ${col?.notNull ? "yes" : "no"} | ${fk ? `${fk.target} (on delete ${fk.onDelete})` : "none"} | ${list(columnFiles(t, c).map((f) => f.replace(/^apps\/backend\/src\//, "")))} |`);
}
out();
out(`${code("thread_work_configs")} has no Workspace column; it is in scope because ADR-035 replaces per-Thread Workspace selection. Its columns: ${list(columns.filter((c) => c.table === "thread_work_configs").map((c) => c.column))}.`);
out();
out("## 3. Columns referencing the legacy model (outside the in-scope tables)");
out();
out("| Column | Type | NOT NULL | Has foreign key |");
out("| --- | --- | :-: | :-: |");
for (const c of legacyColumns.sort((a, b) => (a.table + a.column).localeCompare(b.table + b.column))) {
  const fk = fks.find((f) => f.table === c.table && f.column === c.column);
  out(`| ${code(`${c.table}.${c.column}`)} | ${c.type} | ${c.notNull ? "yes" : "no"} | ${fk ? `yes -> ${fk.target} (${fk.onDelete})` : "**no**"} |`);
}
out();
out("Rows marked **no** hold a legacy id without a database constraint (append-only history, logs, realtime events). They need an explicit decision in P1 and P10: they cannot be repaired by cascading deletes.");
out();
out("## 4. Foreign keys");
out();
out("Column names are read from constraint names (`<table>_<column>_fkey`); composite keys and names shortened by PostgreSQL appear as their stem.");
out();
const fkTable = (title, rows) => {
  out(`### ${title} (${rows.length})`);
  out();
  out("| From | To | On delete |");
  out("| --- | --- | --- |");
  for (const f of rows.sort((a, b) => (a.table + a.column).localeCompare(b.table + b.column))) out(`| ${code(`${f.table}.${f.column}`)} | ${code(f.target)} | ${f.onDelete} |`);
  out();
};
fkTable("Into the in-scope tables, from other tables", fksIntoLegacy);
fkTable("Between in-scope tables", fksBetweenLegacy);
fkTable("From in-scope tables to other tables", fksOutOfLegacy);
out("## 5. Routes");
out();
out("| Method | Path | Handler | Handler file | In-scope tables named there |");
out("| --- | --- | --- | --- | --- |");
for (const r of legacyRoutes) out(`| ${r.method} | ${code(r.path)} | ${code(r.handler)} | ${r.file ? code(r.file.replace(/^apps\/backend\/src\/domain\//, "")) : "?"} | ${list(r.tables)} |`);
out();
out("## 6. Other layers (occurrence counts)");
out();
out(`| Layer | Files | Files touching | ${TERMS.map(code).join(" | ")} |`);
out(`| --- | ---: | ---: | ${TERMS.map(() => "---:").join(" | ")} |`);
for (const l of layerRows) out(`| ${l.name} | ${l.total} | ${l.touching} | ${TERMS.map((t) => l.counts[t]).join(" | ")} |`);
out();
out("Dart code uses camelCase (`workspaceId`), so its snake_case counts are near zero by construction. Counts are occurrences, not call sites.");
out();

const rendered = lines.join("\n");
const arg = process.argv[2];
if (arg === "--write") {
  writeFileSync(OUT, rendered);
  console.log(`wrote ${rel(OUT)}`);
} else if (arg === "--check") {
  const current = existsSync(OUT) ? readFileSync(OUT, "utf8") : "";
  if (current !== rendered) {
    console.error(`${rel(OUT)} is stale: run node apps/backend/scripts/worker-first-inventory.mjs --write`);
    process.exit(1);
  }
  console.log("inventory is current");
} else {
  process.stdout.write(rendered);
}
