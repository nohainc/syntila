/**
 * Ratchets for the SQL-layer refactor (claude/sql-refactor-plan.md). Each limit
 * may only go DOWN: when a commit removes sites, lower the number in the same
 * commit. The end state of every counter is 0.
 */
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
function files(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? files(path) : path.endsWith(".ts") ? [path] : [];
  });
}
const source = files(join(root, "src"));
const tests = files(join(root, "test")).filter((f) => !f.endsWith("ratchets.test.ts"));
const count = (list: string[], pattern: RegExp) =>
  list.reduce((n, f) => n + (readFileSync(f, "utf8").match(pattern)?.length ?? 0), 0);
const countFiles = (list: string[], pattern: RegExp) =>
  list.filter((f) => pattern.test(readFileSync(f, "utf8"))).length;

const LIMITS = {
  prepareCalls: 0,
  batchCalls: 0,
  d1DatabaseReferences: 0,
  mockBasedTestFiles: 4,  // test files that define a fake `prepare` database by hand
};

test("ratchet: .prepare( call sites only go down", () => {
  expect(count(source, /\.prepare\(/g)).toBeLessThanOrEqual(LIMITS.prepareCalls);
});
test("ratchet: .batch( call sites only go down", () => {
  expect(count(source, /\.batch\(/g)).toBeLessThanOrEqual(LIMITS.batchCalls);
});
test("ratchet: D1Database references only go down", () => {
  expect(count(source, /\bD1Database\b/g)).toBeLessThanOrEqual(LIMITS.d1DatabaseReferences);
});
test("ratchet: test files that fake prepare/bind by hand only go down", () => {
  // A fake database: a `prepare` method or property defined in the test itself.
  const fake = /prepare:|prepare\((sql|text|query|_?s)\b[^)]*\)\s*\{|prepare = |prepare\(\) *\{|const prepare|vi\.fn\(\(sql|spyOn\([^)]*prepare/;
  const faked = tests.filter((f) => !f.includes("/helpers/") && !f.endsWith("pg-d1.test.ts") && fake.test(readFileSync(f, "utf8")));
  expect(faked.length).toBeLessThanOrEqual(LIMITS.mockBasedTestFiles);
});
test("ratchet: the sqliteD1 alias is gone", () => {
  expect(countFiles(tests, /\bsqliteD1\b/)).toBe(0);
});
