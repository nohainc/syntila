#!/usr/bin/env bun
/**
 * Type check of the backend sources (src/**), as a ratchet.
 *
 * The backend runs on Bun without a build step, so nothing else compiles it:
 * a reference to a name that does not exist, a wrong argument count or a
 * property read on the wrong type only shows up at runtime. This check runs
 * the TypeScript compiler over `tsconfig.json` and compares the errors in
 * `src/` with `typecheck-baseline.json` (error count per file and code, no
 * line numbers, so edits elsewhere in a file do not matter):
 *   - more errors of a code in a file than the baseline -> fail;
 *   - fewer -> fine; run with --update to lower the baseline.
 * The baseline holds errors that predate the check, mostly missing Bun type
 * definitions (`@types/bun` is not installed yet) and loose environment
 * types. It may only go down.
 *
 * Usage: bun scripts/typecheck.ts [--update]
 */
import ts from "typescript";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, relative } from "node:path";

const root = join(dirname(new URL(import.meta.url).pathname), "..");
const baselinePath = join(root, "scripts", "typecheck-baseline.json");

export type Counts = Record<string, Record<string, number>>;

export function typeErrors(): { counts: Counts; lines: string[]; global: string[] } {
  const configPath = join(root, "tsconfig.json");
  const config = ts.readConfigFile(configPath, ts.sys.readFile);
  if (config.error) throw new Error(ts.flattenDiagnosticMessageText(config.error.messageText, "\n"));
  const parsed = ts.parseJsonConfigFileContent(config.config, ts.sys, root);
  const program = ts.createProgram(parsed.fileNames, parsed.options);
  const counts: Counts = {};
  const lines: string[] = [];
  const global: string[] = []; // configuration problems (a missing types package, a bad option)
  for (const d of ts.getPreEmitDiagnostics(program)) {
    if (!d.file) { global.push(ts.flattenDiagnosticMessageText(d.messageText, " ")); continue; }
    const file = relative(root, d.file.fileName);
    if (!file.startsWith("src/")) continue; // shared packages are checked by their own owners
    const code = `TS${d.code}`;
    (counts[file] ??= {})[code] = (counts[file][code] ?? 0) + 1;
    const { line, character } = d.file.getLineAndCharacterOfPosition(d.start ?? 0);
    lines.push(`${file}(${line + 1},${character + 1}): ${code} ${ts.flattenDiagnosticMessageText(d.messageText, " ")}`);
  }
  return { counts, lines, global };
}

export function compare(counts: Counts, baseline: Counts) {
  const worse: string[] = [];
  let better = 0;
  for (const [file, codes] of Object.entries(counts))
    for (const [code, n] of Object.entries(codes)) {
      const allowed = baseline[file]?.[code] ?? 0;
      if (n > allowed) worse.push(`${file} ${code}: ${n} (baseline ${allowed})`);
    }
  for (const [file, codes] of Object.entries(baseline))
    for (const [code, n] of Object.entries(codes)) better += Math.max(0, n - (counts[file]?.[code] ?? 0));
  return { worse, better };
}

function sorted(counts: Counts): Counts {
  return Object.fromEntries(Object.keys(counts).sort().map((f) =>
    [f, Object.fromEntries(Object.keys(counts[f]!).sort().map((c) => [c, counts[f]![c]!]))]));
}

if (import.meta.main) {
  const { counts, lines, global } = typeErrors();
  if (global.length) {
    console.error("The type check itself is misconfigured:\n" + global.join("\n"));
    process.exit(1);
  }
  if (process.argv.includes("--update")) {
    writeFileSync(baselinePath, JSON.stringify(sorted(counts), null, 2) + "\n");
    console.log(`typecheck baseline written: ${lines.length} known errors`);
    process.exit(0);
  }
  const baseline: Counts = existsSync(baselinePath) ? JSON.parse(readFileSync(baselinePath, "utf8")) : {};
  const { worse, better } = compare(counts, baseline);
  if (worse.length) {
    const files = new Set(worse.map((w) => w.split(" ")[0]));
    console.error("New type errors (fix them; never raise the baseline to hide one):");
    console.error(lines.filter((l) => files.has(l.split("(")[0]!)).join("\n"));
    console.error("\n" + worse.join("\n"));
    process.exit(1);
  }
  console.log(`typecheck ok: ${lines.length} known errors${better ? `; ${better} fewer than the baseline, run with --update to lower it` : ""}`);
}
