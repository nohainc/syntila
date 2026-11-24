import { expect, it, vi } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { identityService } from "../../src/domain/auth/identity-service.js";
import { handleWorkflowConfigurations } from "../../src/domain/routes/workflow-configurations.js";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";
vi.mock("../../src/domain/routes/profiles.js", () => ({
  handleListWorkspaceWorkerInventory: async () =>
    Response.json({ workers: [] }),
}));
it("authenticates actual human sessions and isolates GET/PUT/DELETE ownership", async () => {
  const { sqlite, db } = await pgD1();
  const identity = vi
    .spyOn(identityService, "resolve")
    .mockImplementation(async (request) => {
      const user = request.headers.get("authorization");
      return user
        ? {
            userId: user,
            email: `${user}@test`,
            name: user,
            sessionId: `session-${user}`,
          }
        : null;
    });
  try {
    await sqlite.exec(
      "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('one','one@test','One','now','now'),('two','two@test','Two','now','now')",
    );
    const configuration = (enabled: boolean) => ({
      schemaVersion: 1,
      workflowId: "direct",
      enabled,
      defaults: {},
      stepOverrides: {},
    });
    await sqlite
      .prepare(
        "INSERT INTO user_worker_workflow_configurations(user_id, workflow_id, schema_version, configuration_json, updated_at) VALUES('two','direct',1,?,'now')",
      )
      .run(JSON.stringify(configuration(false)));
    const env = {
      SYNTILA_DB: db,
      BETTER_AUTH_SECRET: "test-secret",
    } as SecurityEnv;
    const request = (method: string, user?: string, body?: unknown) =>
      new Request(
        "https://cloud.test/api/user/workflow-configurations/direct",
        {
          method,
          headers: user ? { authorization: user } : {},
          ...(body ? { body: JSON.stringify(body) } : {}),
        },
      );
    await expect(
      handleWorkflowConfigurations(request("GET"), env),
    ).rejects.toMatchObject({ status: 401 });
    expect(
      await (
        await handleWorkflowConfigurations(request("GET", "one"), env)
      ).json(),
    ).toMatchObject({ configurations: [] });
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "one", { ...configuration(false), userId: "two" }),
        env,
        "direct",
      ),
    ).rejects.toMatchObject({ status: 400 });
    await handleWorkflowConfigurations(
      request("PUT", "one", configuration(false)),
      env,
      "direct",
    );
    await handleWorkflowConfigurations(request("DELETE", "one"), env, "direct");
    expect(
      await (
        await handleWorkflowConfigurations(request("GET", "two"), env, "direct")
      ).json(),
    ).toMatchObject({ configurations: [configuration(false)] });
    expect(
      await sqlite.prepare("SELECT user_id FROM user_worker_workflow_configurations").all(),
    ).toEqual([{ user_id: "two" }]);
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "one", {
          ...configuration(true),
          stepOverrides: { invented: { effort: "high" } },
        }),
        env,
        "direct",
      ),
    ).rejects.toMatchObject({ status: 400 });
  } finally {
    identity.mockRestore();
    await sqlite.close();
  }
});
