import { execFileSync, spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, expect, it } from "vitest";

let root;
afterEach(() => {
  if (root) rmSync(root, { recursive: true, force: true });
});

it("checks auth SQL references against the current migrations", () => {
  root = mkdtempSync(join(tmpdir(), "syntila-auth-schema-"));
  mkdirSync(join(root, "scripts"), { recursive: true });
  mkdirSync(join(root, "apps/cloud/migrations"), { recursive: true });
  mkdirSync(join(root, "apps/cloud/src"), { recursive: true });
  cpSync(
    resolve("scripts/verify-cloud-schema-references.mjs"),
    join(root, "scripts/check.mjs"),
  );
  cpSync(
    resolve("apps/cloud/migrations/0001_auth.sql"),
    join(root, "apps/cloud/migrations/0001_auth.sql"),
  );
  const source = join(root, "apps/cloud/src/query.ts");
  const script = join(root, "scripts/check.mjs");
  writeFileSync(source, 'const query = "SELECT id FROM users";\n');
  expect(
    execFileSync(process.execPath, [script], { encoding: "utf8" }),
  ).toContain("match the auth schema");
  writeFileSync(source, 'const query = "SELECT id FROM missing_table";\n');
  const result = spawnSync(process.execPath, [script], { encoding: "utf8" });
  expect(result.status).toBe(1);
  expect(result.stderr).toContain("unknown auth table 'missing_table'");
});
