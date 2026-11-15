/**
 * Concurrency safety net (claude/concurrency-plan.md, Phase 0).
 *
 * Every scenario runs WITHOUT the global writer lock and with real parallel
 * connections, then checks scripts/check-invariants.sql. A scenario here
 * proves that its write path stays correct once the lock is gone; the lock
 * is removed (Phase 6) only when every write path has a scenario.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { SQL } from "bun";
import { signToken, TokenVerifier } from "../src/auth";
import { configureIdentityVerifier } from "../src/domain/auth/identity-service";
import { PgD1Database } from "../src/platform/pg-d1";
import { createRuntime } from "../src/runtime";
import { pgD1 } from "./domain/helpers/pg-d1";

const INVARIANTS = await Bun.file(new URL("../scripts/check-invariants.sql", import.meta.url)).text();
type Sql = InstanceType<typeof SQL>;

/** Invariants with violations, as `name: count`; empty when all hold. */
export async function brokenInvariants(sql: Sql): Promise<string[]> {
  const rows: { invariant: string; violations: number | bigint }[] = await sql.unsafe(INVARIANTS);
  return rows.filter((r) => Number(r.violations) > 0).map((r) => `${r.invariant}: ${r.violations}`);
}

let sql: Sql, base = "", stop = async () => {}, mint: (sub: string, extra?: Record<string, unknown>) => Promise<string>;
beforeAll(async () => {
  const db = pgD1({ writerLock: false, max: 24 });
  sql = db.sql;
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k" };
  const priv = { ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid: "k" } as JsonWebKey & { kid: string };
  configureIdentityVerifier(new TokenVerifier([pub], "https://syntila.app", "syntila-backend"));
  const now = Math.floor(Date.now() / 1000);
  mint = (sub, extra = {}) => signToken(priv, { iss: "https://syntila.app", aud: "syntila-backend", sub, typ: "user", email: `${sub}@test`, name: sub, iat: now, exp: now + 600, sid: `s-${sub}`, client: "web", ...extra });
  const runtime = createRuntime(sql, new PgD1Database(sql, { writerLock: false }), {
    SYNTILA_ENVIRONMENT: "production", BETTER_AUTH_TRUSTED_ORIGINS: "https://syntila.app",
    SYNTILA_RATE_LIMIT_PER_MINUTE: "0", SYNTILA_MUTATION_RATE_LIMIT_PER_MINUTE: "0",
  });
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
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  return { status: r.status, body: text ? JSON.parse(text) : null };
};

async function spaceWithThread(token: string, name: string) {
  const space = await call(token, "POST", "/api/spaces", { name });
  expect(space.status).toBe(201);
  const thread = await call(token, "POST", `/api/spaces/${space.body.space.id}/threads`, { name: "T" });
  expect(thread.status).toBe(201);
  return { spaceId: space.body.space.id as string, threadId: (thread.body.thread?.id ?? thread.body.id) as string };
}

/** A Conversation with its Thread, Space and owner, written directly. */
async function conversation(id: string) {
  await sql.unsafe(`
    INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES ('u-${id}', '${id}@test', '${id}', now(), now());
    INSERT INTO spaces (id, owner_user_id, name, created_at, updated_at) VALUES ('s-${id}', 'u-${id}', 'S', now(), now());
    INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES ('m-${id}', 's-${id}', 'u-${id}', 'owner', now(), now());
    INSERT INTO threads (id, space_id, name, status, lead_user_id, created_at, updated_at) VALUES ('t-${id}', 's-${id}', 'T', 'active', 'u-${id}', now(), now());
    INSERT INTO conversations (id, thread_id, workflow_id, workflow_version, created_at, updated_at) VALUES ('${id}', 't-${id}', 'chat', 1, now(), now());`);
}
const advance = (s: Sql, id: string) => s.unsafe(
  "UPDATE conversations SET conversation_revision = conversation_revision + 1, context_revision = context_revision + 1 WHERE id = $1", [id]);

describe("history numbering", () => {
  test("parallel writes to one Conversation number its history 1..n", async () => {
    await conversation("c-par");
    await Promise.all(Array.from({ length: 40 }, () => advance(sql, "c-par")));
    const [row] = await sql`SELECT count(*)::int AS n, max(sequence)::int AS top FROM conversation_history_entries WHERE conversation_id = 'c-par'`;
    expect(row).toEqual({ n: 40, top: 40 });
    expect(await brokenInvariants(sql)).toEqual([]);
  });

  test("writes to different Conversations do not wait for each other", async () => {
    await conversation("c-a");
    await conversation("c-b");
    let release!: () => void;
    const held = new Promise<void>((resolve) => (release = resolve));
    let started!: () => void;
    const inside = new Promise<void>((resolve) => (started = resolve));
    // Transaction 1 writes history for A and stays open.
    const first = sql.begin(async (tx) => {
      await advance(tx as unknown as Sql, "c-a");
      started();
      await held;
    });
    await inside;
    try {
      // Transaction 2 writes history for B; it must not wait for A.
      await sql.begin(async (tx) => {
        await tx.unsafe("SET LOCAL lock_timeout = '1s'");
        await advance(tx as unknown as Sql, "c-b");
      });
    } finally {
      release();
      await first;
    }
    expect(await brokenInvariants(sql)).toEqual([]);
  });
});

describe("HTTP write paths without the writer lock", () => {
  test("parallel discussion messages in one Thread", async () => {
    const token = await mint("conc-msg");
    const { threadId } = await spaceWithThread(token, "Messages");
    const results = await Promise.all(Array.from({ length: 30 }, (_, i) =>
      call(token, "POST", `/api/threads/${threadId}/discussion-messages`, { body: `m${i}` })));
    expect(results.map((r) => r.status).filter((s) => s !== 201)).toEqual([]);
    const [row] = await sql`SELECT count(*)::int AS n FROM discussion_messages WHERE thread_id = ${threadId} AND kind = 'message'`;
    expect(row.n).toBe(30);
    expect(await brokenInvariants(sql)).toEqual([]);
  });

  test("one create for parallel requests with the same Idempotency-Key", async () => {
    const token = await mint("conc-idem");
    const key = "conc-space-key-000000001";
    const results = await Promise.all(Array.from({ length: 10 }, () =>
      call(token, "POST", "/api/spaces", { name: "Exactly once" }, { "Idempotency-Key": key })));
    for (const r of results) expect([201, 409]).toContain(r.status);
    expect(results.some((r) => r.status === 201)).toBe(true);
    const [row] = await sql`SELECT count(*)::int AS n FROM spaces WHERE owner_user_id = 'conc-idem' AND name = 'Exactly once'`;
    expect(row.n).toBe(1);
    expect(await brokenInvariants(sql)).toEqual([]);
  });

  test("parallel Space creation by one user", async () => {
    const token = await mint("conc-spaces");
    const results = await Promise.all(Array.from({ length: 12 }, (_, i) =>
      call(token, "POST", "/api/spaces", { name: `S${i}` })));
    expect(results.map((r) => r.status).filter((s) => s !== 201)).toEqual([]);
    expect(await brokenInvariants(sql)).toEqual([]);
  });

  test("parallel edits of one note: exactly one wins, the rest get 409", async () => {
    const token = await mint("conc-note");
    const created = await call(token, "POST", "/api/notes", { title: "N", body: "v0" });
    expect(created.status).toBe(201);
    const { id, revision } = created.body.note;
    const results = await Promise.all(Array.from({ length: 12 }, (_, i) =>
      call(token, "PUT", `/api/notes/${id}`, { body: `v${i + 1}`, revision })));
    const statuses = results.map((r) => r.status).sort();
    expect(statuses.filter((s) => s === 200)).toHaveLength(1);
    expect(statuses.filter((s) => s === 409)).toHaveLength(11);
    const [row] = await sql`SELECT revision::int AS revision FROM user_notes WHERE id = ${id}`;
    expect(row.revision).toBe(revision + 1);
  });
});

describe("first requests of a new user", () => {
  test("many parallel first requests provision the user once, without errors", async () => {
    for (let round = 0; round < 5; round++) {
      const token = await mint(`conc-new-${round}`);
      const results = await Promise.all(Array.from({ length: 12 }, () => call(token, "GET", "/api/spaces")));
      expect(results.map((r) => r.status).filter((s) => s !== 200)).toEqual([]);
    }
    const [row] = await sql`SELECT count(*)::int AS n FROM users WHERE id LIKE 'conc-new-%'`;
    expect(row.n).toBe(5);
  });
});

describe("storage quota", () => {
  test("parallel upload reservations never exceed the allowance", async () => {
    const { reserveUpload } = await import("../src/domain/attachment-storage");
    await sql`INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES ('conc-quota', 'q@test', 'q', now(), now())`;
    // 980 MB used of the free 1 GB: room for exactly two 10 MB uploads.
    await sql`INSERT INTO user_files (id, user_id, name, media_type, size_bytes, created_at)
              VALUES ('wrf-used', 'conc-quota', 'big', 'application/octet-stream', 980000000, now())`;
    const env = { SYNTILA_DB: new PgD1Database(sql, { writerLock: false }) } as any;
    const results = await Promise.allSettled(Array.from({ length: 10 }, (_, i) =>
      reserveUpload(env, { fileId: `wrf-q${i}`, userId: "conc-quota", sizeBytes: 10_000_000 })));
    expect(results.filter((r) => r.status === "fulfilled")).toHaveLength(2);
    const [row] = await sql`SELECT COALESCE(sum(size_bytes), 0)::int8 AS reserved FROM user_file_reservations WHERE user_id = 'conc-quota'`;
    expect(Number(row.reserved)).toBe(20_000_000);
  });
});

describe("plan limits", () => {
  test("parallel invitations never take more than the free member slots of a Space", async () => {
    const token = await mint("conc-owner");
    const space = await call(token, "POST", "/api/spaces", { name: "Limits" });
    expect(space.status).toBe(201);
    const spaceId = space.body.space.id;
    // Free: 4 people including the owner, so 3 invitations fit.
    const results = await Promise.all(Array.from({ length: 10 }, (_, i) =>
      call(token, "POST", `/api/spaces/${spaceId}/invitations`, { email: `invitee-${i}@test`, role: "collaborator" })));
    const statuses = results.map((r) => r.status);
    expect(statuses.filter((s) => s === 201)).toHaveLength(3);
    expect(statuses.filter((s) => s !== 201 && s !== 402)).toEqual([]);
    const [row] = await sql`SELECT count(*)::int AS n FROM space_invitations WHERE space_id = ${spaceId} AND status = 'pending'`;
    expect(row.n).toBe(3);
  });

  test("parallel Workspace registrations never exceed the free Workspace allowance", async () => {
    const desktop = await mint("conc-ws", { client: "desktop", client_aud: "syntila.desktop.management" });
    const register = (i: number) => fetch(`${base}/api/workspace-runtime/register`, {
      method: "POST",
      headers: { authorization: `Bearer ${desktop}`, "content-type": "application/json" },
      body: JSON.stringify({
        contractVersion: "1.0", installationId: `install_${crypto.randomUUID()}`, proposedWorkspaceName: `Mac ${i}`,
        hostname: `mac-${i}`, platform: "macos", architecture: "arm64", appVersion: "1.0.0",
        runtimeCapabilities: { os: "macos", arch: "arm64", appVersion: "1.0.0", supportedRuntimes: ["cli"], maxConcurrentWorkers: 2 },
      }),
    }).then((r) => r.status);
    const statuses = await Promise.all(Array.from({ length: 6 }, (_, i) => register(i)));
    expect(statuses.filter((s) => s < 300)).toHaveLength(1);
    const [row] = await sql`SELECT count(*)::int AS n FROM execution_workspaces WHERE owner_user_id = 'conc-ws' AND status <> 'revoked'`;
    expect(row.n).toBe(1);
  });
});

/** Statuses other than the expected ones; a 5xx in a race is always a bug. */
const unexpected = (results: { status: number }[], allowed: number[]) =>
  results.map((r) => r.status).filter((s) => !allowed.includes(s));

describe("races on shared actions", () => {
  test("accepting one Space invitation from several devices at once", async () => {
    const owner = await mint("race-owner-1");
    const guest = await mint("race-guest-1");
    await call(guest, "GET", "/api/spaces"); // the invitee exists
    const space = await call(owner, "POST", "/api/spaces", { name: "Accept race" });
    const invite = await call(owner, "POST", `/api/spaces/${space.body.space.id}/invitations`, { email: "race-guest-1@test", role: "collaborator" });
    expect(invite.status).toBe(201);
    const id = invite.body.invitation.id;
    const results = await Promise.all(Array.from({ length: 6 }, () => call(guest, "POST", `/api/space-invitations/${id}/accept`, {})));
    expect(unexpected(results, [200, 201, 409])).toEqual([]);
    expect(results.some((r) => r.status < 300)).toBe(true);
    const [row] = await sql`SELECT count(*)::int AS n FROM space_memberships WHERE space_id = ${space.body.space.id} AND user_id = 'race-guest-1'`;
    expect(row.n).toBe(1);
    expect(await brokenInvariants(sql)).toEqual([]);
  });

  test("accepting and declining one Space invitation at the same moment", async () => {
    const owner = await mint("race-owner-2");
    const guest = await mint("race-guest-2");
    await call(guest, "GET", "/api/spaces");
    const space = await call(owner, "POST", "/api/spaces", { name: "Decide race" });
    const invite = await call(owner, "POST", `/api/spaces/${space.body.space.id}/invitations`, { email: "race-guest-2@test", role: "collaborator" });
    const id = invite.body.invitation.id;
    const results = await Promise.all([
      call(guest, "POST", `/api/space-invitations/${id}/accept`, {}),
      call(guest, "POST", `/api/space-invitations/${id}/decline`, {}),
      call(owner, "POST", `/api/spaces/${space.body.space.id}/invitations/${id}/expire`, {}),
    ]);
    expect(unexpected(results, [200, 201, 404, 405, 409])).toEqual([]);
    const [inv] = await sql`SELECT status FROM space_invitations WHERE id = ${id}`;
    const [m] = await sql`SELECT count(*)::int AS n FROM space_memberships WHERE space_id = ${space.body.space.id} AND user_id = 'race-guest-2'`;
    // A member exactly when the invitation ended accepted.
    expect(m.n).toBe(inv.status === "accepted" ? 1 : 0);
  });

  test("parallel person invitations to one person", async () => {
    const a = await mint("race-person-a");
    const b = await mint("race-person-b");
    await call(b, "GET", "/api/spaces");
    const results = await Promise.all(Array.from({ length: 6 }, () => call(a, "POST", "/api/people/invitations", { email: "race-person-b@example.com" })));
    expect(unexpected(results, [200, 201, 409])).toEqual([]);
    const [row] = await sql`SELECT count(*)::int AS n FROM person_invitations WHERE inviter_user_id = 'race-person-a' AND status = 'pending'`;
    expect(row.n).toBe(1);
  });

  test("editing and deleting one message at the same moment", async () => {
    const token = await mint("race-msg");
    const { threadId } = await spaceWithThread(token, "Edit race");
    const sent = await call(token, "POST", `/api/threads/${threadId}/discussion-messages`, { body: "v0" });
    const id = sent.body.message?.id ?? sent.body.id;
    const results = await Promise.all([
      ...Array.from({ length: 4 }, (_, i) => call(token, "PATCH", `/api/discussion-messages/${id}`, { body: `v${i + 1}` })),
      call(token, "DELETE", `/api/discussion-messages/${id}`),
    ]);
    expect(unexpected(results, [200, 204, 404, 409])).toEqual([]);
  });

  test("changing and removing one member at the same moment", async () => {
    const owner = await mint("race-owner-3");
    const guest = await mint("race-guest-3");
    await call(guest, "GET", "/api/spaces");
    const space = await call(owner, "POST", "/api/spaces", { name: "Member race" });
    const spaceId = space.body.space.id;
    const invite = await call(owner, "POST", `/api/spaces/${spaceId}/invitations`, { email: "race-guest-3@test", role: "collaborator" });
    expect((await call(guest, "POST", `/api/space-invitations/${invite.body.invitation.id}/accept`, {})).status).toBeLessThan(300);
    const results = await Promise.all([
      call(owner, "PATCH", `/api/spaces/${spaceId}/members/race-guest-3/role`, { role: "viewer" }),
      call(owner, "POST", `/api/spaces/${spaceId}/members/race-guest-3/remove`, {}),
      call(owner, "PATCH", `/api/spaces/${spaceId}/members/race-guest-3/role`, { role: "collaborator" }),
    ]);
    expect(unexpected(results, [200, 204, 404, 409])).toEqual([]);
    expect(await brokenInvariants(sql)).toEqual([]);
  });

  test("deleting one Space twice at once, while people post in it", async () => {
    const token = await mint("race-delete");
    const { spaceId, threadId } = await spaceWithThread(token, "Delete race");
    const results = await Promise.all([
      call(token, "DELETE", `/api/spaces/${spaceId}`),
      call(token, "DELETE", `/api/spaces/${spaceId}`),
      ...Array.from({ length: 5 }, (_, i) => call(token, "POST", `/api/threads/${threadId}/discussion-messages`, { body: `m${i}` })),
      call(token, "POST", `/api/spaces/${spaceId}/threads`, { name: "late" }),
    ]);
    expect(unexpected(results, [200, 201, 204, 403, 404, 409])).toEqual([]);
    const [row] = await sql`SELECT count(*)::int AS n FROM spaces WHERE id = ${spaceId}`;
    expect(row.n).toBe(0);
    expect(await brokenInvariants(sql)).toEqual([]);
  });

  test("deleting a Thread while people post and clear it", async () => {
    const token = await mint("race-thread");
    const { threadId } = await spaceWithThread(token, "Thread race");
    const results = await Promise.all([
      ...Array.from({ length: 4 }, (_, i) => call(token, "POST", `/api/threads/${threadId}/discussion-messages`, { body: `m${i}` })),
      call(token, "POST", `/api/threads/${threadId}/chat/clear`, {}),
      call(token, "POST", `/api/threads/${threadId}/chat/clear`, {}),
      call(token, "DELETE", `/api/threads/${threadId}`),
      call(token, "PATCH", `/api/threads/${threadId}`, { name: "renamed" }),
    ]);
    expect(unexpected(results, [200, 201, 204, 403, 404, 409])).toEqual([]);
    expect(await brokenInvariants(sql)).toEqual([]);
  });

  test("renaming and archiving one Space at once", async () => {
    const token = await mint("race-rename");
    const { spaceId } = await spaceWithThread(token, "Rename race");
    const results = await Promise.all([
      ...Array.from({ length: 4 }, (_, i) => call(token, "PATCH", `/api/spaces/${spaceId}`, { name: `Renamed ${i}` })),
      call(token, "PATCH", `/api/spaces/${spaceId}`, { archived: true }),
      call(token, "PATCH", `/api/spaces/${spaceId}`, { description: "d" }),
    ]);
    expect(unexpected(results, [200, 409])).toEqual([]);
  });
});
