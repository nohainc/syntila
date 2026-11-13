import { expect, it } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  handleCreateThread,
  handleUpdateThread,
  handleDeleteThread,
  handleListSpaceThreads,
  handleUpdateSpace,
  type SecurityEnv,
} from "../../src/domain/routes/handlers.js";

it("owners manage all Threads while collaborators manage only their assigned Threads", async () => {
  const { sqlite, db } = sqliteD1();
  const roles = {
    owner: "owner",
    lead: "collaborator",
    other: "collaborator",
    viewer: "viewer",
  };
  for (const id of Object.keys(roles)) {
    sqlite
      .prepare(
        "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES(?,?,?,'now','now')",
      )
      .run(id, `${id}@test`, id);
  }
  sqlite.exec(
    "INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('P','owner','Space','now','now')",
  );
  for (const [id, role] of Object.entries(roles))
    sqlite
      .prepare(
        "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES(?,'P',?,?,'now','now')",
      )
      .run(`m-${id}`, id, role);
  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    TEST_AUTHENTICATION: async (request: Request) => {
      const userId = request.headers.get("test-user")!;
      return {
        userId,
        user: {
          id: userId,
          email: `${userId}@test`,
          displayName: userId,
          status: "active",
        },
        workspaceId: "",
        spaceRoles: { P: roles[userId as keyof typeof roles] },
        sessionId: "test",
        clientType: "web",
      };
    },
  } as unknown as SecurityEnv;
  const request = (user: string, body: unknown = {}, method = "PATCH") =>
    new Request("https://test/api", {
      method,
      headers: { "test-user": user },
      body: JSON.stringify(body),
    });
  try {
    const created = await handleCreateThread(
      request("lead", { name: "Lead's stream" }, "POST"),
      env,
      "P",
    );
    const { thread } = (await created.json()) as {
      thread: { id: string; canConfigureWork: boolean };
    };
    expect(thread.canConfigureWork).toBe(true);
    expect(
      sqlite
        .prepare("SELECT lead_user_id FROM threads WHERE id=?")
        .get(thread.id),
    ).toEqual({ lead_user_id: "lead" });
    for (const user of ["other", "viewer"]) {
      await expect(
        handleUpdateThread(
          request(user, { name: "Forbidden" }),
          env,
          thread.id,
        ),
      ).rejects.toMatchObject({ status: 403 });
      await handleUpdateThread(
        request(user, { status: "archived" }),
        env,
        thread.id,
      );
      await handleUpdateThread(
        request(user, { status: "active" }),
        env,
        thread.id,
      );
      await expect(
        handleDeleteThread(request(user, {}, "DELETE"), env, thread.id),
      ).rejects.toMatchObject({ status: 403 });
    }
    await handleUpdateThread(
      request("lead", { name: "Renamed", status: "archived" }),
      env,
      thread.id,
    );
    await handleUpdateThread(
      request("owner", { status: "active" }),
      env,
      thread.id,
    );
    const list = await handleListSpaceThreads(
      new Request("https://test/api", { headers: { "test-user": "other" } }),
      env,
      "P",
    );
    expect(await list.json()).toMatchObject({
      threads: [{ canConfigureWork: false }],
    });
    await expect(
      handleCreateThread(
        request("viewer", { name: "Forbidden" }, "POST"),
        env,
        "P",
      ),
    ).rejects.toMatchObject({ status: 403 });
    await expect(
      handleUpdateSpace(
        request("other", { settings: { threadOrder: [thread.id] } }),
        env,
        "P",
      ),
    ).rejects.toMatchObject({ status: 403 });
    await handleUpdateSpace(
      request("owner", { settings: { threadOrder: [thread.id] } }),
      env,
      "P",
    );
    await handleDeleteThread(request("lead", {}, "DELETE"), env, thread.id);
    const second = await handleCreateThread(
      request("other", { name: "Other's stream" }, "POST"),
      env,
      "P",
    );
    const result = (await second.json()) as { thread: { id: string } };
    await handleDeleteThread(
      request("owner", {}, "DELETE"),
      env,
      result.thread.id,
    );
  } finally {
    sqlite.close();
  }
});
