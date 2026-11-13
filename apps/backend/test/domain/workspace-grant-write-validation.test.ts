vi.mock("../../src/domain/collaboration-events.js", () => ({
  publishCollaborationEvent: vi.fn(async () => {}),
}));
import { describe, expect, it, vi } from "./helpers/vitest-compat";
import { createWorkspaceSpaceGrant } from "../../src/domain/routes/workspace-access.js";

function environment(
  inventoryWorkerIds: readonly string[] = [],
  membershipError?: Error,
) {
  const writes: string[] = [];
  const db = {
    prepare(query: string) {
      let values: unknown[] = [];
      return {
        bind(...bound: unknown[]) {
          values = bound;
          return this;
        },
        async first() {
          if (query.includes("FROM spaces")) return { id: "space-1" };
          if (query.includes("FROM execution_workspaces")) {
            return {
              id: "workspace-1",
              owner_user_id: "owner-1",
              status: "online",
            };
          }
          if (query.includes("FROM space_memberships")) {
            if (membershipError) throw membershipError;
            return null;
          }
          if (query.includes("FROM workspace_space_grants")) return null;
          return null;
        },
        async all() {
          if (!query.includes("FROM workspace_worker_inventory")) {
            return { results: [] };
          }
          const requestedIds = values.slice(1);
          return {
            results: inventoryWorkerIds
              .filter((workerId) => requestedIds.includes(workerId))
              .map((worker_id) => ({ worker_id })),
          };
        },
        async run() {
          writes.push(query);
          return { success: true };
        },
      };
    },
  };
  return { env: { SYNTILA_DB: db } as never, writes };
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
  const { env, writes } = environment(workerIds, membershipError);
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
  return writes;
}

describe("Workspace Grant write validation", () => {
  it.each([
    ["permissions", { allowedPermissions: ["workspace:read"] }],
    ["network policy", { networkPolicy: { mode: "allow_all" } }],
    ["concurrency", { concurrency: { maxConcurrentAssignments: 0 } }],
    ["unknown fields", { legacyScope: "all" }],
  ])("rejects invalid %s before storing a Grant", async (_field, body) => {
    const { env, writes } = environment();
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
    expect(writes).toEqual([]);
  });

  it("requires every explicit Worker ID to belong to the granted Workspace", async () => {
    await expect(
      createGrant({ allowedWorkerIds: ["worker-foreign"] }),
    ).rejects.toMatchObject({ status: 400 });
  });

  it("propagates membership database failures instead of treating them as no membership", async () => {
    const databaseError = new Error("membership database unavailable");
    await expect(createGrant({}, [], databaseError)).rejects.toBe(
      databaseError,
    );
  });

  it("stores a valid explicit Worker, permission, network, and concurrency policy", async () => {
    const writes = await createGrant(
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
    expect(
      writes.some((query) =>
        query.includes("INSERT INTO workspace_space_grants"),
      ),
    ).toBe(true);
  });
});
