import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, expect, it } from "./helpers/vitest-compat";

const root = new URL("../../src/domain", import.meta.url).pathname;

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory()
      ? sources(path)
      : path.endsWith(".ts")
        ? [path]
        : [];
  });
}

/**
 * Every statement that writes `worker_assignments.status` must be a
 * conditional UPDATE, and only reviewed modules may contain one. A new writer
 * that skips the canonical transition rules fails here, not in production.
 */
const REVIEWED_WRITERS = new Set([
  // Canonical message-driven transitions (admission, provider start).
  "assignment-transitions.ts",
  // created->dispatched bookkeeping and the terminal result/error/cancel paths.
  "assignment-dispatcher.ts",
  // Revocation: pending -> reconciling escalation (the only other status writer).
  "assignment-revocation.ts",
  // Grant revocation cancels only assignments that were never accepted.
  "routes/workspaces-grants.ts",
]);

describe("worker_assignments status writers", () => {
  const statements = sources(root).flatMap((file) => {
    const text = readFileSync(file, "utf8");
    return [
      ...text.matchAll(/UPDATE\s+worker_assignments\s+SET\s+status/g),
    ].map((match) => ({
      file: relative(root, file),
      sql: text.slice(match.index!, match.index! + 600),
    }));
  });

  it("finds the known writers", () => {
    expect(statements.length).toBeGreaterThanOrEqual(5);
  });

  it("only occurs in reviewed modules", () => {
    for (const { file } of statements) {
      expect(REVIEWED_WRITERS, file).toContain(file);
    }
  });

  it("always guards on the current status", () => {
    for (const { file, sql } of statements) {
      expect(sql, file).toMatch(/WHERE[\s\S]*?\bstatus\s+(IN|=)\s/);
    }
  });

  it("never lists a terminal status as a source of a transition", () => {
    for (const { file, sql } of statements) {
      const guard = sql.match(/WHERE[\s\S]*?status\s+IN\s*\(([^)]*)\)/)?.[1];
      if (!guard || guard.includes("${")) continue;
      expect(guard, file).not.toMatch(
        /completed|failed|cancelled|timed_out|lost/,
      );
    }
  });
});
