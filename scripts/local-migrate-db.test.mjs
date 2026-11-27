import { afterEach, expect, it } from "vitest";
import {
  mkdtempSync,
  mkdirSync,
  copyFileSync,
  writeFileSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const roots = [];
afterEach(() => {
  for (const root of roots.splice(0))
    rmSync(root, { recursive: true, force: true });
});

function runMigration(options = {}, args = []) {
  const root = mkdtempSync(join(tmpdir(), "syntila-migration-test-"));
  roots.push(root);
  for (const dir of ["scripts", "bin", "apps/cloud", "apps/backend"])
    mkdirSync(join(root, dir), { recursive: true });
  copyFileSync(
    resolve("scripts/local-migrate-db.sh"),
    join(root, "scripts/local-migrate-db.sh"),
  );
  writeFileSync(join(root, "apps/cloud/wrangler.jsonc"), "{}");
  const log = join(root, "calls");
  const stubs = {
    pnpm: `#!/usr/bin/env bash\necho "pnpm $*" >> "$TEST_LOG"\n[[ "$*" == *"wrangler d1 migrations apply"*"--local"* ]] || exit 99\nif [[ "${options.failure ?? ""}" == d1 ]]; then echo 'D1 failure' >&2; exit 17; fi\n`,
    psql: `#!/usr/bin/env bash\necho "psql $*" >> "$TEST_LOG"\nif [[ "${options.failure ?? ""}" == preflight ]]; then exit 19; fi\nif [[ "$*" == *"select datname"* ]]; then ${options.databaseMissing ? ":" : "echo syntila_local"}; fi\n`,
    createdb: `#!/usr/bin/env bash\necho "createdb $*" >> "$TEST_LOG"\n`,
    bun: `#!/usr/bin/env bash\necho "bun $*" >> "$TEST_LOG"\n[[ "$PWD" == */apps/backend ]] || exit 99\nif [[ "${options.failure ?? ""}" == postgres ]]; then echo 'PostgreSQL failure' >&2; exit 23; fi\n`,
  };
  for (const [name, content] of Object.entries(stubs))
    writeFileSync(join(root, "bin", name), content, { mode: 0o755 });
  const result = spawnSync(
    "bash",
    [join(root, "scripts/local-migrate-db.sh"), ...args],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${join(root, "bin")}:${process.env.PATH}`,
        TEST_LOG: log,
        PGHOST: options.host ?? "127.0.0.1",
        PGDATABASE: "syntila_local",
        PGUSER: "syntila_app",
        SYNTILA_WRANGLER_CONFIG: join(root, "apps/cloud/wrangler.jsonc"),
      },
    },
  );
  let calls = "";
  try {
    calls = readFileSync(log, "utf8");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  return { ...result, calls };
}

it("migrates local D1 and PostgreSQL in order", () => {
  const result = runMigration();
  expect(result.status).toBe(0);
  expect(result.calls).toContain(
    "wrangler d1 migrations apply syntila-auth-development --local",
  );
  expect(result.calls).toContain("bun src/migrate.ts");
  expect(result.calls.indexOf("pnpm")).toBeLessThan(
    result.calls.indexOf("bun"),
  );
  expect(result.stdout).toContain("Local PostgreSQL migration complete.");
});

it("creates a missing local PostgreSQL database before migrating it", () => {
  const result = runMigration({ databaseMissing: true });
  expect(result.status).toBe(0);
  expect(result.calls).toContain("createdb -- syntila_local");
  expect(result.calls.indexOf("createdb")).toBeLessThan(
    result.calls.indexOf("bun"),
  );
});

it("supports the launcher's D1-only mode without touching PostgreSQL", () => {
  const result = runMigration({}, ["--d1-only"]);
  expect(result.status).toBe(0);
  expect(result.calls).toContain("pnpm");
  expect(result.calls).not.toMatch(/psql|createdb|bun/);
});

it("rejects non-local PostgreSQL before running either migration", () => {
  const result = runMigration({ host: "db.example.com" });
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain(
    "Refusing to migrate a non-local PostgreSQL host",
  );
  expect(result.calls).toBe("");
});

it("stops before D1 when local PostgreSQL is unreachable", () => {
  const result = runMigration({ failure: "preflight" });
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("PostgreSQL is not reachable");
  expect(result.calls).not.toContain("pnpm");
});

it("rejects unsupported options before touching either database", () => {
  const result = runMigration({}, ["--remote"]);
  expect(result.status).toBe(2);
  expect(result.calls).toBe("");
});

it("stops when D1 migration fails, without applying PostgreSQL migrations", () => {
  const result = runMigration({ failure: "d1" });
  expect(result.status).toBe(17);
  expect(result.stderr).toContain("D1 failure");
  expect(result.calls).not.toContain("bun");
  expect(result.stdout).not.toContain("Local D1 migration complete");
});

it("reports PostgreSQL failure after the completed D1 migration", () => {
  const result = runMigration({ failure: "postgres" });
  expect(result.status).toBe(23);
  expect(result.stdout).toContain("Local D1 migration complete.");
  expect(result.stdout).not.toContain("Local PostgreSQL migration complete.");
});
