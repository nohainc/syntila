import { describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("./verify-production-security.mjs", import.meta.url));
const valid = {
  vars: { SYNTILA_ENVIRONMENT: "production", SYNTILA_BACKEND_URL: "https://api.syntila.app" },
  routes: [{ pattern: "app.syntila.app", custom_domain: true }],
  assets: { binding: "ASSETS", run_worker_first: ["/api/*"] },
  d1_databases: [{ binding: "SYNTILA_DB", database_name: "syntila-auth" }],
  secrets: { required: ["SYNTILA_BACKEND_SIGNING_KEY", "BETTER_AUTH_SECRET", "EMAIL_RELAY_SECRET"] },
};
function check(config) {
  const dir = mkdtempSync(join(tmpdir(), "syntila-security-preflight-"));
  try {
    const path = join(dir, "config.json");
    writeFileSync(path, JSON.stringify(config));
    return spawnSync(process.execPath, [script, path], { encoding: "utf8" });
  } finally { rmSync(dir, { recursive: true, force: true }); }
}
describe("production security preflight", () => {
  it("accepts the production auth edge configuration", () => {
    expect(check(valid).status).toBe(0);
  });
  it("rejects a missing backend signing secret", () => {
    const result = check({ ...valid, secrets: { required: ["BETTER_AUTH_SECRET", "EMAIL_RELAY_SECRET"] } });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("backend signing secret");
  });
  it("rejects configuration that bypasses the auth Worker for API routes", () => {
    const result = check({ ...valid, assets: { binding: "ASSETS" } });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("API routes reach the auth Worker");
  });
  it("rejects a non-production backend", () => {
    const result = check({ ...valid, vars: { ...valid.vars, SYNTILA_BACKEND_URL: "http://localhost:8788" } });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("backend URL");
  });
  it("rejects a development database", () => {
    const result = check({ ...valid, d1_databases: [{ binding: "SYNTILA_DB", database_name: "syntila-development" }] });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("development resource names");
  });
  it("rejects anonymous development access", () => {
    const result = check({ ...valid, vars: { ...valid.vars, SYNTILA_ALLOW_ANONYMOUS_DEV: "true" } });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("anonymous development access");
  });
  it("requires secrets in the required secret list", () => {
    const result = check({ ...valid, secrets: { required: ["BETTER_AUTH_SECRET", "EMAIL_RELAY_SECRET"] }, note: "SYNTILA_BACKEND_SIGNING_KEY" });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("backend signing secret");
  });
});
