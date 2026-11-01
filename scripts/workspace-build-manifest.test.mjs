import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  readFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { afterEach, expect, it } from "vitest";

const roots = [];
afterEach(() => {
  for (const root of roots.splice(0))
    rmSync(root, { recursive: true, force: true });
});
it("packaging rejects missing, mismatched and altered build output", () => {
  const root = mkdtempSync(join(tmpdir(), "workspace-manifest-"));
  roots.push(root);
  mkdirSync(join(root, "assets/engines"), { recursive: true });
  for (const name of ["syntila", "assets/engines/syntila-agent"]) {
    writeFileSync(join(root, name), "fixture");
  }
  const run = (mode, version = "1.0.4") =>
    execFileSync(
      process.execPath,
      ["scripts/workspace-build-manifest.mjs", mode, root, version],
      { stdio: "pipe" },
    );
  expect(() => run("verify")).toThrow();
  run("record");
  const provenance = JSON.parse(
    readFileSync(join(root, "build-provenance.json"), "utf8"),
  );
  expect(provenance.gitCommit).toMatch(/^[a-f0-9]{40}$/);
  expect(provenance.sourceDigest).toMatch(/^[a-f0-9]{64}$/);
  expect(provenance.version).toBe("1.0.4");
  expect(typeof provenance.includesUncommittedChanges).toBe("boolean");
  expect(Array.isArray(provenance.changedFiles)).toBe(true);
  expect(() => run("verify")).not.toThrow();
  expect(() => run("verify", "1.0.5")).toThrow();
  writeFileSync(join(root, "syntila"), "stale");
  expect(() => run("verify")).toThrow();
});
