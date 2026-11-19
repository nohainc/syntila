import { afterAll, beforeAll, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { user, workspace } from "./helpers/seed";
import {
  handleCreateWorker,
  handleListFeatures,
  handleListWorkers,
  handleWorker,
  type SecurityEnv,
} from "../../src/domain/routes/handlers.js";

// Worker Instances and Actors (ADR-032, P1): identity independent of Workspaces.

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
  await sqlite.exec([user("alice"), user("bob"), workspace("WS", "alice")].join("\n"));
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
  expect(a).toMatchObject({ name: "Writer", workerTypeId: "chatgpt", workerTypeName: "ChatGPT", enabled: true, online: false, ready: false, revokedAt: null });
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

it("enabled is configured; online and ready are observed from the Workspace it came from", async () => {
  const f = await fixture();
  await f.sqlite.exec(`
    INSERT INTO workspace_worker_inventory (worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
      local_concurrency_limit, revision, created_at, updated_at, last_seen_at)
    VALUES ('worker-legacy-1', 'WS', 'alice', 'chatgpt', 'enabled', 'ready', 1, 1, now(), now(), now());
    INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at)
    VALUES ('RT', 'WS', 'h', 'inst', now());
    INSERT INTO workspace_sessions (id, workspace_id, runtime_identity_id, protocol_version, client_version, connected_at, last_heartbeat_at)
    VALUES ('S1', 'WS', 'RT', '1', '1.0.0', now(), now());`);
  const [adopted] = await f.list("alice");
  expect(adopted).toMatchObject({ id: "worker-legacy-1", enabled: true, ready: true, online: true });
  // Disabling it is configuration: it stays ready and online.
  const off = ((await (await f.one("alice", adopted!.id, "PATCH", { enabled: false })).json()) as { worker: Worker }).worker;
  expect(off).toMatchObject({ enabled: false, ready: true, online: true });
  await f.sqlite.exec("UPDATE workspace_sessions SET disconnected_at = now() WHERE id = 'S1'");
  expect(((await (await f.one("alice", adopted!.id)).json()) as { worker: Worker }).worker).toMatchObject({ online: false, ready: true });
  await f.sqlite.exec("UPDATE workspace_worker_inventory SET readiness_state = 'sign_in_required' WHERE worker_id = 'worker-legacy-1'");
  expect(((await (await f.one("alice", adopted!.id)).json()) as { worker: Worker }).worker.ready).toBe(false);
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

it("adopts every inventory row: valid ids are kept, others mapped; the backfill is repeatable and referentially sound", async () => {
  const f = await fixture();
  // Rows that exist before the migration have no instance: insert them with the trigger off.
  await f.sqlite.exec("ALTER TABLE workspace_worker_inventory DISABLE TRIGGER inventory_adopt_worker");
  const insert = (id: string, type: string) => `INSERT INTO workspace_worker_inventory (worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
      local_concurrency_limit, revision, created_at, updated_at, last_seen_at) VALUES ('${id}', 'WS', 'alice', '${type}', 'enabled', 'ready', 1, 1, now(), now(), now());`;
  await f.sqlite.exec([insert("worker-valid-1", "chatgpt"), insert("w1", "gemini"), insert("worker-no-catalog", "ghost")].join("\n"));
  await f.sqlite.exec("ALTER TABLE workspace_worker_inventory ENABLE TRIGGER inventory_adopt_worker");
  expect(await f.rows("SELECT 1 FROM worker_instances")).toHaveLength(0);

  await f.sqlite.exec("SELECT adopt_inventory_worker(worker_id) FROM workspace_worker_inventory");
  await f.sqlite.exec("SELECT adopt_inventory_worker(worker_id) FROM workspace_worker_inventory"); // repeatable
  const mapping = await f.rows("SELECT legacy_worker_id AS l, worker_instance_id AS i FROM legacy_worker_mapping ORDER BY legacy_worker_id");
  expect(mapping.map((r: any) => r.l)).toEqual(["w1", "worker-valid-1"]); // the unknown Type is skipped
  expect(mapping.find((r: any) => r.l === "worker-valid-1").i).toBe("worker-valid-1");
  expect(mapping.find((r: any) => r.l === "w1").i).toMatch(/^wrk-/); // too short to be a valid id

  // Counts and integrity: every adoptable row has exactly one Instance, Actor and mapping.
  const [counts] = await f.rows(`SELECT
      (SELECT count(*) FROM workspace_worker_inventory i WHERE EXISTS (SELECT 1 FROM worker_catalog c WHERE c.worker_type_id = i.worker_type_id)) AS adoptable,
      (SELECT count(*) FROM worker_instances) AS instances,
      (SELECT count(*) FROM legacy_worker_mapping) AS mappings,
      (SELECT count(*) FROM worker_instances w LEFT JOIN actors a ON a.id = w.actor_id AND a.kind = 'worker' WHERE a.id IS NULL) AS without_actor,
      (SELECT count(*) FROM legacy_worker_mapping m LEFT JOIN worker_instances w ON w.id = m.worker_instance_id WHERE w.id IS NULL) AS dangling,
      (SELECT count(*) FROM users u LEFT JOIN actors a ON a.user_id = u.id WHERE a.id IS NULL) AS users_without_actor`);
  expect([counts.adoptable, counts.instances, counts.mappings].map(Number)).toEqual([2, 2, 2]);
  expect([counts.without_actor, counts.dangling, counts.users_without_actor].map(Number)).toEqual([0, 0, 0]);
});

it("a new inventory row gets its Worker Instance; removal tombstones it; registering again makes a new one", async () => {
  const f = await fixture();
  const add = `INSERT INTO workspace_worker_inventory (worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
      local_concurrency_limit, revision, created_at, updated_at, last_seen_at) VALUES ('worker-reg-001', 'WS', 'alice', 'chatgpt', 'disabled', 'not_probed', 1, 1, now(), now(), now())`;
  await f.sqlite.exec(add);
  const [first] = await f.list("alice");
  expect(first).toMatchObject({ id: "worker-reg-001", name: "ChatGPT", enabled: false });
  await f.sqlite.exec("DELETE FROM workspace_worker_inventory WHERE worker_id = 'worker-reg-001'");
  expect(await f.list("alice")).toEqual([]);
  const [tomb] = await f.list("alice", "?includeRevoked=true");
  expect(tomb!.revokedAt).not.toBeNull();
  await f.sqlite.exec(add);
  const live = await f.list("alice");
  expect(live).toHaveLength(1);
  expect(live[0]!.id).not.toBe("worker-reg-001");
  expect(live[0]!.id).toMatch(/^wrk-/);
  expect(await f.list("alice", "?includeRevoked=true")).toHaveLength(2);
});

it("the new references on assignments, history and configuration are nullable", async () => {
  const f = await fixture();
  const cols = await f.rows(`SELECT table_name, is_nullable FROM information_schema.columns
     WHERE column_name = 'worker_instance_id'
       AND table_name IN ('worker_assignments','worker_activity_history','thread_work_configs','user_workflow_configurations')
     ORDER BY table_name`);
  expect(cols.map((c: any) => c.table_name)).toEqual([
    "thread_work_configs", "user_workflow_configurations", "worker_activity_history", "worker_assignments",
  ]);
  expect(cols.every((c: any) => c.is_nullable === "YES")).toBe(true);
});

it("the flag gates the routes and /api/features lists what is on", async () => {
  const f = await fixture();
  const features = ((await (await handleListFeatures(f.as("alice", "GET", undefined, "/api/features"), f.env)).json()) as { flags: string[] }).flags;
  expect(features).toEqual(["worker_identity"]);
  const previous = process.env.SYNTILA_FEATURE_FLAGS;
  process.env.SYNTILA_FEATURE_FLAGS = "";
  try {
    expect(await status(handleListWorkers(f.as("alice"), f.env))).toBe(404);
    expect(((await (await handleListFeatures(f.as("alice"), f.env)).json()) as { flags: string[] }).flags).toEqual([]);
  } finally {
    process.env.SYNTILA_FEATURE_FLAGS = previous;
  }
});
