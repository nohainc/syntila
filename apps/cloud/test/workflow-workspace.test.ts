import { expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { handleCreateSpace } from "../src/routes/spaces.js";
import { identityService } from "../src/auth/identity-service.js";
import { handleWorkflowWorkspace } from "../src/routes/workflow-workspace.js";
import { loadSpaceWorkflowConfigurations } from "../src/routes/space-workflow-configurations.js";
import type { SecurityEnv } from "../src/routes/http-security.js";
it("attaches Workspaces only by explicit per-Space choice, never by inheritance", async () => {
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
    sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('owner','o@test','Owner','now','now'),('member','m@test','Member','now','now');
 INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('a','owner','First','now','now'),('b','owner','Second','now','now'),('foreign','member','Foreign','now','now');
 INSERT INTO workspace_worker_inventory(worker_id,workspace_id,owner_user_id,worker_type_id,activation_state,readiness_state,local_concurrency_limit,revision,created_at,updated_at,last_seen_at) VALUES('worker-a','a','owner','chatgpt','enabled','ready',1,1,'now','now','now');
 INSERT INTO worker_scheduling(worker_id,state,updated_at) VALUES('worker-a','disabled','now');
 INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('s','owner','Space','now','now'),('independent','owner','Independent','now','now');
 INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('o','s','owner','owner','now','now'),('m','s','member','collaborator','now','now');`);
    const env = { SYNTILA_DB: db, BETTER_AUTH_SECRET: "test" } as SecurityEnv;
    const handle = (body?: object, spaceId?: string, user = "owner") =>
      handleWorkflowWorkspace(
        new Request("https://test/api/user/workflow-workspace", {
          method: body ? "PUT" : "GET",
          headers: { authorization: user },
          ...(body ? { body: JSON.stringify(body) } : {}),
        }),
        env,
        spaceId,
      );
    // The account-level selection only picks which account templates are
    // shown; it attaches no Workspace to any Space.
    await handle({ workspaceId: "a" });
    await expect(handle({ workspaceId: "foreign" })).rejects.toMatchObject({
      status: 403,
    });
    expect(
      sqlite.prepare("SELECT COUNT(*) AS n FROM workspace_space_grants").get(),
    ).toEqual({ n: 0 });
    expect(
      sqlite
        .prepare(
          "SELECT state FROM worker_scheduling WHERE worker_id='worker-a'",
        )
        .get(),
    ).toEqual({ state: "disabled" });
    expect(await (await handle(undefined, "s")).json()).toMatchObject({
      workspaceId: null,
      inherited: false,
    });

    // A new Space gets no Workspace unless one is chosen explicitly.
    const create = (body: object) =>
      handleCreateSpace(
        new Request("https://test/api/spaces", {
          method: "POST",
          headers: { authorization: "owner" },
          body: JSON.stringify(body),
        }),
        env,
      );
    const plain = (await (await create({ name: "Plain" })).json()) as {
      space: { id: string };
    };
    expect(
      sqlite
        .prepare(
          "SELECT workspace_id FROM space_workflow_settings WHERE space_id=?",
        )
        .get(plain.space.id),
    ).toEqual({ workspace_id: null });
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS n FROM workspace_space_grants WHERE space_id=?")
        .get(plain.space.id),
    ).toEqual({ n: 0 });
    const chosen = (await (
      await create({ name: "Chosen", workspaceId: "a" })
    ).json()) as { space: { id: string } };
    expect(
      sqlite
        .prepare(
          "SELECT workspace_id,status FROM workspace_space_grants WHERE space_id=?",
        )
        .get(chosen.space.id),
    ).toEqual({ workspace_id: "a", status: "active" });
    await expect(
      create({ name: "Foreign", workspaceId: "foreign" }),
    ).rejects.toMatchObject({ status: 403 });

    // Only the owner chooses a Space's Workspace, with reset confirmation.
    await expect(
      handle({ workspaceId: "a", confirmReset: true }, "s", "member"),
    ).rejects.toMatchObject({ status: 403 });
    await expect(handle({ workspaceId: "a" }, "s")).rejects.toMatchObject({
      status: 409,
    });
    await handle({ workspaceId: "a", confirmReset: true }, "s");
    expect(await (await handle(undefined, "s", "member")).json()).toMatchObject(
      { workspaceId: "a", workspaces: [{ id: "a", name: "First" }] },
    );
    expect(
      sqlite
        .prepare(
          "SELECT state FROM worker_scheduling WHERE worker_id='worker-a'",
        )
        .get(),
    ).toEqual({ state: "enabled" });
    // There is no inheritance any more.
    await expect(
      handle({ inherit: true, confirmReset: true }, "s"),
    ).rejects.toMatchObject({ status: 400 });

    // Switching a Space resets only that Space's overrides.
    const config = JSON.stringify({
      schemaVersion: 1,
      workflowId: "chat",
      enabled: false,
      defaults: {},
      stepOverrides: {},
    });
    sqlite.exec(
      "INSERT INTO space_workflow_settings VALUES('independent','b','now')",
    );
    sqlite
      .prepare(
        "INSERT INTO space_workflow_configurations VALUES('independent','chat',1,?,'now'),('s','chat',1,?,'now')",
      )
      .run(config, config);
    await handle({ workspaceId: "b", confirmReset: true }, "s");
    expect(
      sqlite
        .prepare(
          "SELECT space_id FROM space_workflow_configurations ORDER BY space_id",
        )
        .all(),
    ).toEqual([{ space_id: "independent" }]);
    expect((await loadSpaceWorkflowConfigurations(env, "s")).workspaceId).toBe(
      "b",
    );
  } finally {
    identity.mockRestore();
    sqlite.close();
  }
});
