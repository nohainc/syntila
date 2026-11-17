vi.mock("../../src/domain/collaboration-events.js", () => ({
  publishCollaborationEvent: vi.fn(async () => {}),
}));
import { describe, expect, it, vi } from "./helpers/vitest-compat";
import { createWorkspaceSpaceGrant } from "../../src/domain/routes/workspace-access.js";
import { pgD1 } from "./helpers/pg-d1";
import { space, T0, user, workspace } from "./helpers/seed";

async function environment(
  inventoryWorkerIds: readonly string[] = [],
  membershipError?: Error,
) {
  const { db, sqlite } = await pgD1();
  await sqlite.exec(
    user("owner-1") +
      space("space-1", "owner-1") +
      workspace("workspace-1", "owner-1") +
      "UPDATE execution_workspaces SET status = 'online' WHERE id = 'workspace-1';" +
      inventoryWorkerIds
        .map(
          (id) => `INSERT INTO workspace_worker_inventory (
             worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
             local_concurrency_limit, revision, created_at, updated_at, last_seen_at
           ) VALUES ('${id}', 'workspace-1', 'owner-1', 'chatgpt-codex', 'enabled', 'ready', 1, 1, '${T0}', '${T0}', '${T0}');`,
        )
        .join(""),
  );
  // A failing membership lookup is a failing database, not "no membership".
  const database = membershipError
    ? new Proxy(db as object, {
        get(target, prop, receiver) {
          const value = Reflect.get(target, prop, receiver);
          if (prop !== "sql") return value;
          return new Proxy(value, {
            apply(fn, thisArg, args) {
              if (Array.isArray(args[0]) && args[0].join("?").includes("FROM space_memberships"))
                throw membershipError;
              return Reflect.apply(fn, thisArg, args);
            },
          });
        },
      })
    : db;
  const grants = async () =>
    Number(
      (await sqlite.prepare("SELECT count(*) AS n FROM workspace_space_grants").get() as { n: number | string }).n,
    );
  return { env: { SYNTILA_DB: database } as never, grants };
}

const context = {
  userId: "owner-1",
  user: { id: "owner-1", status: "active" },
  spaceRoles: {},
  sessionId: "session-1",
  clientType: "web",
} as never;

async function createGrant(
  body: Record<string, unknown>,
  workerIds: string[] = [],
  membershipError?: Error,
) {
  const { env, grants } = await environment(workerIds, membershipError);
  await createWorkspaceSpaceGrant(
    new Request("https://cloud.test", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ confirmContribution: true, ...body }),
    }),
    env,
    context,
    "space-1",
    "workspace-1",
  );
  return grants();
}

describe("Workspace Grant write validation", () => {
  it.each([
    ["permissions", { allowedPermissions: ["workspace:read"] }],
    ["network policy", { networkPolicy: { mode: "allow_all" } }],
    ["concurrency", { concurrency: { maxConcurrentAssignments: 0 } }],
    ["unknown fields", { legacyScope: "all" }],
  ])("rejects invalid %s before storing a Grant", async (_field, body) => {
    const { env, grants } = await environment();
    await expect(
      createWorkspaceSpaceGrant(
        new Request("https://cloud.test", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ confirmContribution: true, ...body }),
        }),
        env,
        context,
        "space-1",
        "workspace-1",
      ),
    ).rejects.toMatchObject({ status: 400 });
    expect(await grants()).toBe(0);
  });

  it("requires every explicit Worker ID to belong to the granted Workspace", async () => {
    await expect(createGrant({ allowedWorkerIds: ["worker-foreign"] }),).rejects.toMatchObject({ status: 400 });
  });

  it("propagates membership database failures instead of treating them as no membership", async () => {
    const databaseError = new Error("membership database unavailable");
    await expect(createGrant({}, [], databaseError)).rejects.toBe(
      databaseError,
    );
  });

  it("stores a valid explicit Worker, permission, network, and concurrency policy", async () => {
    const stored = await createGrant(
      {
        allowedWorkerIds: ["worker-local"],
        allowedPermissions: ["repository:read", "network:use"],
        networkPolicy: {
          mode: "allowlist",
          allowedHosts: ["api.example.com"],
        },
        concurrency: { maxConcurrentAssignments: 3 },
      },
      ["worker-local"],
    );
    expect(stored).toBe(1);
  });
});
