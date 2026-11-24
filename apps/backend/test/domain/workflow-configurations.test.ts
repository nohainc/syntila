import { expect, it, vi } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { handleWorkflowConfigurations } from "../../src/domain/routes/workflow-configurations.js";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";

vi.mock("../../src/domain/routes/http-security.js", async (original) => ({
  ...(await original<typeof import("../../src/domain/routes/http-security.js")>()),
  securityContext: async (request: Request) => {
    const userId = request.headers.get("authorization");
    if (!userId) throw new Error("Unauthenticated");
    return { userId };
  },
}));

it("persists only user overrides, isolates users, retains offline choices, resets and rejects foreign writes", async () => {
  const { sqlite, db } = await pgD1();
  try {
    await sqlite.exec(
      "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES ('U','u@test','U','now','now'),('V','v@test','V','now','now')",
    );
    await sqlite.exec(
      "INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES('offline','','U','chatgpt','Offline'),('elsewhere','','V','chatgpt','Elsewhere');",
    );
    const env = { SYNTILA_DB: db } as SecurityEnv;
    const configuration = {
      schemaVersion: 1,
      workflowId: "chat",
      enabled: true,
      defaults: { worker: "offline" },
      stepOverrides: {},
    };
    const request = (method: string, user = "U", body?: unknown) =>
      new Request("https://cloud.test/api/user/workflow-configurations/chat", {
        method,
        headers: user ? { authorization: user } : {},
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
    await expect(
      handleWorkflowConfigurations(request("GET", ""), env),
    ).rejects.toThrow("Unauthenticated");
    await handleWorkflowConfigurations(
      request("PUT", "U", configuration),
      env,
      "chat",
    );
    expect(
      (
        (await (
          await handleWorkflowConfigurations(request("GET"), env)
        ).json()) as { configurations: unknown[] }
      ).configurations,
    ).toEqual([configuration]);
    expect(
      (
        (await (
          await handleWorkflowConfigurations(request("GET", "V"), env)
        ).json()) as { configurations: unknown[] }
      ).configurations,
    ).toEqual([]);
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...configuration,
          defaults: { worker: "elsewhere" },
        }),
        env,
        "chat",
      ),
    ).rejects.toMatchObject({ status: 400 });
    expect(
      (await sqlite
        .prepare("SELECT count(*) n FROM user_worker_workflow_configurations")
        .get())!.n,
    ).toBe(1);
    await handleWorkflowConfigurations(request("DELETE", "V"), env, "chat");
    expect(
      (await sqlite
        .prepare("SELECT count(*) n FROM user_worker_workflow_configurations")
        .get())!.n,
    ).toBe(1);
    await handleWorkflowConfigurations(request("DELETE"), env, "chat");
    expect(
      (await sqlite
        .prepare("SELECT count(*) n FROM user_worker_workflow_configurations")
        .get())!.n,
    ).toBe(0);
    await expect(
      handleWorkflowConfigurations(
        request("PUT", "U", {
          ...configuration,
          enabled: true,
          defaults: { worker: "Auto" },
        }),
        env,
        "chat",
      ),
    ).rejects.toThrow("Worker must be selected explicitly");
    expect(
      (await sqlite
        .prepare("SELECT count(*) n FROM user_worker_workflow_configurations")
        .get())!.n,
    ).toBe(0);
  } finally {
    await sqlite.close();
  }
});
