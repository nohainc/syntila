import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseEnv } from "node:util";
import { afterEach, expect, it } from "vitest";
import { setupDevelopmentAuth } from "./local-setup-auth.mjs";

const roots = [];
function temporaryRoot() {
  const root = mkdtempSync(join(tmpdir(), "syntila-local-auth-"));
  roots.push(root);
  mkdirSync(join(root, "apps/cloud"), { recursive: true });
  return root;
}
afterEach(() =>
  roots.splice(0).forEach((root) => rmSync(root, { recursive: true })),
);

it("generates a persistent private secret and preserves other local settings", () => {
  const root = temporaryRoot();
  const file = join(root, "apps/cloud/.dev.vars");
  const previous = "# Existing settings\nOTHER_SECRET=keep";
  writeFileSync(file, previous);
  expect(setupDevelopmentAuth(root)).toEqual({ generated: true });
  const source = readFileSync(file, "utf8");
  expect(source.startsWith(previous)).toBe(true);
  expect(parseEnv(source).BETTER_AUTH_SECRET).toMatch(/^[a-f0-9]{64}$/);
  expect(statSync(file).mode & 0o777).toBe(0o600);
  expect(setupDevelopmentAuth(root)).toEqual({ generated: false });
  expect(readFileSync(file, "utf8")).toBe(source);
});
it("creates configuration for a fresh checkout", () => {
  const root = temporaryRoot();
  expect(setupDevelopmentAuth(root).generated).toBe(true);
});
it("preserves configured secrets and rejects explicit empty configuration", () => {
  const root = temporaryRoot();
  const file = join(root, "apps/cloud/.dev.vars");
  writeFileSync(file, "BETTER_AUTH_SECRET=existing-secret\n");
  expect(setupDevelopmentAuth(root).generated).toBe(false);
  expect(parseEnv(readFileSync(file, "utf8")).BETTER_AUTH_SECRET).toBe(
    "existing-secret",
  );
  writeFileSync(file, 'BETTER_AUTH_SECRET=""\n');
  expect(() => setupDevelopmentAuth(root)).toThrow("empty");
  expect(readFileSync(file, "utf8")).toBe('BETTER_AUTH_SECRET=""\n');
});
