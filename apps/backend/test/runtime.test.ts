/**
 * End to end on the real server stack: Bun.serve + domain router + PostgreSQL
 * + in-process Durable Objects + WebSocket bridging + backend JWT auth.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { signToken, TokenVerifier } from "../src/auth";
import { configureIdentityVerifier } from "../src/domain/auth/identity-service";
import { PgD1Database } from "../src/platform/pg-d1";
import { createRuntime } from "../src/runtime";
import { pgD1 } from "./domain/helpers/pg-d1";

let base = "", stop = async () => {}, mint: (sub: string, extra?: Record<string, unknown>) => Promise<string>, runtime: ReturnType<typeof createRuntime>;
beforeAll(async () => {
  const { sql } = pgD1();
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k" };
  const priv = { ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid: "k" } as JsonWebKey & { kid: string };
  configureIdentityVerifier(new TokenVerifier([pub], "https://syntila.app", "syntila-backend"));
  const now = Math.floor(Date.now() / 1000);
  mint = (sub, extra = {}) => signToken(priv, { iss: "https://syntila.app", aud: "syntila-backend", sub, typ: "user", email: `${sub}@test`, name: sub, iat: now, exp: now + 600, sid: `s-${sub}`, client: "web", ...extra });
  runtime = createRuntime(sql as any, new PgD1Database(sql), { SYNTILA_ENVIRONMENT: "production", BETTER_AUTH_TRUSTED_ORIGINS: "https://syntila.app" });
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: (r, s) => runtime.fetch(r, s as any), websocket: runtime.websocket as any });
  await runtime.start();
  base = `http://127.0.0.1:${server.port}`;
  stop = async () => { server.stop(true); await runtime.stop(); };
});
afterAll(() => stop());

const api = async (token: string, method: string, path: string, body?: unknown) => {
  const r = await fetch(base + path, { method, headers: { authorization: `Bearer ${token}`, "content-type": "application/json", origin: "https://syntila.app" }, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await r.text();
  return { status: r.status, body: text ? JSON.parse(text) : null };
};

describe("runtime", () => {
  test("REST via JWT, realtime WebSocket through the in-process gateway, live fan-out of a Thread message", async () => {
    const alice = await mint("alice");
    expect((await api(alice, "GET", "/api/session")).body.user.id).toBe("alice");
    const created = await api(alice, "POST", "/api/spaces", { name: "Launch" });
    expect(created.status).toBe(201);
    const spaceId = created.body.space.id;
    const threads = await api(alice, "GET", `/api/spaces/${spaceId}/threads`);
    expect(threads.status).toBe(200);
    let threadId = threads.body.threads?.[0]?.id;
    if (!threadId) {
      const t = await api(alice, "POST", `/api/spaces/${spaceId}/threads`, { name: "General" });
      expect(t.status).toBeLessThan(300);
      threadId = t.body.thread?.id ?? t.body.id;
    }

    const ws = new WebSocket(base.replace("http", "ws") + "/api/realtime", { headers: { authorization: `Bearer ${alice}`, origin: "https://syntila.app" } } as any);
    const frames: any[] = [];
    ws.onmessage = (e) => frames.push(JSON.parse(String(e.data)));
    const waitFor = async (pred: (f: any) => boolean) => {
      for (let i = 0; i < 200; i++) { const f = frames.find(pred); if (f) return f; await Bun.sleep(25); }
      throw new Error(`no frame; got ${JSON.stringify(frames.map((f) => f.type))}`);
    };
    await waitFor((f) => f.type === "realtime.ready");
    ws.send(JSON.stringify({ type: "subscribe", scope: { kind: "space", spaceId } }));
    await waitFor((f) => f.type === "subscription.confirmed");

    const posted = await api(alice, "POST", `/api/threads/${threadId}/discussion-messages`, { body: "hello from postgres" });
    expect(posted.status).toBeLessThan(300);
    const event = await waitFor((f) => f.type !== "realtime.ready" && f.type !== "subscription.confirmed" && JSON.stringify(f).includes(threadId));
    expect(event).toBeTruthy();
    ws.close();
    // Gateway state survives in PostgreSQL storage.
    expect(runtime.hosts.realtimeGateway.size).toBeGreaterThan(0);
  });

  test("a Workspace Service registers with a desktop token and connects through the gateway WebSocket", async () => {
    const desktop = await mint("bob", { client: "desktop", client_aud: "syntila.desktop.management" });
    const web = await mint("bob");
    const body = {
      contractVersion: "1.0", installationId: `install_${crypto.randomUUID()}`, proposedWorkspaceName: "Bob's Mac",
      hostname: "bobs-mac", platform: "macos", architecture: "arm64", appVersion: "1.0.0", runtimeCapabilities: { os: "macos", arch: "arm64", appVersion: "1.0.0", supportedRuntimes: ["cli"], maxConcurrentWorkers: 2 },
    };
    expect((await api(web, "POST", "/api/workspace-runtime/register", body)).status).toBe(401); // web token is not a desktop session
    const reg = await api(desktop, "POST", "/api/workspace-runtime/register", body);
    if (reg.status >= 300) console.log("REG", JSON.stringify(reg.body));
    expect(reg.status).toBeLessThan(300);
    const runtimeId = reg.body.workspaceRuntimeId ?? reg.body.runtime?.id ?? reg.body.workspaceRuntime?.id;
    const credential = reg.body.runtimeCredential;
    expect(typeof runtimeId).toBe("string");
    expect(typeof credential).toBe("string");

    const ws = new WebSocket(`${base.replace("http", "ws")}/api/workspace-gateway/connect?workspaceRuntimeId=${encodeURIComponent(runtimeId)}`, { headers: { authorization: `Bearer ${credential}` } } as any);
    await new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = () => reject(new Error("gateway socket failed")); });
    for (let i = 0; i < 80; i++) {
      const [row] = await runtime.env.SYNTILA_DB.prepare("SELECT status FROM execution_workspaces WHERE id = ?1").bind(reg.body.workspaceId ?? reg.body.workspace?.id).all().then((r: any) => r.results);
      if (row?.status === "online") break;
      await Bun.sleep(25);
    }
    const list = await api(web, "GET", "/api/workspaces");
    expect(JSON.stringify(list.body)).toContain("online");
    ws.close();
  });

  test("browsers connect to realtime with a single-use ticket", async () => {
    const carol = await mint("carol");
    const { body } = await api(carol, "POST", "/api/realtime/tickets");
    const url = `${base.replace("http", "ws")}/api/realtime?ticket=${body.ticket}`;
    const ws = new WebSocket(url, { headers: { origin: "https://syntila.app" } } as any);
    const first = await new Promise<any>((resolve, reject) => { ws.onmessage = (e) => resolve(JSON.parse(String(e.data))); ws.onerror = () => reject(new Error("ws failed")); });
    expect(first.type).toBe("realtime.ready");
    ws.close();
    const reuse = await fetch(url.replace("ws", "http"), { headers: { upgrade: "websocket", origin: "https://syntila.app" } });
    expect(reuse.status).toBe(401);
  });

  test("unauthenticated API and realtime requests are rejected", async () => {
    expect((await fetch(base + "/api/spaces")).status).toBe(401);
    expect((await fetch(base + "/api/realtime", { headers: { upgrade: "websocket", origin: "https://syntila.app" } })).status).toBe(401);
  });
});
