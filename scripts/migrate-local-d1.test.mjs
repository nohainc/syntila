import { expect, it } from "vitest";
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

it("shows captured inspection errors and stops before applying migrations", () => {
  const root = mkdtempSync(join(tmpdir(), "syntila-migration-test-"));
  try {
    mkdirSync(join(root, "scripts"));
    mkdirSync(join(root, "bin"));
    mkdirSync(join(root, "apps/cloud"), { recursive: true });
    copyFileSync(resolve("scripts/migrate-local-d1.sh"), join(root, "scripts/migrate-local-d1.sh"));
    writeFileSync(join(root, "apps/cloud/wrangler.jsonc"), "{}");
    writeFileSync(join(root, "bin/pnpm"), `#!/usr/bin/env bash
if [[ "$*" != *"SELECT type,name"* ]]; then
  echo "unexpected migration command" >&2
  exit 99
fi
echo '{"error":"inspection database failure"}'
echo 'inspection stderr detail' >&2
exit 17
`, { mode: 0o755 });
    const result = spawnSync("bash", [join(root, "scripts/migrate-local-d1.sh")], {
      encoding: "utf8",
      env: { ...process.env, PATH: `${join(root, "bin")}:${process.env.PATH}`,
        SYNTILA_WRANGLER_CONFIG: join(root, "apps/cloud/wrangler.jsonc") },
    });
    expect(result.status).toBe(17);
    expect(result.stderr).toContain("Local D1 schema inspection failed (exit 17)");
    expect(result.stderr).toContain("inspection database failure");
    expect(result.stderr).toContain("inspection stderr detail");
    expect(result.stderr).toContain("Pending migrations were not applied");
    expect(result.stderr).not.toContain("unexpected migration command");
    expect(result.stdout).not.toContain("Applying pending local migrations");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
