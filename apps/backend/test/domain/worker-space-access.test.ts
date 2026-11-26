import { afterAll, beforeAll, describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { member, space, user } from "./helpers/seed";
import {
  handleCreateWorker,
  handleRemoveSpaceMember,
  handleWorker,
  handleWorkerSpaceAccess,
  handleWorkerMemberModelAccess,
  type SecurityEnv,
} from "../../src/domain/routes/handlers.js";

const savedFlags = process.env.SYNTILA_FEATURE_FLAGS;
beforeAll(() => {
  process.env.SYNTILA_FEATURE_FLAGS = "worker_identity";
});
afterAll(() => {
  if (savedFlags === undefined) delete process.env.SYNTILA_FEATURE_FLAGS;
  else process.env.SYNTILA_FEATURE_FLAGS = savedFlags;
});

async function status(call: Promise<Response>): Promise<number> {
  try {
    return (await call).status;
  } catch (error: any) {
    return error.status ?? 500;
  }
}

async function fixture() {
  const { sqlite, db } = await pgD1();
  await sqlite.exec(
    [
      user("alice"),
      user("bob"),
      user("carol"),
      user("stranger"),
      space("spc-1", "alice", "Team Space"),
      member("spc-1", "alice", "owner"),
      member("spc-1", "bob", "collaborator"),
      member("spc-1", "carol", "viewer"),
      "INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at) VALUES ('alice','paid','active','manual',now(),now());",
    ].join("\n"),
  );

  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    TEST_AUTHENTICATION: async (request: Request) => {
      const userId = request.headers.get("test-user")!;
      return {
        userId,
        user: { id: userId, email: `${userId}@test`, displayName: userId, status: "active" },
        spaceRoles: {},
        sessionId: "test",
        clientType: "web",
      };
    },
  } as unknown as SecurityEnv;

  const createRes = await handleCreateWorker(
    new Request("https://test/api/workers", {
      method: "POST",
      headers: { "test-user": "alice" },
      body: JSON.stringify({ workerTypeId: "chatgpt", name: "Shared Worker" }),
    }),
    env,
  );
  expect(createRes.status).toBe(201);
  const { worker } = (await createRes.json()) as { worker: { id: string } };

  const getAccess = (who: string, workerId: string, spaceId = "spc-1") =>
    handleWorkerSpaceAccess(
      new Request(`https://test/api/workers/${workerId}/space-access?spaceId=${encodeURIComponent(spaceId)}`, {
        method: "GET",
        headers: { "test-user": who },
      }),
      env,
      workerId,
    );

  const putAccess = (who: string, workerId: string, body: unknown) =>
    handleWorkerSpaceAccess(
      new Request(`https://test/api/workers/${workerId}/space-access`, {
        method: "PUT",
        headers: { "test-user": who },
        body: JSON.stringify(body),
      }),
      env,
      workerId,
    );

  const rows = (sql: string, ...params: unknown[]) => sqlite.prepare(sql).all(...params);

  return { sqlite, env, workerId: worker.id, getAccess, putAccess, rows };
}

describe("GET / PUT /api/workers/:workerId/space-access", () => {
  it("allows the Worker owner to read and update Space member access", async () => {
    const f = await fixture();

    const initialRes = await f.getAccess("alice", f.workerId);
    expect(initialRes.status).toBe(200);
    const initial = (await initialRes.json()) as {
      workerId: string;
      spaceId: string;
      members: Array<{ userId: string; enabled: boolean; permissions: { mode: string } }>;
    };
    expect(initial.workerId).toBe(f.workerId);
    expect(initial.spaceId).toBe("spc-1");
    expect(initial.members.map((m) => [m.userId, m.enabled, m.permissions.mode])).toEqual([
      ["alice", false, "chat"],
      ["bob", false, "chat"],
      ["carol", false, "chat"],
    ]);

    const putRes = await f.putAccess("alice", f.workerId, {
      spaceId: "spc-1",
      members: [
        { userId: "bob", enabled: true, permissions: { mode: "work" } },
        { userId: "carol", enabled: false, permissions: { mode: "chat" } },
      ],
    });
    expect(putRes.status).toBe(200);
    const updated = (await putRes.json()) as typeof initial;
    expect(updated.members.map((m) => [m.userId, m.enabled, m.permissions.mode])).toEqual([
      ["alice", false, "chat"],
      ["bob", true, "work"],
      ["carol", false, "chat"],
    ]);

    const reloaded = (await (await f.getAccess("alice", f.workerId)).json()) as typeof initial;
    expect(reloaded.members).toEqual(updated.members);
  });

  it("makes sharing a Plus feature: Free cannot enable access but can turn it off", async () => {
    const f = await fixture();
    const enable = { spaceId: "spc-1", members: [{ userId: "bob", enabled: true, permissions: { mode: "chat" } }] };
    const disable = { spaceId: "spc-1", members: [{ userId: "bob", enabled: false, permissions: { mode: "chat" } }] };
    expect((await f.putAccess("alice", f.workerId, enable)).status).toBe(200);
    // The plan lapses: new sharing is refused, revoking still works.
    await f.sqlite.exec("UPDATE account_plans SET tier = 'free' WHERE user_id = 'alice'");
    expect(await status(f.putAccess("alice", f.workerId, enable))).toBe(402);
    expect((await f.putAccess("alice", f.workerId, disable)).status).toBe(200);
  });

  it("stores one allow-list of models per Worker, clears it, and rejects bad input", async () => {
    const f = await fixture();
    const call = (who: string, method: string, body?: unknown) =>
      handleWorkerMemberModelAccess(
        new Request(`https://test/api/workers/${f.workerId}/member-model-access`, {
          method,
          headers: { "test-user": who },
          body: body === undefined ? undefined : JSON.stringify(body),
        }),
        f.env,
        f.workerId,
      );
    const limits = { allowedModels: ["m2"], allowedEfforts: { m1: ["high"] } };
    const put = await call("alice", "PUT", { modelAccess: limits });
    expect(put.status).toBe(200);
    expect(((await put.json()) as { modelAccess: unknown }).modelAccess).toEqual(limits);
    expect(((await (await call("alice", "GET")).json()) as { modelAccess: unknown }).modelAccess).toEqual(limits);

    await call("alice", "PUT", { modelAccess: { allowedModels: [], allowedEfforts: {} } });
    expect((await f.rows("SELECT 1 FROM worker_member_model_access")).length).toBe(0);

    expect(await status(call("alice", "PUT", { modelAccess: { bogus: 1 } }))).toBe(400);
    expect(await status(call("bob", "PUT", { modelAccess: limits }))).toBe(403);
    expect(await status(call("bob", "GET"))).toBe(403);
  });

  it("returns 403 for a non-owner and 404 for an unknown Worker", async () => {
    const f = await fixture();
    expect(await status(f.getAccess("bob", f.workerId))).toBe(403);
    expect(
      await status(
        f.putAccess("bob", f.workerId, {
          spaceId: "spc-1",
          members: [{ userId: "bob", enabled: true, permissions: { mode: "chat" } }],
        }),
      ),
    ).toBe(403);
    expect(await status(f.getAccess("alice", "wrk-missing"))).toBe(404);
  });

  it("rejects non-member userIds and callers without Space manage rights", async () => {
    const f = await fixture();

    // Stranger is not a member of spc-1
    expect(
      await status(
        f.putAccess("alice", f.workerId, {
          spaceId: "spc-1",
          members: [{ userId: "stranger", enabled: true, permissions: { mode: "work" } }],
        }),
      ),
    ).toBe(422);

    // Carol is a viewer in spc-1, even if she owns her own Worker
    const carolWorkerRes = await handleCreateWorker(
      new Request("https://test/api/workers", {
        method: "POST",
        headers: { "test-user": "carol" },
        body: JSON.stringify({ workerTypeId: "chatgpt", name: "Carol Worker" }),
      }),
      f.env,
    );
    const { worker: carolWorker } = (await carolWorkerRes.json()) as { worker: { id: string } };
    expect(await status(f.getAccess("carol", carolWorker.id))).toBe(403);
    expect(
      await status(
        f.putAccess("carol", carolWorker.id, {
          spaceId: "spc-1",
          members: [{ userId: "bob", enabled: true, permissions: { mode: "chat" } }],
        }),
      ),
    ).toBe(403);
  });

  it("revokes Space member access when the Worker is revoked or a member leaves the Space", async () => {
    const f = await fixture();
    await f.putAccess("alice", f.workerId, {
      spaceId: "spc-1",
      members: [
        { userId: "bob", enabled: true, permissions: { mode: "work+shell" } },
        { userId: "carol", enabled: true, permissions: { mode: "chat" } },
      ],
    });
    expect((await f.rows("SELECT user_id FROM worker_space_members WHERE worker_id = ?", f.workerId)).length).toBe(2);

    // Removing bob from the Space removes bob's Worker access row
    const removeRes = await handleRemoveSpaceMember(
      new Request("https://test/api/spaces/spc-1/members/bob", {
        method: "DELETE",
        headers: { "test-user": "alice" },
      }),
      f.env,
      "spc-1",
      "bob",
    );
    expect(removeRes.status).toBe(200);
    expect(await f.rows("SELECT user_id FROM worker_space_members WHERE worker_id = ?", f.workerId)).toEqual([
      { user_id: "carol" },
    ]);

    // Revoking the Worker removes remaining Space member access rows and blocks further edits
    const revokeRes = await handleWorker(
      new Request(`https://test/api/workers/${f.workerId}`, {
        method: "DELETE",
        headers: { "test-user": "alice" },
      }),
      f.env,
      f.workerId,
    );
    expect(revokeRes.status).toBe(200);
    expect(await f.rows("SELECT user_id FROM worker_space_members WHERE worker_id = ?", f.workerId)).toEqual([]);
    expect(await status(f.getAccess("alice", f.workerId))).toBe(409);
  });
});
