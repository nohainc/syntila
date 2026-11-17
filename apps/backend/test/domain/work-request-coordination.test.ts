import { pgD1 } from "./helpers/pg-d1";
import { member, space, thread, user, workspace } from "./helpers/seed";
import { describe, expect, it, vi } from "./helpers/vitest-compat";

vi.mock("../../src/domain/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: async () => ({
    context: { userId: "owner" },
    spaceId: "space",
  }),
  validateWorkflowWorkerEligibility: async () => ({
    issues: [],
    primaryWorkspaceId: "workspace",
    workerProfiles: {
      direct: { profileId: "chatgpt-codex", profileReleaseVersion: 1 },
      chat: { profileId: "chatgpt-codex", profileReleaseVersion: 1 },
    },
  }),
  resolveWorkflowInstanceId: async (_env: unknown, id: string) => id,
}));
vi.mock("../../src/domain/event-publisher.js", () => ({
  // Applies the domain writes the route commits together with its signal.
  createEventPublisher: (env: unknown) => ({
    publish: async (input?: { mutate?: (tx: never) => Promise<unknown> }) => {
      if (!input?.mutate) return;
      const { dataOf } = await import("../../src/platform/data.js");
      await dataOf(env as never).tx("test.publish", (tx) => input.mutate!(tx as never));
    },
  }),
}));
import { handleCreateWorkRequest } from "../../src/domain/routes/work-creation.js";

const NOW = "2026-01-01T00:00:00.000Z";
const configuration = (workflowId: string) =>
  JSON.stringify({
    schemaVersion: 1,
    workflowId,
    enabled: true,
    defaults: { worker: "worker-a" },
    stepOverrides: {},
  });

async function fixture(coordinatorAvailable = true) {
  const { db, sqlite } = await pgD1();
  await sqlite.exec(
    user("owner") +
      space("space", "owner") +
      member("space", "owner") +
      workspace("workspace", "owner") +
      thread("stream", "space", "owner") +
      `INSERT INTO workspace_worker_inventory (
         worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
         local_concurrency_limit, revision, created_at, updated_at, last_seen_at
       ) VALUES ('worker-a', 'workspace', 'owner', 'chatgpt-codex', 'enabled', 'ready', 1, 1, '${NOW}', '${NOW}', '${NOW}');
       INSERT INTO space_workflow_settings(space_id, workspace_id, updated_at) VALUES ('space', 'workspace', '${NOW}');
       INSERT INTO space_workflow_configurations(space_id, workflow_id, schema_version, configuration_json, updated_at) VALUES
         ('space', 'chat', 1, '${configuration("chat")}', '${NOW}'),
         ('space', 'direct', 1, '${configuration("direct")}', '${NOW}');`,
  );
  const enqueue = vi.fn(async () => new Response("{}"));
  const create = vi.fn(async () => ({ status: async () => "queued" }));
  const env = {
    SYNTILA_DB: db,
    SYNTILA_RUN_WORKFLOW: { create },
    ...(coordinatorAvailable
      ? { SYNTILA_THREAD_COORDINATOR: { getByName: () => ({ fetch: enqueue }) } }
      : {}),
  };
  const requests = async () =>
    (await sqlite.prepare("SELECT mode FROM work_requests").all()) as { mode: string }[];
  const leases = async () =>
    Number((await sqlite.prepare("SELECT count(*) AS n FROM thread_runtime_leases").get() as { n: number | string }).n);
  return { env, enqueue, create, requests, leases };
}

describe("Work Request mutation coordination", () => {
  it.each([true, false])(
    "creates Chat without a mutation lease (coordinator available: %s)",
    async (available) => {
      const { env, enqueue, create, requests, leases } = await fixture(available);
      const response = await handleCreateWorkRequest(
        new Request("https://syntila.test/work", {
          method: "POST",
          body: JSON.stringify({
            workflowId: "chat",
            input: { originalRequest: "Explain this code" },
          }),
        }),
        env as never,
        "stream",
      );
      expect(response.status).toBe(202);
      const body = (await response.json()) as {
        workRequest: { mode: string; workflowId: string };
      };
      expect(body.workRequest).toMatchObject({
        mode: "stateless",
        workflowId: "chat",
      });
      expect(enqueue).not.toHaveBeenCalled();
      expect(create).toHaveBeenCalledOnce();
      expect((await requests()).map((r) => r.mode)).toEqual(["stateless"]);
      expect(await leases()).toBe(0);
    },
  );

  it("keeps Work stateful and enqueues it for coordination", async () => {
    const { env, enqueue, requests } = await fixture();
    const response = await handleCreateWorkRequest(
      new Request("https://syntila.test/work", {
        method: "POST",
        body: JSON.stringify({
          workflowId: "direct",
          input: { originalRequest: "Implement this" },
        }),
      }),
      env as never,
      "stream",
    );
    expect(response.status).toBe(202);
    expect(
      ((await response.json()) as { workRequest: { mode: string } }).workRequest
        .mode,
    ).toBe("stateful");
    expect(enqueue).toHaveBeenCalledOnce();
    expect((await requests()).map((r) => r.mode)).toEqual(["stateful"]);
  });

  it("rejects a caller attempting to make Chat stateful", async () => {
    const { env, enqueue, create, requests } = await fixture();
    await expect(
      handleCreateWorkRequest(
        new Request("https://syntila.test/work", {
          method: "POST",
          body: JSON.stringify({ workflowId: "chat", mode: "stateful" }),
        }),
        env as never,
        "stream",
      ),
    ).rejects.toThrow("requires stateless mode");
    expect(enqueue).not.toHaveBeenCalled();
    expect(create).not.toHaveBeenCalled();
    expect(await requests()).toEqual([]);
  });
});
