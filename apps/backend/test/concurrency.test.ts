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

describe("races on Workspaces, grants and the request queue", () => {
  const registration = (installationId: string, name: string) => ({
    contractVersion: "1.0", installationId, proposedWorkspaceName: name,
    hostname: name.toLowerCase().replace(/[^a-z0-9]+/g, "-"), platform: "macos", architecture: "arm64", appVersion: "1.0.0",
    runtimeCapabilities: { os: "macos", arch: "arm64", appVersion: "1.0.0", supportedRuntimes: ["cli"], maxConcurrentWorkers: 2 },
  });
  const machine = async (token: string, path: string, body: unknown) => {
    const r = await fetch(`${base}${path}`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const text = await r.text();
    return { status: r.status, body: text ? JSON.parse(text) : null };
  };

  test("one installation registering from several app starts at once", async () => {
    const desktop = await mint("race-ws-1", { client: "desktop", client_aud: "syntila.desktop.management" });
    const installationId = `install_${crypto.randomUUID()}`;
    const results = await Promise.all(Array.from({ length: 5 }, () =>
      machine(desktop, "/api/workspace-runtime/register", registration(installationId, "Mac"))));
    expect(unexpected(results, [200, 201, 409])).toEqual([]);
    const [row] = await sql`SELECT count(*)::int AS n FROM execution_workspaces WHERE owner_user_id = 'race-ws-1' AND status <> 'revoked'`;
    expect(row.n).toBe(1);
    const [inst] = await sql`SELECT count(*)::int AS n FROM workspace_installations WHERE installation_id = ${installationId}`;
    expect(inst.n).toBe(1);
  });

  test("releasing and registering one installation at the same moment", async () => {
    const desktop = await mint("race-ws-2", { client: "desktop", client_aud: "syntila.desktop.management" });
    const installationId = `install_${crypto.randomUUID()}`;
    const first = await machine(desktop, "/api/workspace-runtime/register", registration(installationId, "Mac"));
    expect(first.status).toBeLessThan(300);
    const release = { installationId, workspaceId: first.body.workspaceId ?? first.body.executionWorkspaceId, runtimeId: first.body.workspaceRuntimeId };
    const results = await Promise.all([
      machine(desktop, "/api/workspace-runtime/release", release),
      machine(desktop, "/api/workspace-runtime/register", registration(installationId, "Mac")),
      machine(desktop, "/api/workspace-runtime/release", release),
    ]);
    expect(unexpected(results, [200, 201, 402, 404, 409])).toEqual([]);
    // At most one live registration of the installation, whatever the order.
    const [inst] = await sql`SELECT count(*)::int AS n FROM workspace_installations WHERE installation_id = ${installationId} AND status = 'active'`;
    expect(inst.n).toBeLessThanOrEqual(1);
    expect(await brokenInvariants(sql)).toEqual([]);
  });

  test("selecting the same Workspace for one Space from several tabs", async () => {
    const owner = await mint("race-grant");
    const desktop = await mint("race-grant", { client: "desktop", client_aud: "syntila.desktop.management" });
    const ws = await machine(desktop, "/api/workspace-runtime/register", registration(`install_${crypto.randomUUID()}`, "Mac"));
    expect(ws.status).toBeLessThan(300);
    const workspaceId = ws.body.workspaceId ?? ws.body.executionWorkspaceId;
    const space = await call(owner, "POST", "/api/spaces", { name: "Grant race" });
    const spaceId = space.body.space.id;
    const results = await Promise.all(Array.from({ length: 6 }, () =>
      call(owner, "PUT", `/api/spaces/${spaceId}/workflow-workspace`, { workspaceId, confirmReset: true })));
    expect(unexpected(results, [200, 409])).toEqual([]);
    const [row] = await sql`SELECT count(*)::int AS n FROM workspace_space_grants WHERE space_id = ${spaceId} AND status IN ('active', 'suspended')`;
    expect(row.n).toBe(1);
    expect(await brokenInvariants(sql)).toEqual([]);
  });

  test("queueing, sending now, pausing and resuming one Thread queue at once", async () => {
    const token = await mint("race-queue");
    const { threadId } = await spaceWithThread(token, "Queue race");
    const enqueue = (i: number) => call(token, "POST", `/api/threads/${threadId}/queue`, { request: { workflowId: "chat", input: { originalRequest: `q${i}` } } });
    const queued = await enqueue(0);
    expect(unexpected([queued], [200, 201])).toEqual([]);
    const firstId = queued.body.items?.[0]?.id;
    const results = await Promise.all([
      ...Array.from({ length: 6 }, (_, i) => enqueue(i + 1)),
      call(token, "POST", `/api/threads/${threadId}/queue/pause`, {}),
      call(token, "POST", `/api/threads/${threadId}/queue/resume`, {}),
      ...(firstId ? [call(token, "POST", `/api/threads/${threadId}/queue/${firstId}/send-now`, {})] : []),
    ]);
    expect(unexpected(results, [200, 201, 400, 404, 409, 422])).toEqual([]);
    expect(await brokenInvariants(sql)).toEqual([]);
  });
});

describe("Thread names", () => {
  const names = async (spaceId: string) =>
    (await sql.unsafe("SELECT name FROM threads WHERE space_id = $1", [spaceId])).map((r: any) => String(r.name).trim().toLowerCase());

  test("parallel creates of one name: exactly one wins, the rest are 409, no 5xx", async () => {
    const token = await mint("thread-name-a");
    const space = await call(token, "POST", "/api/spaces", { name: "Names" });
    const spaceId = space.body.space.id as string;
    const results = await Promise.all(Array.from({ length: 12 }, (_, i) =>
      call(token, "POST", `/api/spaces/${spaceId}/threads`, { name: i % 2 ? " Plan " : "plan" })));
    const statuses = results.map((r) => r.status).sort();
    expect(statuses.filter((s) => s >= 500)).toEqual([]);
    expect(statuses.filter((s) => s === 201)).toHaveLength(1);
    expect(statuses.filter((s) => s === 409)).toHaveLength(11);
    // The loser is told what to change, not just to reload.
    expect(results.find((r) => r.status === 409)!.body.error).toBe("This Space already has a Thread with this name");
    expect((await names(spaceId)).filter((n) => n === "plan")).toHaveLength(1);
    expect(await brokenInvariants(sql)).toEqual([]);
  });

  test("a create racing a rename to the same name: at most one Thread ends up with it", async () => {
    const token = await mint("thread-name-b");
    const space = await call(token, "POST", "/api/spaces", { name: "Rename race" });
    const spaceId = space.body.space.id as string;
    const ids: string[] = [];
    for (const n of ["a", "b", "c", "d"]) {
      const t = await call(token, "POST", `/api/spaces/${spaceId}/threads`, { name: n });
      ids.push(t.body.thread.id);
    }
    const results = await Promise.all([
      call(token, "POST", `/api/spaces/${spaceId}/threads`, { name: "Target" }),
      ...ids.map((id) => call(token, "PATCH", `/api/threads/${id}`, { name: "target" })),
    ]);
    expect(results.filter((r) => r.status >= 500).map((r) => r.status)).toEqual([]);
    expect((await names(spaceId)).filter((n) => n === "target")).toHaveLength(1);
  });
});

describe("Space names", () => {
  const owned = async (owner: string) =>
    (await sql.unsafe("SELECT lower(btrim(name)) AS name FROM spaces WHERE owner_user_id = $1 AND kind = 'group'", [owner])).map((r: any) => r.name as string);

  test("a create racing renames to the same name: at most one Space ends up with it, no 5xx", async () => {
    const token = await mint("space-name-a");
    const me = (await call(token, "GET", "/api/session")).body.user.id as string;
    const ids: string[] = [];
    for (const n of ["one", "two", "three", "four"]) ids.push((await call(token, "POST", "/api/spaces", { name: n })).body.space.id);
    const results = await Promise.all([
      call(token, "POST", "/api/spaces", { name: "Target" }),
      ...ids.map((id) => call(token, "PATCH", `/api/spaces/${id}`, { name: " target " })),
    ]);
    expect(results.filter((r) => r.status >= 500).map((r) => r.status)).toEqual([]);
    expect((await owned(me)).filter((n) => n === "target")).toHaveLength(1);
    const loser = results.find((r) => r.status === 409);
    expect(loser?.body.error).toBe("You already have a Space with this name");
  });

  test("different owners may use the same name", async () => {
    const [a, b] = await Promise.all([mint("space-name-b1"), mint("space-name-b2")]);
    const results = await Promise.all([a, b].map((t) => call(t, "POST", "/api/spaces", { name: "Shared name" })));
    expect(results.map((r) => r.status)).toEqual([201, 201]);
  });
});
