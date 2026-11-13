#!/usr/bin/env bun
/**
 * Runs each test file in its own `bun test` process (like vitest's per-file
 * isolation: module mocks never leak between files), several at a time.
 * Usage: bun scripts/test.ts [filter...]   env TEST_JOBS (default 6)
 */
import { Glob } from "bun";

const filters = Bun.argv.slice(2);
const files = [...new Glob("test/**/*.test.ts").scanSync(".")].sort()
  .filter((f) => filters.length === 0 || filters.some((p) => f.includes(p)));
const jobs = Number(process.env.TEST_JOBS ?? 4);
let pass = 0, fail = 0, failedFiles: { file: string; fail: number; output: string }[] = [];
const started = performance.now();
let next = 0;

async function worker() {
  while (next < files.length) {
    const file = files[next++]!;
    const proc = Bun.spawn(["bun", "test", "--timeout", "20000", "--preload", "./test/preload.ts", file], { stdout: "pipe", stderr: "pipe" });
    const [out, err] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
    await proc.exited;
    const text = out + err;
    const p = Number(text.match(/^\s*(\d+) pass$/m)?.[1] ?? 0);
    const f = Number(text.match(/^\s*(\d+) fail$/m)?.[1] ?? 0) + (proc.exitCode && !/\d+ fail/.test(text) ? 1 : 0);
    pass += p; fail += f;
    if (f) failedFiles.push({ file, fail: f, output: text });
    if (process.env.TEST_VERBOSE || f) process.stdout.write(`${f ? "FAIL" : "ok  "} ${file} (${p} pass, ${f} fail)\n`);
  }
}
await Promise.all(Array.from({ length: Math.min(jobs, files.length) }, worker));
// The synchronous fixture bridge can deadlock against a background async
// transaction under heavy parallel load (test-harness only). Re-run failed
// files once, alone, and report the ones that pass as flaky.
const flaky: string[] = [];
for (const failed of [...failedFiles]) {
  const proc = Bun.spawn(["bun", "test", "--timeout", "20000", "--preload", "./test/preload.ts", failed.file], { stdout: "pipe", stderr: "pipe" });
  const text = (await new Response(proc.stdout).text()) + (await new Response(proc.stderr).text());
  await proc.exited;
  if (proc.exitCode === 0) {
    flaky.push(failed.file);
    fail -= failed.fail; pass += failed.fail;
    failedFiles.splice(failedFiles.indexOf(failed), 1);
  } else failed.output = text;
}
if (flaky.length) process.stdout.write(`flaky (passed on serial retry): ${flaky.join(", ")}\n`);
// Drop the per-test databases of all finished test processes in one place.
try {
  const { SQL } = await import("bun");
  const admin = new SQL(process.env.TEST_DATABASE_URL ?? "postgres://syntila_app:devpass@127.0.0.1:5432/postgres", { max: 4 });
  const dbs: { datname: string }[] = await admin`SELECT datname FROM pg_database WHERE datname LIKE 'syntila\_t\_%'`;
  await Promise.all(dbs.map(({ datname }) => admin.unsafe(`DROP DATABASE IF EXISTS ${datname} WITH (FORCE)`).catch(() => {})));
  await admin.close();
} catch {}
if (process.env.TEST_LOG) await Bun.write(process.env.TEST_LOG, failedFiles.map((f) => `### ${f.file}\n${f.output}`).join("\n"));
console.log(`\n${pass} pass, ${fail} fail across ${files.length} files in ${((performance.now() - started) / 1000).toFixed(1)}s`);
process.exit(fail ? 1 : 0);
