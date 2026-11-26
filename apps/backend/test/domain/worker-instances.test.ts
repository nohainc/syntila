import { afterAll, beforeAll, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { user } from "./helpers/seed";
import {
  handleCreateWorker,
  handleListWorkers,
  handleWorker,
  type SecurityEnv,
} from "../../src/domain/routes/handlers.js";

// Worker Instances and Actors (ADR-032, P1): identity independent of Workers.

const savedFlags = process.env.SYNTILA_FEATURE_FLAGS;
beforeAll(() => { process.env.SYNTILA_FEATURE_FLAGS = "worker_identity"; });
afterAll(() => {
  if (savedFlags === undefined) delete process.env.SYNTILA_FEATURE_FLAGS;
  else process.env.SYNTILA_FEATURE_FLAGS = savedFlags;
});

type Worker = {
  id: string; actorId: string; workerTypeId: string; workerTypeName: string; name: string;
  description: string; enabled: boolean; online: boolean; ready: boolean;
  defaultModel: string | null; createdAt: string; updatedAt: string; revokedAt: string | null;
};

/** Handlers signal failures by throwing HttpError; read the status either way. */
async function status(call: Promise<Response>): Promise<number> {
  try { return (await call).status; } catch (error: any) { return error.status ?? 500; }
}

async function fixture() {
  const { sqlite, db } = await pgD1();
  await sqlite.exec([user("alice"), user("bob")].join("\n"));
  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    TEST_AUTHENTICATION: async (request: Request) => {
      const userId = request.headers.get("test-user")!;
      return {
        userId,
        user: { id: userId, email: `${userId}@test`, displayName: userId, status: "active" },
        workspaceId: "", spaceRoles: {}, sessionId: "test", clientType: "web",
      };
    },
  } as unknown as SecurityEnv;
  const as = (who: string, method = "GET", body?: unknown, path = "/api/workers") =>
    new Request(`https://test${path}`, {
      method,
      headers: { "test-user": who },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
  const create = (who: string, body: unknown) => handleCreateWorker(as(who, "POST", body), env);
  const created = async (who: string, body: Record<string, unknown>) => {
    const response = await create(who, body);
    expect(response.status).toBe(201);
    return ((await response.json()) as { worker: Worker }).worker;
  };
  const list = async (who: string, query = "") =>
    ((await (await handleListWorkers(as(who, "GET", undefined, `/api/workers${query}`), env)).json()) as { workers: Worker[] }).workers;
  const one = (who: string, id: string, method = "GET", body?: unknown) => handleWorker(as(who, method, body), env, id);
  const rows = async (text: string, ...params: unknown[]) => sqlite.prepare(text).all(...params);
  return { sqlite, env, as, create, created, list, one, rows };
}

it("two Workers with the same name and Type are distinct, each with its own Actor", async () => {
  const f = await fixture();
  const a = await f.created("alice", { workerTypeId: "chatgpt", name: "Writer" });
  const b = await f.created("alice", { workerTypeId: "chatgpt", name: "Writer" });
  expect(a.id).not.toBe(b.id);
  expect(a.actorId).not.toBe(b.actorId);
  expect(a).toMatchObject({ name: "Writer", workerTypeId: "chatgpt", workerTypeName: "ChatGPT", enabled: true, online: false, ready: false, readinessKnown: false, revokedAt: null });
  expect((await f.list("alice")).map((w) => w.id).sort()).toEqual([a.id, b.id].sort());
  const actors = await f.rows("SELECT kind, user_id FROM actors WHERE id IN (?, ?)", a.actorId, b.actorId);
  expect(actors.map((r: any) => [r.kind, r.user_id])).toEqual([["worker", null], ["worker", null]]);
});

it("only the owner can see or change a Worker; a stranger gets 404", async () => {
  const f = await fixture();
  const w = await f.created("alice", { workerTypeId: "gemini", name: "Mine" });
  expect(await f.list("bob")).toEqual([]);
  for (const [method, body] of [["GET", undefined], ["PATCH", { name: "Stolen" }], ["DELETE", undefined]] as const)
    expect(await status(f.one("bob", w.id, method, body))).toBe(404);
  expect(await status(f.one("alice", "wrk-unknown"))).toBe(404);
  expect(((await (await f.one("alice", w.id)).json()) as { worker: Worker }).worker.name).toBe("Mine");
});

it("renaming keeps the id and the Actor; the Type and owner never change", async () => {
  const f = await fixture();
  const w = await f.created("alice", { workerTypeId: "chatgpt", name: "Old", description: "first" });
  const response = await f.one("alice", w.id, "PATCH", { name: "  New name ", description: "second", defaultModel: "m1" });
  expect(response.status).toBe(200);
  const renamed = ((await response.json()) as { worker: Worker }).worker;
  expect(renamed).toMatchObject({ id: w.id, actorId: w.actorId, name: "New name", description: "second", defaultModel: "m1", workerTypeId: "chatgpt" });
  // null clears the default model; leaving it out keeps it.
  const cleared = ((await (await f.one("alice", w.id, "PATCH", { defaultModel: null })).json()) as { worker: Worker }).worker;
  expect(cleared.defaultModel).toBeNull();
  await expect(f.sqlite.exec(`UPDATE worker_instances SET worker_type_id = 'gemini' WHERE id = '${w.id}'`)).rejects.toThrow();
  await expect(f.sqlite.exec(`UPDATE worker_instances SET owner_user_id = 'bob' WHERE id = '${w.id}'`)).rejects.toThrow();
});

it("validates input: online and ready cannot be set, empty or unknown changes are 400, unknown Types 422", async () => {
  const f = await fixture();
  const w = await f.created("alice", { workerTypeId: "chatgpt", name: "W" });
  expect(await status(f.one("alice", w.id, "PATCH", { online: true, ready: true }))).toBe(400);
  expect(await status(f.one("alice", w.id, "PATCH", {}))).toBe(400);
  expect(await status(f.one("alice", w.id, "PATCH", { name: "   " }))).toBe(400);
  expect(await status(f.create("alice", { workerTypeId: "chatgpt", name: "" }))).toBe(400);
  expect(await status(f.create("alice", { name: "No type" }))).toBe(400);
  expect(await status(f.create("alice", { workerTypeId: "nope", name: "X" }))).toBe(422);
  await f.sqlite.exec(`INSERT INTO worker_catalog(worker_type_id,display_name,created_at,updated_at,origin,owner_user_id) VALUES ('plugin-0123456789ab','Plug','now','now','plugin','bob')`);
  expect(await status(f.create("alice", { workerTypeId: "plugin-0123456789ab", name: "Not mine" }))).toBe(422);
  expect(await status(f.create("bob", { workerTypeId: "plugin-0123456789ab", name: "Mine" }))).toBe(201);
});

it("reports the Agent lease on the Worker dispatch path", async () => {
  const f = await fixture();
  const w = await f.created("alice", { workerTypeId: "chatgpt", name: "Agent" });
  await f.sqlite.exec(`
    INSERT INTO worker_credentials (id, worker_instance_id, public_key, key_fingerprint)
    VALUES ('C1', '${w.id}', '${"a".repeat(43)}', '${"a".repeat(64)}');
    INSERT INTO worker_agent_sessions (worker_instance_id, session_id, session_epoch, credential_id, token_digest, lease_expires_at)
    VALUES ('${w.id}', 'S1', 1, 'C1', 'digest', now() + interval '1 minute');`);
  expect((await f.list("alice"))[0]).toMatchObject({ online: true, ready: false, readinessKnown: false });
  await f.sqlite.exec("UPDATE worker_agent_sessions SET lease_expires_at = now() - interval '1 second'");
  expect(((await (await f.one("alice", w.id)).json()) as { worker: Worker }).worker.online).toBe(false);
});

it("removing a Worker is a tombstone: it keeps its row and Actor, hides from the list and cannot change", async () => {
  const f = await fixture();
  const w = await f.created("alice", { workerTypeId: "chatgpt", name: "Gone" });
  const removed = await f.one("alice", w.id, "DELETE");
  expect(removed.status).toBe(200);
  const tomb = ((await removed.json()) as { worker: Worker }).worker;
  expect(tomb).toMatchObject({ id: w.id, enabled: false, online: false, ready: false });
  expect(tomb.revokedAt).not.toBeNull();
  expect(await f.list("alice")).toEqual([]);
  expect((await f.list("alice", "?includeRevoked=true")).map((x) => x.id)).toEqual([w.id]);
  const [actor] = await f.rows("SELECT tombstoned_at FROM actors WHERE id = ?", w.actorId);
  expect(actor.tombstoned_at).not.toBeNull();
  expect(await status(f.one("alice", w.id, "PATCH", { name: "Back" }))).toBe(409);
  expect(await status(f.one("alice", w.id, "DELETE"))).toBe(200); // idempotent
  await expect(f.sqlite.exec(`UPDATE worker_instances SET revoked_at = NULL WHERE id = '${w.id}'`)).rejects.toThrow();
});

it("every user has one human Actor; deleting the account tombstones it", async () => {
  const f = await fixture();
  const humans = await f.rows("SELECT user_id FROM actors WHERE kind = 'human' ORDER BY user_id");
  expect(humans.map((r: any) => r.user_id)).toEqual(["alice", "bob"]);
  await f.sqlite.exec("DELETE FROM users WHERE id = 'bob'");
  const [bob] = await f.rows("SELECT user_id, tombstoned_at FROM actors WHERE id = 'actor-human-bob'");
  expect(bob.user_id).toBeNull();
  expect(bob.tombstoned_at).not.toBeNull();
  const system = await f.rows("SELECT id FROM actors WHERE kind = 'system'");
  expect(system.map((r: any) => r.id)).toEqual(["actor-system-platform"]);
});

it("worker_assignments requires worker_instance_id (NOT NULL)", async () => {
  const f = await fixture();
  const cols = await f.rows(`SELECT table_name, is_nullable FROM information_schema.columns
     WHERE column_name = 'worker_instance_id'
       AND table_name IN ('worker_assignments','agent_commands','thread_runtime_leases')
     ORDER BY table_name`);
  expect(cols.map((c: any) => c.table_name)).toEqual([
    "agent_commands", "thread_runtime_leases", "worker_assignments",
  ]);
  expect(cols.every((c: any) => c.is_nullable === "NO")).toBe(true);
});
