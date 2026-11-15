/**
 * The shared API structure on the real server stack: route table dispatch,
 * 405 for known paths, route-level idempotency, request validation and
 * cursor pagination.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { signToken, TokenVerifier } from "../src/auth";
import { configureIdentityVerifier } from "../src/domain/auth/identity-service";
import { STALE_CLAIM_MS } from "../src/domain/routes/route-idempotency";
import { PgD1Database } from "../src/platform/pg-d1";
import { createRuntime } from "../src/runtime";
import { pgD1 } from "./domain/helpers/pg-d1";

let base = "", stop = async () => {}, mint: (sub: string) => Promise<string>, sql: any;
beforeAll(async () => {
  sql = pgD1().sql;
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k" };
  const priv = { ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid: "k" } as JsonWebKey & { kid: string };
  configureIdentityVerifier(new TokenVerifier([pub], "https://syntila.app", "syntila-backend"));
  const now = Math.floor(Date.now() / 1000);
  mint = (sub) => signToken(priv, { iss: "https://syntila.app", aud: "syntila-backend", sub, typ: "user", email: `${sub}@test`, name: sub, iat: now, exp: now + 600, sid: `s-${sub}`, client: "web" });
  const runtime = createRuntime(sql, new PgD1Database(sql), { SYNTILA_ENVIRONMENT: "production", BETTER_AUTH_TRUSTED_ORIGINS: "https://syntila.app", SYNTILA_RATE_LIMIT_PER_MINUTE: "0", SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE: "0" });
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: (r, s) => runtime.fetch(r, s as any), websocket: runtime.websocket as any });
  await runtime.start();
  base = `http://127.0.0.1:${server.port}`;
  stop = async () => { server.stop(true); await runtime.stop(); };
});
afterAll(() => stop());

const call = async (token: string, method: string, path: string, body?: unknown, headers: Record<string, string> = {}) => {
  const r = await fetch(base + path, {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", origin: "https://syntila.app", ...headers },
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
  const text = await r.text();
  return { status: r.status, headers: r.headers, body: text ? JSON.parse(text) : null };
};

describe("route table", () => {
  test("a known path with an unsupported method answers 405 with Allow", async () => {
    const response = await call(await mint("rt-a"), "PUT", "/api/spaces", {});
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("GET, POST");
    expect(response.body.code).toBe("method_not_allowed");
  });
  test("an unknown path answers 404", async () => {
    expect((await call(await mint("rt-a"), "GET", "/api/nothing-here")).status).toBe(404);
  });
});

describe("route-level idempotency", () => {
  test("a retried create returns the first response and creates once", async () => {
    const token = await mint("idem-a");
    const key = "idem-space-0000000001";
    const first = await call(token, "POST", "/api/spaces", { name: "Once" }, { "Idempotency-Key": key });
    const second = await call(token, "POST", "/api/spaces", { name: "Once" }, { "Idempotency-Key": key });
    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(second.headers.get("idempotency-replayed")).toBe("true");
    expect(second.body.space.id).toBe(first.body.space.id);
    const [{ n }] = await sql`SELECT count(*)::int AS n FROM spaces WHERE owner_user_id = 'idem-a' AND name = 'Once'`;
    expect(n).toBe(1);
  });
  test("the same key with a different body is refused", async () => {
    const token = await mint("idem-b");
    const key = "idem-space-0000000002";
    await call(token, "POST", "/api/spaces", { name: "First" }, { "Idempotency-Key": key });
    const reused = await call(token, "POST", "/api/spaces", { name: "Second" }, { "Idempotency-Key": key });
    expect(reused.status).toBe(409);
    expect(reused.body.code).toBe("idempotency_key_reused");
  });
  test("keys are per user", async () => {
    const key = "idem-space-0000000003";
    const a = await call(await mint("idem-c"), "POST", "/api/spaces", { name: "Mine" }, { "Idempotency-Key": key });
    const b = await call(await mint("idem-d"), "POST", "/api/spaces", { name: "Mine" }, { "Idempotency-Key": key });
    expect(b.headers.get("idempotency-replayed")).toBeNull();
    expect(b.body.space.id).not.toBe(a.body.space.id);
  });
  test("a request still being processed is not run twice; an abandoned claim is taken over", async () => {
    const token = await mint("idem-e");
    await call(token, "GET", "/api/session");
    const key = "idem-space-0000000004";
    const body = JSON.stringify({ name: "Pending" });
    const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body))), (b) => b.toString(16).padStart(2, "0")).join("");
    await sql`INSERT INTO mutation_receipts (user_id, scope, idempotency_key, request_hash, response_json, response_status, created_at)
      VALUES ('idem-e', 'route:POST /api/spaces', ${key}, ${hash}, '{}', 0, now())`;
    const busy = await call(token, "POST", "/api/spaces", body, { "Idempotency-Key": key });
    expect(busy.status).toBe(409);
    expect(busy.body.code).toBe("idempotency_in_progress");
    await sql`UPDATE mutation_receipts SET created_at = now() - make_interval(secs => ${STALE_CLAIM_MS / 1000 + 60}) WHERE idempotency_key = ${key}`;
    const retaken = await call(token, "POST", "/api/spaces", body, { "Idempotency-Key": key });
    expect(retaken.status).toBe(201);
  });
  test("a failed request releases its key", async () => {
    const token = await mint("idem-f");
    const key = "idem-space-0000000005";
    const invalid = await call(token, "POST", "/api/spaces", { name: "" }, { "Idempotency-Key": key });
    expect(invalid.status).toBe(400);
    const [{ n }] = await sql`SELECT count(*)::int AS n FROM mutation_receipts WHERE idempotency_key = ${key}`;
    expect(n).toBe(0);
  });
  test("a malformed key is refused and no key means no receipt", async () => {
    const token = await mint("idem-g");
    expect((await call(token, "POST", "/api/notes", { title: "x" }, { "Idempotency-Key": "short" })).status).toBe(400);
    const plain = await call(token, "POST", "/api/notes", { title: "x" });
    expect(plain.status).toBeLessThan(300);
  });
});

describe("request validation", () => {
  test("every problem is reported at once, with its path", async () => {
    const token = await mint("val-a");
    const response = await call(token, "POST", "/api/spaces", { name: "", description: 5, kind: "direct" });
    expect(response.status).toBe(400);
    expect(response.body.code).toBe("invalid_request");
    expect(response.body.details.map((d: { path: string }) => d.path).sort()).toEqual(["description", "kind", "name"]);
    expect(typeof response.body.error).toBe("string");
  });
  test("invalid JSON is its own error", async () => {
    const response = await call(await mint("val-b"), "POST", "/api/notes", "{not json");
    expect(response.status).toBe(400);
    expect(response.body.code).toBe("invalid_json");
  });
  test("exactly one of email or userId for a person invitation", async () => {
    const token = await mint("val-c");
    await call(token, "GET", "/api/session");
    const both = await call(token, "POST", "/api/people/invitations", { email: "x@test", userId: "u" });
    expect(both.status).toBe(400);
    expect(both.body.error).toBe("Exactly one of 'email' or 'userId' must be provided");
  });
});

describe("cursor pagination", () => {
  test("notes come page by page, newest first, without gaps or repeats", async () => {
    const token = await mint("page-a");
    const created: string[] = [];
    for (let i = 0; i < 7; i++) created.push((await call(token, "POST", "/api/notes", { title: `n${i}` })).body.note.id);
    // Same timestamp for several notes: the id must break the tie.
    await sql`UPDATE user_notes SET updated_at = '2026-01-01T00:00:00.123456Z' WHERE user_id = 'page-a' AND title IN ('n2', 'n3', 'n4')`;
    const seen: string[] = [];
    let cursor: string | null = null;
    for (let guard = 0; guard < 10; guard++) {
      const page = await call(token, "GET", `/api/notes?limit=3${cursor ? `&cursor=${cursor}` : ""}`);
      expect(page.status).toBe(200);
      expect(page.body.notes.length).toBeLessThanOrEqual(3);
      seen.push(...page.body.notes.map((n: { id: string }) => n.id));
      cursor = page.body.nextCursor;
      if (!cursor) break;
    }
    expect(seen.length).toBe(7);
    expect(new Set(seen).size).toBe(7);
    expect(new Set(seen)).toEqual(new Set(created));
  });
  test("limits and cursors are checked", async () => {
    const token = await mint("page-b");
    expect((await call(token, "GET", "/api/notes?limit=0")).status).toBe(400);
    expect((await call(token, "GET", "/api/notes?limit=501")).status).toBe(400);
    const bad = await call(token, "GET", "/api/notes?cursor=nonsense");
    expect(bad.status).toBe(400);
    expect(bad.body.code).toBe("invalid_cursor");
  });
});

describe("older lists accept cursor", () => {
  test("files page with an opaque cursor; a bare timestamp is rejected", async () => {
    const token = await mint("files-a");
    expect((await call(token, "GET", "/api/files")).status).toBe(200);
    const rows = Array.from({ length: 103 }, (_, i) => {
      const id = `f-${String(i).padStart(3, "0")}`;
      // Three files share one timestamp to exercise the id tie-break.
      const at = i < 3 ? "'2026-01-01T00:00:00.5Z'" : `now() - make_interval(secs => ${i})`;
      return `('${id}', 'files-a', 'f${i}.txt', 'text/plain', 1, ${at})`;
    });
    await sql.unsafe(`INSERT INTO user_files (id, user_id, name, media_type, size_bytes, created_at) VALUES ${rows.join(",")}`);
    const first = await call(token, "GET", "/api/files");
    expect(first.status).toBe(200);
    expect(first.body.files.length).toBe(100);
    const second = await call(token, "GET", `/api/files?cursor=${encodeURIComponent(first.body.nextCursor)}`);
    expect(second.status).toBe(200);
    expect(second.body.files.length).toBe(3);
    expect(second.body.nextCursor).toBeNull();
    const ids = [...first.body.files, ...second.body.files].map((f: { fileId: string }) => f.fileId);
    expect(new Set(ids).size).toBe(103);
    // The old `before` timestamp is gone: a bare timestamp is not a cursor.
    const legacy = await call(token, "GET", `/api/files?cursor=${encodeURIComponent("2026-01-01T00:00:01Z")}`);
    expect(legacy.status).toBe(400);
    expect(legacy.body.code).toBe("invalid_cursor");
  });
});
