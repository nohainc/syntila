import { describe, expect, it } from "vitest";
import { handleUserBackendToken } from "../src/backend-token.js";
import { HttpError } from "../src/routes/http-security.js";

async function keyPair() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const priv = { ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid: "k1" };
  return { secret: JSON.stringify(priv), publicKey: pair.publicKey };
}

function decode(token: string) {
  const [h = "", p = "", s = ""] = token.split(".");
  const b = (x: string) => Uint8Array.from(atob(x.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(x.length / 4) * 4, "=")), (c) => c.charCodeAt(0));
  return { header: JSON.parse(new TextDecoder().decode(b(h))), claims: JSON.parse(new TextDecoder().decode(b(p))), input: `${h}.${p}`, sig: b(s) };
}

/** Minimal D1 fake: answers by SQL fragment. */
function fakeDb(rows: Record<string, unknown>) {
  return {
    prepare(sql: string) {
      let args: unknown[] = [];
      const stmt = {
        bind: (...a: unknown[]) => ((args = a), stmt),
        first: async () => {
          for (const [fragment, value] of Object.entries(rows))
            if (sql.includes(fragment)) return typeof value === "function" ? (value as (a: unknown[]) => unknown)(args) : value;
          return null;
        },
      };
      return stmt;
    },
  } as unknown as D1Database;
}

const user = { id: "u-1", email: "a@example.com", displayName: "Alice", status: "active" as const, avatarUrl: null };
const authenticated = (status: "active" | "suspended" = "active") =>
  async () => ({ userId: user.id, user: { ...user, status }, spaceRoles: {}, sessionId: "s", clientType: "web" as const });

describe("backend tokens", () => {
  it("issues a verifiable short-lived user token", async () => {
    const { secret, publicKey } = await keyPair();
    const env = {
      SYNTILA_ENVIRONMENT: "development", TEST_AUTHENTICATION: authenticated(), SYNTILA_BACKEND_SIGNING_KEY: secret,
      BETTER_AUTH_URL: "https://syntila.app", SYNTILA_DB: fakeDb({ "FROM users": { emailVerified: 1 } }),
    } as never;
    const res = await handleUserBackendToken(new Request("https://syntila.app/api/backend-token", { method: "POST" }), env);
    expect(res.headers.get("cache-control")).toBe("no-store");
    const body = (await res.json()) as { token: string; backendUrl: string; expiresIn: number };
    expect(body.backendUrl).toBe("https://api.syntila.app");
    const { header, claims, input, sig } = decode(body.token);
    expect(header).toMatchObject({ alg: "EdDSA", kid: "k1" });
    expect(claims).toMatchObject({ iss: "https://syntila.app", aud: "syntila-backend", sub: "u-1", typ: "user", email: "a@example.com", email_verified: true, sid: "s", client: "web" });
    expect(claims.exp - claims.iat).toBe(900);
    expect(await crypto.subtle.verify({ name: "Ed25519" }, publicKey, sig, new TextEncoder().encode(input))).toBe(true);
  });

  it("refuses inactive users and unconfigured deployments", async () => {
    const { secret } = await keyPair();
    const req = () => new Request("https://syntila.app/api/backend-token", { method: "POST" });
    await expect(handleUserBackendToken(req(), { SYNTILA_ENVIRONMENT: "development", TEST_AUTHENTICATION: authenticated("suspended"), SYNTILA_BACKEND_SIGNING_KEY: secret, SYNTILA_DB: fakeDb({}) } as never))
      .rejects.toMatchObject({ status: 403 });
    await expect(handleUserBackendToken(req(), { SYNTILA_ENVIRONMENT: "development", TEST_AUTHENTICATION: authenticated(), SYNTILA_DB: fakeDb({}) } as never))
      .rejects.toBeInstanceOf(HttpError);
  });

});
