import { expect, it, vi } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { identityService } from "../../src/domain/auth/identity-service.js";
import { handleWorkflowDefault } from "../../src/domain/routes/workflow-default.js";
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

vi.mock("../../src/domain/routes/profiles.js", () => ({
  handleListWorkspaceWorkerInventory: async () =>
    Response.json({ workers: [] }),
}));

it("persists scoped defaults, rejects disabled workflows, and falls back to Chat", async () => {
  const { sqlite, db } = sqliteD1();
  const identity = vi
    .spyOn(identityService, "resolve")
    .mockImplementation(async (request) => {
      const user = request.headers.get("authorization");
      return user
        ? { userId: user, email: `${user}@test`, name: user, sessionId: user }
        : null;
    });
  try {
    sqlite.exec(`
      INSERT INTO users(id,email,display_name,created_at,updated_at)
      VALUES ('owner','owner@test','Owner','now','now'),('other','other@test','Other','now','now');
      INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at)
      VALUES ('ws','owner','Workspace','now','now');
      INSERT INTO user_workflow_settings VALUES ('owner','ws','now');
    `);
    const env = { SYNTILA_DB: db } as SecurityEnv;
    const request = (method: string, user = "owner", body?: unknown) =>
      new Request("https://cloud.test/api/user/workflow-default", {
        method,
        headers: { authorization: user },
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
    expect(
      await (await handleWorkflowDefault(request("GET"), env)).json(),
    ).toMatchObject({ defaultWorkflowId: "chat" });
    expect(
      await (
        await handleWorkflowDefault(
          request("PUT", "owner", { defaultWorkflowId: "direct" }),
          env,
        )
      ).json(),
    ).toMatchObject({ defaultWorkflowId: "direct" });
    expect(
      await (await handleWorkflowDefault(request("GET"), env)).json(),
    ).toMatchObject({ defaultWorkflowId: "direct" });
    await expect(
      handleWorkflowDefault(
        request("PUT", "owner", { defaultWorkflowId: "unknown" }),
        env,
      ),
    ).rejects.toMatchObject({ status: 400 });
    await expect(
      handleWorkflowConfigurations(
        new Request(
          "https://cloud.test/api/user/workflow-configurations/chat",
          {
            method: "PUT",
            headers: { authorization: "owner" },
            body: JSON.stringify({
              schemaVersion: 1,
              workflowId: "chat",
              enabled: false,
              defaults: {},
              stepOverrides: {},
            }),
          },
        ),
        env,
        "chat",
      ),
    ).rejects.toMatchObject({ status: 400 });
    await handleWorkflowConfigurations(
      new Request(
        "https://cloud.test/api/user/workflow-configurations/direct",
        {
          method: "PUT",
          headers: { authorization: "owner" },
          body: JSON.stringify({
            schemaVersion: 1,
            workflowId: "direct",
            enabled: false,
            defaults: {},
            stepOverrides: {},
          }),
        },
      ),
      env,
      "direct",
    );
    await expect(
      handleWorkflowDefault(
        request("PUT", "owner", { defaultWorkflowId: "direct" }),
        env,
      ),
    ).rejects.toMatchObject({ status: 400 });
    expect(
      await (await handleWorkflowDefault(request("GET", "other"), env)).json(),
    ).toMatchObject({ defaultWorkflowId: "chat" });
  } finally {
    identity.mockRestore();
    sqlite.close();
  }
});
