/**
 * Every route in the table, called with junk input by a signed-in user who
 * owns a Space and a Thread: unknown ids, empty and wrong-typed bodies.
 * A 5xx is a bug: the client's mistake must be answered 4xx.
 */
import { afterAll, beforeAll, expect, test } from "bun:test";
import { signToken, TokenVerifier } from "../src/auth";
import { configureIdentityVerifier } from "../src/domain/auth/identity-service";
import { routeTable, type WorkerRouteHandlers } from "../src/domain/routes/table";
import { PgD1Database } from "../src/platform/pg-d1";
import { createRuntime } from "../src/runtime";
import { pgD1 } from "./domain/helpers/pg-d1";
import { message, user, workRequest, workspace } from "./domain/helpers/seed";
import { threadConversationId } from "../src/domain/routes/conversations";

let base = "", stop = async () => {}, mint: (sub: string) => Promise<string>, db: ReturnType<typeof pgD1>["sql"];
const logged: string[] = [];
beforeAll(async () => {
  const sql = db = pgD1().sql;
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k" };
  const priv = { ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid: "k" } as JsonWebKey & { kid: string };
  configureIdentityVerifier(new TokenVerifier([pub], "https://syntila.app", "syntila-backend"));
  const now = Math.floor(Date.now() / 1000);
  mint = (sub) => signToken(priv, { iss: "https://syntila.app", aud: "syntila-backend", sub, typ: "user", email: `${sub}@test`, name: sub, iat: now, exp: now + 3600, sid: `s-${sub}`, client: "web" });
  const runtime = createRuntime(sql, new PgD1Database(sql), { SYNTILA_ENVIRONMENT: "production", BETTER_AUTH_TRUSTED_ORIGINS: "https://syntila.app", SYNTILA_RATE_LIMIT_PER_MINUTE: "0", SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE: "0" });
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: (r, s) => runtime.fetch(r, s as any), websocket: runtime.websocket as any });
  await runtime.start();
  base = `http://127.0.0.1:${server.port}`;
  stop = async () => { server.stop(true); await runtime.stop(); };
  const original = console.error;
  console.error = (...args: unknown[]) => { logged.push(args.map(String).join(" ")); };
  afterAll(() => { console.error = original; });
});
afterAll(() => stop());

const call = async (token: string, method: string, path: string, body?: string) => {
  const r = await fetch(base + path, {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", origin: "https://syntila.app" },
    body: method === "GET" || method === "HEAD" ? undefined : body,
    signal: AbortSignal.timeout(8_000),
  }).catch((e) => (e?.name === "TimeoutError" ? null : Promise.reject(e)));
  // null: the request hung (reported as a failure below).
  if (!r) return { status: 599, body: null, text: "hung for 8 s" };
  const text = await r.text();
  let json: any = null;
  try { json = text ? JSON.parse(text) : null; } catch {}
  return { status: r.status, body: json, text };
};

const JUNK = [
  undefined,
  "{}",
  JSON.stringify({ name: 5, title: [], body: {}, kind: "nope", status: "nope", ids: "x", role: 7, email: 3, userId: [], permissions: "all", settings: "x", enabled: "yes", position: "first", limit: -1, cursor: 5, request: "x", message: 1, references: "x", attachments: {}, workerId: 1, runtimeId: 2, payload: "x" }),
  JSON.stringify({ name: "x".repeat(20_000), body: "x".repeat(200_000) }),
];
const QUERIES = ["", "?limit=abc&cursor=%%%&before=nope&after=-1"];

test("no route answers 5xx to junk input", async () => {
  const token = await mint("fuzz-owner");
  await call(token, "GET", "/api/session");
  const space = await call(token, "POST", "/api/spaces", JSON.stringify({ name: "Fuzz" }));
  expect(space.status).toBe(201);
  const spaceId = space.body.space.id;
  const thread = await call(token, "POST", `/api/spaces/${spaceId}/threads`, JSON.stringify({ name: "T" }));
  expect(thread.status).toBe(201);
  const threadId = thread.body.thread.id;
  // Real rows for the other path parameters, so requests get past the first
  // lookup and into the handlers' own checks.
  const note = await call(token, "POST", "/api/notes", JSON.stringify({ title: "n", body: "b" }));
  expect(note.status).toBe(201);
  const msg = await call(token, "POST", `/api/threads/${threadId}/messages`, JSON.stringify({ body: "hello" }));
  const other = "fuzz-other";
  await call(await mint(other), "GET", "/api/session");
  await call(token, "POST", "/api/people/invitations", JSON.stringify({ userId: other }));
  const invitation = await call(token, "GET", "/api/people/invitations");
  await db.unsafe([
    user("fuzz-ghost"),
    workspace("fuzz-ws", "fuzz-owner"),
    workRequest(threadId, "fuzz-owner", "{}", "fuzz-wr").replace("?", "'{}'"),
    message(threadId, "fuzz-owner", "[]", "fuzz-dm").replace("?", "'[]'"),
  ].join(";\n"));
  const real: Record<string, string> = {
    spaceId, threadId,
    workspaceId: "fuzz-ws",
    workRequestId: "fuzz-wr",
    messageId: msg.body?.message?.id ?? "fuzz-dm",
    noteId: note.body.note.id,
    userId: other,
    conversationId: threadConversationId(threadId),
    invitationId: invitation.body?.outgoing?.[0]?.id ?? "unknown",
  };

  const failures: string[] = [];
  for (const route of routeTable({} as WorkerRouteHandlers)) {
    const methods = route.method === "*" ? ["GET", "POST", "PUT", "PATCH", "DELETE"] : [route.method];
    for (const fill of ["real", "unknown"] as const) {
      const path = route.segments.map((s) => s.startsWith(":") ? encodeURIComponent(fill === "real" && real[s.slice(1)] || `unknown-${s.slice(1)}`) : s).join("/");
      for (const method of methods)
        for (const query of QUERIES)
          for (const body of JUNK) {
            const before = logged.length;
            const r = await call(token, method, `/${path}${query}`, body);
            if (process.env.FUZZ_REPORT && body === JUNK[2] && method !== "GET" && r.status < 300)
              console.log(`ACCEPTED ${method} ${route.path} [${fill}] -> ${r.status} ${r.text.slice(0, 160)}`);
            // 503 "unavailable" is a service this test does not configure (support, file storage).
            if (r.status >= 500 && !(r.status === 503 && r.body?.code === "unavailable")) {
              const log = logged.slice(before).find((l) => l.includes("unhandled_error")) ?? r.text.slice(0, 200);
              failures.push(`${method} ${route.path}${query} [${fill}] body=${(body ?? "none").slice(0, 30)} -> ${r.status} ${log.slice(0, 400)}`);
            }
          }
    }
  }
  if (failures.length) console.log(failures.join("\n"));
  expect(failures).toEqual([]);
}, 600_000);

test("an oversized body is refused with 413 promptly, not left hanging", async () => {
  const token = await mint("fuzz-big");
  await call(token, "GET", "/api/session");
  const ws = "fuzz-big-ws";
  await db.unsafe(workspace(ws, "fuzz-big"));
  const big = new Uint8Array(6 * 1024 * 1024);
  const form = new FormData();
  form.set("original", new File([big], "a.png", { type: "image/png" }));
  form.set("thumbnail", new File([new Uint8Array(10)], "t.png", { type: "image/png" }));
  const started = performance.now();
  const avatar = await fetch(base + "/api/profile/avatar", {
    method: "PUT", body: form, signal: AbortSignal.timeout(8_000),
    headers: { authorization: `Bearer ${token}`, origin: "https://syntila.app" },
  });
  expect(avatar.status).toBe(413);
  const prefs = await call(token, "PUT", `/api/workspaces/${ws}/worker-preferences`, JSON.stringify({ pad: "x".repeat(2 * 1024 * 1024) }));
  expect(prefs.status).toBe(413);
  // JSON bodies are capped at 2 MiB for every route, with or without an Idempotency-Key.
  const huge = JSON.stringify({ title: "t", body: "x".repeat(3 * 1024 * 1024) });
  const note = await call(token, "POST", "/api/notes", huge);
  expect([note.status, note.body?.code]).toEqual([413, "payload_too_large"]);
  const keyed = await fetch(base + "/api/notes", {
    method: "POST", body: huge, signal: AbortSignal.timeout(8_000),
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", origin: "https://syntila.app", "idempotency-key": "huge-0000000000001" },
  });
  expect(keyed.status).toBe(413);
  expect(performance.now() - started).toBeLessThan(8_000);
});
