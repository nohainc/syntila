/**
 * Route handlers read bodies through `readBody` (schema) or `readJson`
 * (src/domain/routes/validation.ts). A bare `request.json()` turns a
 * malformed body into a 500, and `.catch(() => …)` silently accepts it.
 */
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { readJson } from "../../src/domain/routes/validation";

const ROUTES = new URL("../../src/domain/routes/", import.meta.url);
// Maps its own SyntaxError to 400 together with the configuration's validation.
const ALLOWED = new Set(["workflow-configurations.ts", "validation.ts"]);

test("route handlers never call request.json() directly", () => {
  const offenders = readdirSync(ROUTES)
    .filter((f) => f.endsWith(".ts") && !ALLOWED.has(f))
    .filter((f) => /\brequest\.json\(\)/.test(readFileSync(new URL(f, ROUTES), "utf8")));
  expect(offenders).toEqual([]);
});

const req = (body?: string) => new Request("https://x/api", { method: "POST", body });

test("readJson: empty is {}, objects pass, the rest is a 400 with a code", async () => {
  expect(await readJson(req())).toEqual({});
  expect(await readJson(req("  "))).toEqual({});
  expect(await readJson(req('{"a":1}'))).toEqual({ a: 1 });
  for (const [body, code] of [["{x", "invalid_json"], ["[]", "invalid_request"], ["null", "invalid_request"], ['"s"', "invalid_request"], ["3", "invalid_request"]]) {
    await expect(readJson(req(body))).rejects.toMatchObject({ status: 400, code });
  }
});

test("route handlers never buffer a body with request.text()/clone().text() directly", () => {
  const offenders = readdirSync(ROUTES)
    .filter((f) => f.endsWith(".ts") && !["http-security.ts", "validation.ts", "issue-reports.ts"].includes(f))
    .filter((f) => /\brequest(?:\.clone\(\))?\.text\(\)/.test(readFileSync(new URL(f, ROUTES), "utf8")));
  expect(offenders).toEqual([]);
});

test("readJson and readBodyText refuse an oversized body with 413, declared or streamed", async () => {
  const { readBodyText } = await import("../../src/domain/routes/http-security");
  const big = "x".repeat(2 * 1024 * 1024 + 1);
  await expect(readJson(req(JSON.stringify({ a: big })))).rejects.toMatchObject({ status: 413, code: "payload_too_large" });
  // Declared length alone is enough.
  const declared = new Request("https://x/api", { method: "POST", body: "{}", headers: { "content-length": String(10 * 1024 * 1024) } });
  await expect(readBodyText(declared)).rejects.toMatchObject({ status: 413 });
  expect(await readBodyText(req("héllo"))).toBe("héllo");
  expect(await readBodyText(req("abcd"), 4)).toBe("abcd");
  await expect(readBodyText(req("abcde"), 4)).rejects.toMatchObject({ status: 413 });
});
