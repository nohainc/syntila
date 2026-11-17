/**
 * The release publisher (scripts/release/publish-workspace-release.mjs) posts
 * the Workspace package inline as base64 JSON. Two regressions broke that:
 * the request schema dropped `packageBase64`, and the 2 MiB JSON body limit
 * refused any real package. A release manager's multi-megabyte package must
 * get past both and reach the signature check.
 */
import { afterAll, beforeAll, expect, test } from "bun:test";
import { signToken, TokenVerifier } from "../src/auth";
import { configureIdentityVerifier } from "../src/domain/auth/identity-service";
import { JSON_BODY_LIMIT } from "../src/domain/routes/http-security";
import { PgD1Database } from "./domain/helpers/pg-d1-adapter";
import { createRuntime } from "../src/runtime";
import { pgD1 } from "./domain/helpers/pg-d1";

let base = "", stop = async () => {}, mint: (sub: string) => Promise<string>;
beforeAll(async () => {
  const sql = pgD1().sql;
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k" };
  const priv = { ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid: "k" } as JsonWebKey & { kid: string };
  configureIdentityVerifier(new TokenVerifier([pub], "https://syntila.app", "syntila-backend"));
  const now = Math.floor(Date.now() / 1000);
  mint = (sub) => signToken(priv, { iss: "https://syntila.app", aud: "syntila-backend", sub, typ: "user", email: `${sub}@test`, name: sub, iat: now, exp: now + 3600, sid: `s-${sub}`, client: "web" });
  const runtime = createRuntime(sql, new PgD1Database(sql), {
    SYNTILA_ENVIRONMENT: "production", BETTER_AUTH_TRUSTED_ORIGINS: "https://syntila.app",
    SYNTILA_RATE_LIMIT_PER_MINUTE: "0", SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE: "0",
    SYNTILA_PROFILE_RELEASE_MANAGER_USER_IDS: "release-manager",
  });
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", maxRequestBodySize: 256 * 1024 * 1024, fetch: (r, s) => runtime.fetch(r, s as any), websocket: runtime.websocket as any });
  await runtime.start();
  base = `http://127.0.0.1:${server.port}`;
  stop = async () => { server.stop(true); await runtime.stop(); };
});
afterAll(() => stop());

const publish = async (who: string, body: unknown) => {
  const token = await mint(who);
  await fetch(`${base}/api/session`, { headers: { authorization: `Bearer ${token}`, origin: "https://syntila.app" } });
  const r = await fetch(`${base}/api/workspace-releases/publish`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", origin: "https://syntila.app" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(15_000),
  });
  return { status: r.status, body: await r.json().catch(() => null) };
};

const bigPackage = Buffer.alloc(JSON_BODY_LIMIT + 1024 * 1024, 7).toString("base64"); // ~4 MiB of base64

test("a release manager's inline package above 2 MiB reaches the signature check", async () => {
  const r = await publish("release-manager", { version: "9.9.9", channel: "stable", packageBase64: bigPackage });
  expect(r.body?.error).toBe("signingKeyId and signature are required");
  expect(r.status).toBe(400);
}, 30_000);

test("anyone else is refused before the body is read", async () => {
  const r = await publish("someone-else", { version: "9.9.9", packageBase64: bigPackage });
  expect(r.status).toBe(403);
}, 30_000);
