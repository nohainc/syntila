import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { user } from "./helpers/seed";
import { handleWorkflowConfigurations } from "../../src/domain/routes/workflow-configurations.js";
import { translateConfiguration } from "../../src/domain/routes/worker-workflow-configurations.js";

async function fixture() {
  const f = await pgD1();
  await f.sqlite.exec(`${user("alice")} ${user("bob")}
    INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES
      ('worker-alice','','alice','chatgpt','Writer'), ('worker-bob','','bob','chatgpt','Writer')`);
  const env = { SYNTILA_DB: f.db, SYNTILA_ENVIRONMENT: "development", TEST_AUTHENTICATION: async () => ({
    userId: "alice", user: { id: "alice", email: "alice@test", displayName: "alice", status: "active" },
    spaceRoles: {}, sessionId: "test", clientType: "web",
  }) } as never;
  return { ...f, env };
}

const configuration = (worker?: string) => ({ schemaVersion: 1, workflowId: "chat", enabled: true, defaults: worker ? { worker } : {}, stepOverrides: {} });
const call = (env: never, method: string, body?: unknown) =>
  handleWorkflowConfigurations(new Request("https://test/api/user/workflow-configurations/chat", { method, headers: { "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) }), env, "chat");

describe("Workspace-free Workflow configuration", () => {
  it("saves a Worker by ID, reads it back, and refuses another person's Worker", async () => {
    const f = await fixture();
    const prior = process.env.SYNTILA_FEATURE_FLAGS;
    process.env.SYNTILA_FEATURE_FLAGS = "worker_identity,worker_agent_connect,worker_target_dispatch";
    try {
      expect((await call(f.env, "PUT", configuration("worker-alice"))).status).toBe(200);
      const read = (await (await call(f.env, "GET")).json()) as { configurations: { defaults: { worker?: string } }[]; issues: unknown[] };
      expect(read.configurations[0]?.defaults.worker).toBe("worker-alice");
      expect(read.issues).toEqual([]);
      await expect(call(f.env, "PUT", configuration("worker-bob"))).rejects.toMatchObject({ status: 400 });
      await f.sqlite.exec("UPDATE worker_instances SET revoked_at = now(), enabled = false WHERE id = 'worker-alice'");
      const revoked = (await (await call(f.env, "GET")).json()) as { configurations: { defaults: { worker?: string } }[]; issues: { code: string }[] };
      expect(revoked.configurations[0]?.defaults.worker).toBeUndefined();
      expect(revoked.issues).toMatchObject([{ code: "worker_unavailable" }]);
    } finally {
      if (prior === undefined) delete process.env.SYNTILA_FEATURE_FLAGS;
      else process.env.SYNTILA_FEATURE_FLAGS = prior;
    }
  });

  it("keeps owned Workers and reports Workers that no longer exist", async () => {
    const f = await fixture();
    const saved = { schemaVersion: 1, workflowId: "chat", enabled: true, defaults: { worker: "worker-alice", model: "m" }, stepOverrides: { chat: { worker: "gone" } } } as never;
    const result = await translateConfiguration(f.env, "alice", saved);
    expect(result.configuration.defaults).toEqual({ worker: "worker-alice", model: "m" });
    expect(result.configuration.stepOverrides.chat).toEqual({});
    expect(result.issues).toMatchObject([{ stepId: "chat", code: "worker_unavailable" }]);
  });
});
