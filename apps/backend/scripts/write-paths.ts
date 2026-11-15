/**
 * Inventory of database write paths, for the concurrency plan
 * (removing the global writer lock). Scans src/ for SQL statements that
 * write, groups them by the function that contains them and flags the
 * patterns that matter once writes run in parallel:
 *
 *   numbering   `MAX(...) + 1` style numbering (races without a lock)
 *   read-write  the function also reads before writing (check-then-act)
 *   guarded     the write carries its own condition (NOT EXISTS, ON CONFLICT,
 *               WHERE status ...), which stays correct in parallel
 *   batch       writes are sent through `batch()`
 *
 * Usage: bun scripts/write-paths.ts            print to stdout
 *        bun scripts/write-paths.ts --write    write docs/backend/WRITE_PATHS.md
 */
import { readdir } from "node:fs/promises";
import { join, relative } from "node:path";

const ROOT = join(import.meta.dir, "..");
const SRC = join(ROOT, "src");
const OUT = join(ROOT, "..", "..", "docs", "backend", "WRITE_PATHS.md");

/** Phase-5 conversion groups, by file. First match wins. */
const AREAS: [RegExp, string][] = [
  [/^platform\/|^retention\.ts$/, "0 platform (native SQL, outside the adapter)"],
  [/queries\.ts$|http-security|idempotency|^internal\.ts$/, "0 shared helpers (converted with their callers)"],
  [/routes\/(notes|user-files|pins|profile|profiles|notifications|issue-reports)\.ts$|avatar-storage|attachment-storage|upload-stream|issue-report/, "1 personal data"],
  [/people|spaces|space-|invitation|account-|profile-admin|paddle|auth/, "2 people, Spaces, accounts"],
  [/threads|thread-history|thread-activity|reply-references|collaboration-events/, "3 Threads and messages"],
  [/work|conversation|workflow|assignment|thread-coordinator|thread-request-queue|execution|implement-plan|mcp|worker|scheduler/, "4 work core"],
  [/realtime|event-publisher|workspace|gateway|retention|durable-objects|releases|release-trust|email/, "5 realtime, gateway, jobs"],
];

interface Statement { table: string; verb: string; guarded: boolean; numbering: boolean }
interface Path { file: string; fn: string; area: string; statements: Statement[]; reads: boolean; batch: boolean; adapter: boolean; data: boolean }

async function files(dir: string): Promise<string[]> {
  const out: string[] = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await files(path)));
    else if (entry.name.endsWith(".ts")) out.push(path);
  }
  return out;
}

const WRITE = /\b(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+([a-z_][a-z0-9_]*)/gi;
const LITERAL = /`(?:\\.|[^`\\])*`|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'/g;
const FUNCTION = /(?:function\s*\*?\s*([A-Za-z0-9_$]+)|(?:const|let)\s+([A-Za-z0-9_$]+)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z0-9_$]+)\s*(?::[^=]+)?=>|^\s*(?:(?:private|public|protected|static|override)\s+)*(?:async\s+)?([A-Za-z0-9_$]+)\s*\([^)]*\)\s*(?::[^{]+)?\{)/gm;
const NOT_KEYWORDS = new Set(["if", "for", "while", "switch", "catch", "return", "function"]);

function enclosingFunctions(text: string): { at: number; name: string }[] {
  const out: { at: number; name: string }[] = [];
  for (const m of text.matchAll(FUNCTION)) {
    const name = m[1] ?? m[2] ?? m[3];
    if (name && !NOT_KEYWORDS.has(name)) out.push({ at: m.index!, name });
  }
  // SQL kept in a module constant belongs to no function.
  for (const m of text.matchAll(/^(?:export\s+)?const\s+([A-Z][A-Z0-9_]*)\s*=/gm))
    out.push({ at: m.index!, name: `(${m[1]})` });
  return out.sort((a, b) => a.at - b.at);
}

export async function collectWritePaths(): Promise<Path[]> {
  const paths = new Map<string, Path>();
  for (const path of (await files(SRC)).sort()) {
    const file = relative(SRC, path);
    if (file === "migrate.ts" || file === "schema-lock.ts") continue;
    const text = await Bun.file(path).text();
    const fns = enclosingFunctions(text);
    const owner = (at: number) => [...fns].reverse().find((f) => f.at <= at)?.name ?? "(module)";
    for (const literal of text.matchAll(LITERAL)) {
      const sql = literal[0];
      if (!/\b(SELECT|INSERT|UPDATE|DELETE)\b/.test(sql)) continue;
      const fn = owner(literal.index!);
      const key = `${file}#${fn}`;
      const entry = paths.get(key) ?? {
        file, fn, statements: [], reads: false, batch: false, adapter: false, data: false,
        area: AREAS.find(([re]) => re.test(file))?.[1] ?? "other",
      };
      const writes = [...sql.matchAll(WRITE)];
      if (writes.length === 0) {
        if (/^\W*SELECT\b/i.test(sql.slice(1))) entry.reads = true;
      }
      for (const w of writes) {
        if (/^UPDATE$/i.test(w[1]!) && !new RegExp(`UPDATE\\s+${w[2]}\\s+(?:AS\\s+\\w+\\s+)?SET\\b`, "i").test(sql)) continue;
        entry.statements.push({
          verb: w[1]!.split(/\s+/)[0]!.toUpperCase(),
          table: w[2]!.toLowerCase(),
          guarded: /\bNOT\s+EXISTS\b|\bON\s+CONFLICT\b|\bWHERE\b[\s\S]*\b(status|revision|version|generation|lease|claimed|state)\b/i.test(sql),
          numbering: /MAX\s*\([^)]*\)\s*\)?\s*,?\s*0?\s*\)?\s*\+\s*1|MAX\s*\([^)]*\)\s*\+\s*1/i.test(sql),
        });
      }
      paths.set(key, entry);
    }
    // File-level signals, attributed to every path in the file that writes.
    for (const entry of paths.values()) {
      if (entry.file !== file) continue;
      const body = sliceOf(text, fns, entry.fn);
      entry.batch ||= /\.batch\s*\(/.test(body);
      entry.adapter ||= /\.prepare\s*\(/.test(body);
      entry.data ||= /\bdataOf\s*\(|\.tx\s*\(|\b(?:q|tx)\.(?:rows|row|run)`/.test(body);
    }
  }
  return [...paths.values()].filter((p) => p.statements.length > 0);
}

function sliceOf(text: string, fns: { at: number; name: string }[], name: string): string {
  const i = fns.findIndex((f) => f.name === name);
  if (i < 0) return text;
  return text.slice(fns[i]!.at, fns[i + 1]?.at ?? text.length);
}

export function renderWritePaths(paths: Path[]): string {
  const tables = new Set(paths.flatMap((p) => p.statements.map((s) => s.table)));
  const count = (f: (p: Path) => boolean) => paths.filter(f).length;
  const lines = [
    "# Database write paths",
    "",
    "Generated by `bun scripts/write-paths.ts --write` in `apps/backend`. Do not edit by hand.",
    "Plan: `claude/concurrency-plan.md` (project). Flags:",
    "",
    "- **numbering**: `MAX(...) + 1` numbering; races once writes run in parallel.",
    "- **read-write**: the function reads before it writes (check-then-act); needs a row lock or a constraint.",
    "- **guarded**: every write carries its own condition (`NOT EXISTS`, `ON CONFLICT`, a status/version check).",
    "- **adapter**: still uses the D1-style adapter (`prepare`/`batch`), so it still takes the global writer lock.",
    "- **data**: uses the data layer (`src/platform/data.ts`): no global lock.",
    "",
    `Totals: ${paths.length} write paths, ${tables.size} tables; ` +
      `${count((p) => p.statements.some((s) => s.numbering))} numbering, ` +
      `${count((p) => p.reads && !p.statements.every((s) => s.guarded))} unguarded read-write, ` +
      `${count((p) => p.adapter)} on the adapter, ${count((p) => p.data && !p.adapter)} on the data layer.`,
    "",
  ];
  const areas = [...new Set(paths.map((p) => p.area))].sort();
  for (const area of areas) {
    lines.push(`## ${area}`, "", "| File | Function | Writes | Flags |", "| --- | --- | --- | --- |");
    for (const p of paths.filter((x) => x.area === area).sort((a, b) => (a.file + a.fn).localeCompare(b.file + b.fn))) {
      const writes = [...new Set(p.statements.map((s) => `${s.verb} ${s.table}`))].sort().join(", ");
      const flags = [
        p.statements.some((s) => s.numbering) && "numbering",
        p.reads && "read-write",
        p.statements.every((s) => s.guarded) && "guarded",
        p.batch && "batch",
        p.adapter && "adapter",
        p.data && "data",
      ].filter(Boolean).join(", ");
      lines.push(`| \`${p.file}\` | \`${p.fn}\` | ${writes} | ${flags} |`);
    }
    lines.push("");
  }
  return lines.join("\n");
}

if (import.meta.main) {
  const text = renderWritePaths(await collectWritePaths());
  if (Bun.argv.includes("--write")) {
    await Bun.write(OUT, text);
    console.log(`Wrote ${relative(process.cwd(), OUT)}`);
  } else process.stdout.write(text);
}
