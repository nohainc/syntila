import { describe, expect, it, vi } from "vitest";

vi.mock("../src/routes/handlers.js", async (original) => ({
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
vi.mock("../src/event-publisher.js", () => ({
  // Applies the domain writes the route commits together with its signal.
  createEventPublisher: () => ({
    publish: async (input?: { mutations?: { run(): Promise<unknown> }[] }) => {
      for (const statement of input?.mutations ?? []) await statement.run();
    },
  }),
}));
import { handleCreateWorkRequest } from "../src/routes/work-creation.js";

function fixture(coordinatorAvailable = true) {
  const writes: { sql: string; values: unknown[] }[] = [];
  const enqueue = vi.fn(async () => new Response("{}"));
  const create = vi.fn(async () => ({ status: async () => "queued" }));
  const env = {
    SYNTILA_DB: {
      prepare(sql: string) {
        const statement = {
          values: [] as unknown[],
          bind(...values: unknown[]) {
            this.values = values;
            return this;
          },
          async first() {
            if (sql.includes("space_workflow_settings"))
              return { workspaceId: "workspace" };
            if (
              sql.includes("owner_user_id AS ownerUserId") &&
              sql.includes("FROM spaces")
            )
              return { ownerUserId: "owner", kind: "group" };
            if (sql.includes("space_memberships"))
              return { role: "owner", settingsJson: "{}" };
            if (sql.includes("thread_execution_policies"))
              return {
                mode: "stateful",
                primaryWorkspaceId: "different-workspace",
              };
            return null;
          },
          async all() {
            if (sql.includes("UNION ALL")) {
              const target =
                typeof this.values[1] === "string" ? this.values[1] : null;
              const rows = [
                {
                  workflow_id: "chat",
                  configuration_json: JSON.stringify({
                    schemaVersion: 1,
                    workflowId: "chat",
                    enabled: true,
                    defaults: { worker: "worker-a" },
                    stepOverrides: {},
                  }),
                },
                {
                  workflow_id: "direct",
                  configuration_json: JSON.stringify({
                    schemaVersion: 1,
                    workflowId: "direct",
                    enabled: true,
                    defaults: { worker: "worker-a" },
                    stepOverrides: {},
                  }),
                },
              ];
              return {
                results: target
                  ? rows.filter((r) => r.workflow_id === target)
                  : rows,
              };
            }
            return {
              results: [{ workerId: "worker-a", workspaceId: "workspace" }],
            };
          },
          async run() {
            writes.push({ sql, values: this.values });
            return {};
          },
        };
        return statement;
      },
      async batch(statements: { run(): Promise<unknown> }[]) {
        return Promise.all(statements.map((s) => s.run()));
      },
    },
    SYNTILA_RUN_WORKFLOW: { create },
    ...(coordinatorAvailable
      ? {
          SYNTILA_THREAD_COORDINATOR: {
            getByName: () => ({ fetch: enqueue }),
          },
        }
      : {}),
  };
  return { env, enqueue, create, writes };
}

describe("Work Request mutation coordination", () => {
  it.each([true, false])(
    "creates Chat without a mutation lease (coordinator available: %s)",
    async (available) => {
      const { env, enqueue, create, writes } = fixture(available);
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
      expect(
        writes.find((w) => w.sql.includes("INSERT INTO work_requests"))
          ?.values[3],
      ).toBe("stateless");
      expect(writes.some((w) => w.sql.includes("thread_runtime_leases"))).toBe(
        false,
      );
    },
  );

  it("keeps Work stateful and enqueues it for coordination", async () => {
    const { env, enqueue } = fixture();
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
  });

  it("rejects a caller attempting to make Chat stateful", async () => {
    const { env, enqueue, create } = fixture();
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
  });
});
