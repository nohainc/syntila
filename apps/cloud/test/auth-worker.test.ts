import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index.js";
import { handleEmailRelay } from "../src/email-relay.js";
import { prepareBackendAccountDeletion, syncBackendProfile, BackendUnavailableError } from "../src/backend-calls.js";

const SECRET = "relay-secret";
async function sign(body: string, ts: number, secret = SECRET) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${ts}.${body}`)));
  return btoa(String.fromCharCode(...sig)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
async function relayRequest(message: unknown, { ts = Math.floor(Date.now() / 1000), secret = SECRET } = {}) {
  const body = JSON.stringify(message);
  return new Request("https://syntila.app/api/internal/email", {
    method: "POST",
    headers: { "content-type": "application/json", "x-syntila-timestamp": String(ts), "x-syntila-signature": await sign(body, ts, secret) },
    body,
  });
}
function mailer(behaviour: (from: string) => Promise<{ messageId?: string }>) {
  const sent: { from: string; to: string; subject: string }[] = [];
  return {
    sent,
    binding: { async send(m: { from: { email: string } | string; to: string; subject: string }) {
      const from = typeof m.from === "string" ? m.from : m.from.email;
      sent.push({ from, to: m.to, subject: m.subject });
      return behaviour(from);
    } },
  };
}
const senders = { SYNTILA_EMAIL_FROM: "primary@syntila.test", SYNTILA_EMAIL_FALLBACK_FROM: "fallback@syntila.test" };

afterEach(() => vi.restoreAllMocks());

describe("email relay", () => {
  it("sends a signed message with the Worker's sender", async () => {
    const m = mailer(async () => ({ messageId: "m-1" }));
    const response = await handleEmailRelay(await relayRequest({ to: "a@example.com", subject: "Hi", text: "Hello" }), { ...senders, EMAIL_RELAY_SECRET: SECRET, SYNTILA_EMAIL: m.binding } as never);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ messageId: "m-1", usedFallback: false });
    expect(m.sent).toEqual([{ from: "primary@syntila.test", to: "a@example.com", subject: "Hi" }]);
  });

  it("falls back to the second sender when the first is rejected", async () => {
    const m = mailer(async (from) => {
      if (from === "primary@syntila.test") throw Object.assign(new Error("not verified"), { code: "sender_not_verified" });
      return { messageId: "m-2" };
    });
    const response = await handleEmailRelay(await relayRequest({ to: "a@example.com", subject: "Hi", html: "<p>Hi</p>" }), { ...senders, EMAIL_RELAY_SECRET: SECRET, SYNTILA_EMAIL: m.binding } as never);
    expect(await response.json()).toEqual({ messageId: "m-2", usedFallback: true });
  });

  it("rejects bad signatures, stale timestamps and invalid recipients", async () => {
    const env = { ...senders, EMAIL_RELAY_SECRET: SECRET, SYNTILA_EMAIL: mailer(async () => ({})).binding } as never;
    expect((await handleEmailRelay(await relayRequest({ to: "a@example.com", subject: "s", text: "t" }, { secret: "wrong" }), env)).status).toBe(401);
    expect((await handleEmailRelay(await relayRequest({ to: "a@example.com", subject: "s", text: "t" }, { ts: Math.floor(Date.now() / 1000) - 3600 }), env)).status).toBe(401);
    const invalid = await handleEmailRelay(await relayRequest({ to: "not-an-address", subject: "s", text: "t" }), env);
    expect(invalid.status).toBe(400);
    expect(await invalid.json()).toMatchObject({ code: "invalid_recipient" });
    expect((await handleEmailRelay(await relayRequest({ to: "a@example.com", subject: "s", text: "t" }), { ...senders } as never)).status).toBe(503);
  });
});

describe("backend calls", () => {
  async function signingKey() {
    const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
    return JSON.stringify({ ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid: "k1" });
  }
  const db = { prepare: () => ({ bind: () => ({ first: async () => ({ email: "a@example.com", name: "A", image: null, emailVerified: 1 }) }) }) };

  it("deletion requires the backend's confirmation, with an internal token", async () => {
    const env = { SYNTILA_BACKEND_SIGNING_KEY: await signingKey(), SYNTILA_BACKEND_URL: "https://api.test", SYNTILA_DB: db } as never;
    const calls: { url: string; auth: string | null }[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      calls.push({ url: String(input), auth: new Headers(init?.headers).get("authorization") });
      return Response.json({ ok: true });
    });
    await prepareBackendAccountDeletion(env, "u-1");
    expect(calls[0]!.url).toBe("https://api.test/internal/accounts/u-1/deletion");
    const claims = JSON.parse(atob(calls[0]!.auth!.split(".")[1]!.replace(/-/g, "+").replace(/_/g, "/")));
    expect(claims).toMatchObject({ typ: "internal", sub: "syntila-auth", aud: "syntila-backend" });
    expect(claims.exp - claims.iat).toBeLessThanOrEqual(60);

    vi.spyOn(globalThis, "fetch").mockImplementation(async () => new Response("down", { status: 503 }));
    await expect(prepareBackendAccountDeletion(env, "u-1")).rejects.toBeInstanceOf(BackendUnavailableError);
  });

  it("profile sync is best effort", async () => {
    const env = { SYNTILA_BACKEND_SIGNING_KEY: await signingKey(), SYNTILA_BACKEND_URL: "https://api.test", SYNTILA_DB: db } as never;
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => new Response("down", { status: 503 }));
    vi.spyOn(console, "warn").mockImplementation(() => {});
    await expect(syncBackendProfile(env, "u-1")).resolves.toBeUndefined();
  });
});

describe("auth Worker routing", () => {
  const env = { SYNTILA_ENVIRONMENT: "production" } as never;
  it("answers health and points product API calls at the backend", async () => {
    const health = await worker.fetch(new Request("https://syntila.app/health"), env);
    expect(await health.json()).toMatchObject({ ok: true, role: "auth" });
    const spaces = await worker.fetch(new Request("https://syntila.app/api/spaces"), env);
    expect(spaces.status).toBe(404);
    expect(await spaces.json()).toMatchObject({ code: "not_found" });
  });
  it("serves the web app for non-API paths", async () => {
    const assets = { fetch: async () => new Response("<html>app</html>") };
    const page = await worker.fetch(new Request("https://syntila.app/desktop-auth/approve"), { ...(env as object), ASSETS: assets } as never);
    expect(await page.text()).toBe("<html>app</html>");
  });
});
