import { expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { identityService } from "../src/auth/identity-service.js";
import { handleWorkflowConfigurations } from "../src/routes/workflow-configurations.js";
import { loadSpaceWorkflowConfigurations } from "../src/routes/space-workflow-configurations.js";
import type { SecurityEnv } from "../src/routes/http-security.js";
vi.mock("../src/routes/profiles.js", () => ({
  handleListWorkspaceWorkerInventory: async () =>
    Response.json({
      workers: [
        {
          id: "worker",
          workspaceId: "ws",
          displayName: "Worker",
          executionOptions: null,
        },
      ],
    }),
}));
it("shares owner defaults across members, isolates Spaces, restricts writes, and resets to inheritance", async () => {
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
    sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('owner','owner@test','Owner','now','now'),('member','member@test','Member','now','now'),('outsider','out@test','Out','now','now');
      INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('s','owner','Space','now','now'),('other','outsider','Other','now','now');
      INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('o','s','owner','owner','now','now'),('m','s','member','collaborator','now','now');`);
    sqlite.exec(
      "INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('ws','owner','Workspace','now','now'); INSERT INTO user_workflow_settings VALUES('owner','ws','now'); INSERT INTO space_workflow_settings VALUES('s','ws','now'); INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('ws-member','member','Member Workspace','now','now');",
    );
    const config = (enabled: boolean) => ({
      schemaVersion: 1,
      workflowId: "chat",
      enabled,
      defaults: enabled ? { worker: "worker" } : {},
      stepOverrides: {},
    });
    sqlite
      .prepare(
        "INSERT INTO user_workflow_configurations VALUES('owner','ws','chat',1,?,'now')",
      )
      .run(JSON.stringify(config(false)));
    sqlite
      .prepare(
        "INSERT INTO user_workflow_configurations VALUES('member','ws-member','chat',1,?,'now')",
      )
      .run(JSON.stringify(config(true)));
    const env = {
      SYNTILA_DB: db,
      BETTER_AUTH_SECRET: "test-secret",
    } as SecurityEnv;
    const request = (method: string, user?: string, body?: unknown) =>
      new Request(
        "https://cloud.test/api/spaces/s/workflow-configurations/chat",
        {
          method,
          headers: user ? { authorization: user } : {},
          ...(body ? { body: JSON.stringify(body) } : {}),
        },
      );
    const handle = (
      method: string,
      user?: string,
      body?: unknown,
      space = "s",
    ) =>
      handleWorkflowConfigurations(
        request(method, user, body),
        env,
        "chat",
        undefined,
        space,
      );
    await expect(handle("GET")).rejects.toMatchObject({ status: 401 });
    await expect(handle("GET", "outsider")).rejects.toMatchObject({
      status: 403,
    });
    expect(await (await handle("GET", "member")).json()).toMatchObject({
      configurations: [config(false)],
    });
    await expect(handle("PUT", "member", config(true))).rejects.toMatchObject({
      status: 403,
    });
    await expect(handle("DELETE", "member")).rejects.toMatchObject({
      status: 403,
    });
    await expect(
      handle("PUT", "owner", { ...config(true), spaceId: "other" }),
    ).rejects.toMatchObject({ status: 400 });
    await expect(
      handle("PUT", "owner", config(true), "other"),
    ).rejects.toMatchObject({ status: 403 });
    await handle("PUT", "owner", config(true));
    expect(await (await handle("GET", "member")).json()).toMatchObject({
      configurations: [config(true)],
    });
    expect(
      (await loadSpaceWorkflowConfigurations(env, "other")).configurations,
    ).toEqual([]);
    // An explicit Worker override is stored: it can replace disabled global defaults.
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM space_workflow_configurations")
        .get(),
    ).toEqual({ count: 1 });
    await handle("DELETE", "owner");
    expect(await (await handle("GET", "member")).json()).toMatchObject({
      configurations: [config(false)],
    });
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM space_workflow_configurations")
        .get(),
    ).toEqual({ count: 0 });
  } finally {
    identity.mockRestore();
    sqlite.close();
  }
});
