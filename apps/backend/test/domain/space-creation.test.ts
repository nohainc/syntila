import { pgD1 } from "./helpers/pg-d1";
import { member, space, user } from "./helpers/seed";
import { beforeEach, describe, expect, it } from "./helpers/vitest-compat";
import {
  handleCreateSpace,
  handleCreateThread,
  handleGetSpace,
  handleUpdateSpace,
} from "../../src/domain/routes/handlers.js";

const authenticate = (spaceRoles: Record<string, string> = {}) => async () => ({
  userId: "user-1",
  user: {
    id: "user-1",
    email: "owner@example.test",
    displayName: "Owner",
    status: "active",
  },
  workspaceId: "",
  spaceRoles,
  sessionId: "session-1",
  clientType: "web",
});

const json = (url: string, method: string, body: unknown) =>
  new Request(url, {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

describe("Space creation", () => {
  let handle: Awaited<ReturnType<typeof pgD1>>;
  const count = async (table: string, where = "TRUE") =>
    Number(
      (await handle.sqlite.prepare(`SELECT count(*) AS n FROM ${table} WHERE ${where}`).get() as { n: number | string }).n,
    );

  beforeEach(async () => {
    handle = await pgD1();
    await handle.sqlite.exec(user("user-1", { email: "owner@example.test", name: "Owner" }) + user("other"));
  });
  const envWith = (spaceRoles: Record<string, string> = {}) =>
    ({
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: handle.db,
      TEST_AUTHENTICATION: authenticate(spaceRoles),
    }) as never;

  it("refuses a Workspace the creator does not own and creates nothing", async () => {
    await handle.sqlite.exec(
      `INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at)
       VALUES ('ws-revoked','other','Theirs','online','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');`,
    );
    await expect(
      handleCreateSpace(
        json("https://syntila.test/api/spaces", "POST", {
          name: "Not mine",
          workspaceId: "ws-revoked",
        }),
        envWith(),
      ),
    ).rejects.toMatchObject({ status: 403 });
    expect(await count("spaces")).toBe(0);
    expect(await count("space_memberships")).toBe(0);
  });

  it("creates a Space without requiring an execution Workspace", async () => {
    const response = await handleCreateSpace(
      json("https://syntila.test/api/spaces", "POST", { name: "Unattached Space" }),
      envWith(),
    );

    expect(response.status).toBe(201);
    const { space: created } = (await response.json()) as { space: { id: string; name: string } };
    expect(created.name).toBe("Unattached Space");
    expect(await count("spaces", `id = '${created.id}' AND owner_user_id = 'user-1'`)).toBe(1);
    expect(await count("space_memberships", `space_id = '${created.id}' AND user_id = 'user-1' AND role = 'owner'`)).toBe(1);
    // The Space records "no Workspace" explicitly; nothing is inherited.
    expect(await count("space_workflow_settings", `space_id = '${created.id}' AND workspace_id IS NULL`)).toBe(1);
  });

  it("creates a persisted Thread with its Space lead", async () => {
    await handle.sqlite.exec(space("space-1", "user-1") + member("space-1", "user-1"));
    const response = await handleCreateThread(
      json("https://syntila.test/api/spaces/space-1/threads", "POST", { name: "Authentication work" }),
      envWith({ "space-1": "owner" }),
      "space-1",
    );

    expect(response.status).toBe(201);
    const body = (await response.json()) as { thread: { id: string } };
    expect(body).toMatchObject({
      thread: {
        spaceId: "space-1",
        name: "Authentication work",
        status: "active",
        lead: "user-1",
      },
    });
    expect(await count("threads", `id = '${body.thread.id}' AND space_id = 'space-1' AND lead_user_id = 'user-1'`)).toBe(1);
  });

  it("gets and updates a Space with custom settings", async () => {
    await handle.sqlite.exec(
      `INSERT INTO spaces(id,owner_user_id,name,description,settings_json,created_at,updated_at)
         VALUES ('space-1','user-1','Original Name','Original Desc','{"threadOrder":["ws-1","ws-2"]}','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');` +
        member("space-1", "user-1"),
    );
    const roles = { "space-1": "owner" };

    const getRes = await handleGetSpace(
      new Request("https://syntila.test/api/spaces/space-1"),
      envWith(roles),
      "space-1",
    );
    expect(getRes.status).toBe(200);
    const getBody = (await getRes.json()) as {
      space: { name: string; instructions: string; settings: { threadOrder: string[] } };
    };
    expect(getBody.space.name).toBe("Original Name");
    expect(getBody.space.instructions).toBe("");
    expect(getBody.space.settings.threadOrder).toEqual(["ws-1", "ws-2"]);

    const updateRes = await handleUpdateSpace(
      json("https://syntila.test/api/spaces/space-1", "PATCH", {
        name: "Updated Name",
        settings: { threadOrder: ["ws-2", "ws-1"] },
      }),
      envWith(roles),
      "space-1",
    );
    expect(updateRes.status).toBe(200);
    const updateBody = (await updateRes.json()) as {
      space: { name: string; settings: { threadOrder: string[] } };
    };
    expect(updateBody.space.name).toBe("Updated Name");
    expect(updateBody.space.settings.threadOrder).toEqual(["ws-2", "ws-1"]);

    const stored = await handle.sqlite
      .prepare("SELECT name, settings_json AS settings FROM spaces WHERE id = 'space-1'")
      .get() as { name: string; settings: string };
    expect(stored.name).toBe("Updated Name");
    expect(JSON.parse(stored.settings).threadOrder).toEqual(["ws-2", "ws-1"]);

    await expect(
      handleUpdateSpace(
        json("https://syntila.test/api/spaces/space-1", "PATCH", {
          settings: { showAiHistory: "yes" },
        }),
        envWith(roles),
        "space-1",
      ),
    ).rejects.toMatchObject({ status: 400 });
    // The rejected update left the stored Space untouched.
    expect(
      (await handle.sqlite.prepare("SELECT name FROM spaces WHERE id = 'space-1'").get() as { name: string }).name,
    ).toBe("Updated Name");
  });
});
