import { describe, expect, it, vi } from "vitest";
import {
  handleCreateSpace,
  handleCreateThread,
  handleGetSpace,
  handleUpdateSpace,
} from "../src/routes/handlers.js";

vi.mock("../src/collaboration-events.js", () => ({
  publishCollaborationEvent: async (
    env: {
      SYNTILA_DB: { batch?: (statements: unknown[]) => Promise<unknown> };
    },
    _type: string,
    _space: string,
    _entity: string,
    options: { mutations?: { run: () => Promise<unknown> }[] } = {},
  ) => {
    if (env.SYNTILA_DB.batch)
      await env.SYNTILA_DB.batch(options.mutations ?? []);
    else for (const statement of options.mutations ?? []) await statement.run();
  },
}));
describe("Space creation", () => {
  it("refuses a Workspace the creator does not own and creates nothing", async () => {
    const db = {
      prepare() {
        return {
          bind() {
            return this;
          },
          async first() {
            return null;
          },
          async all() {
            return { results: [] };
          },
          async run() {
            return { success: true };
          },
        };
      },
      async batch() {
        batches += 1;
        return [];
      },
    };
    let batches = 0;
    await expect(
      handleCreateSpace(
      new Request("https://syntila.test/api/spaces", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          name: "Not mine",
          workspaceId: "ws-revoked",
        }),
      }),
      {
        SYNTILA_ENVIRONMENT: "development",
        SYNTILA_DB: db,
        TEST_AUTHENTICATION: async () => ({
          userId: "user-1",
          user: {
            id: "user-1",
            email: "owner@example.test",
            displayName: "Owner",
            status: "active",
          },
          workspaceId: "",
          spaceRoles: {},
          sessionId: "session-1",
          clientType: "web",
        }),
      } as never,
    ),
    ).rejects.toMatchObject({ status: 403 });
    expect(batches).toBe(0);
  });

  it("creates a Space without requiring an execution Workspace", async () => {
    const prepared: string[] = [];
    let batchSize = 0;
    const db = {
      prepare(query: string) {
        prepared.push(query);
        return {
          bind() {
            return this;
          },
          async first() {
            return null;
          },
          async run() {
            return { success: true };
          },
        };
      },
      async batch(statements: readonly unknown[]) {
        batchSize = statements.length;
        return [];
      },
    };

    const response = await handleCreateSpace(
      new Request("https://syntila.test/api/spaces", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "Unattached Space" }),
      }),
      {
        SYNTILA_ENVIRONMENT: "development",
        SYNTILA_DB: db,
        TEST_AUTHENTICATION: async () => ({
          userId: "user-1",
          user: {
            id: "user-1",
            email: "owner@example.test",
            displayName: "Owner",
            status: "active",
          },
          workspaceId: "",
          spaceRoles: {},
          sessionId: "session-1",
          clientType: "web",
        }),
      } as never,
    );

    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({
      space: { name: "Unattached Space" },
    });
    expect(prepared).toContainEqual(
      expect.stringContaining("INSERT INTO spaces (id, owner_user_id"),
    );
    expect(prepared).toContainEqual(
      expect.stringContaining("INSERT INTO space_memberships"),
    );
    // The Space records "no Workspace" explicitly; nothing is inherited.
    expect(prepared).toContainEqual(
      expect.stringContaining("INSERT INTO space_workflow_settings"),
    );
    expect(prepared.join("\n")).not.toContain("user_workflow_settings");
    expect(batchSize).toBe(3);
  });

  it("creates a persisted Thread with its Space lead", async () => {
    const prepared: string[] = [];
    const db = {
      prepare(query: string) {
        prepared.push(query);
        return {
          bind() {
            return this;
          },
          async first() {
            return query.includes("space_memberships")
              ? { role: "owner" }
              : null;
          },
          async run() {
            return { success: true };
          },
        };
      },
    };
    const response = await handleCreateThread(
      new Request("https://syntila.test/api/spaces/space-1/threads", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "Authentication work" }),
      }),
      {
        SYNTILA_ENVIRONMENT: "development",
        SYNTILA_DB: db,
        TEST_AUTHENTICATION: async () => ({
          userId: "user-1",
          user: {
            id: "user-1",
            email: "owner@example.test",
            displayName: "Owner",
            status: "active",
          },
          workspaceId: "",
          spaceRoles: { "space-1": "owner" },
          sessionId: "session-1",
          clientType: "web",
        }),
      } as never,
      "space-1",
    );

    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({
      thread: {
        spaceId: "space-1",
        name: "Authentication work",
        status: "active",
        lead: "user-1",
      },
    });
    expect(prepared).toContainEqual(
      expect.stringContaining("INSERT INTO threads"),
    );
  });

  it("gets and updates a Space with custom settings", async () => {
    let updatedQuery = "";
    let updatedBindings: unknown[] = [];
    const db = {
      prepare(query: string) {
        if (
          query.includes("owner_user_id = ?1") &&
          query.includes("id <> ?2")
        ) {
          return {
            bind() {
              return this;
            },
            async first() {
              return null;
            },
          };
        }
        if (query.includes("SELECT") && query.includes("FROM spaces")) {
          return {
            bind() {
              return this;
            },
            async first() {
              return {
                id: "space-1",
                name: "Original Name",
                ownerUserId: "user-1",
                role: "owner",
                description: "Original Desc",
                settingsJson: JSON.stringify({
                  threadOrder: ["ws-1", "ws-2"],
                }),
                createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z",
              };
            },
          };
        }
        if (query.includes("UPDATE spaces")) {
          return {
            bind(...args: unknown[]) {
              updatedQuery = query;
              updatedBindings = args;
              return this;
            },
            async run() {
              return { success: true, meta: { changes: 1 } };
            },
          };
        }
        if (query.includes("space_memberships")) {
          return {
            bind() {
              return this;
            },
            async first() {
              return { role: "owner" };
            },
          };
        }
        return {
          bind() {
            return this;
          },
        };
      },
    };

    const auth = async () => ({
      userId: "user-1",
      user: {
        id: "user-1",
        email: "owner@example.test",
        displayName: "Owner",
        status: "active",
      },
      workspaceId: "",
      spaceRoles: { "space-1": "owner" },
      sessionId: "session-1",
      clientType: "web",
    });

    const getRes = await handleGetSpace(
      new Request("https://syntila.test/api/spaces/space-1"),
      {
        SYNTILA_ENVIRONMENT: "development",
        SYNTILA_DB: db,
        TEST_AUTHENTICATION: auth,
      } as never,
      "space-1",
    );
    expect(getRes.status).toBe(200);
    const getBody = (await getRes.json()) as {
      space: {
        name: string;
        instructions: string;
        settings: { threadOrder: string[] };
      };
    };
    expect(getBody.space.name).toBe("Original Name");
    expect(getBody.space.instructions).toBe("");
    expect(getBody.space.settings.threadOrder).toEqual(["ws-1", "ws-2"]);

    const updateRes = await handleUpdateSpace(
      new Request("https://syntila.test/api/spaces/space-1", {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          name: "Updated Name",
          settings: { threadOrder: ["ws-2", "ws-1"] },
        }),
      }),
      {
        SYNTILA_ENVIRONMENT: "development",
        SYNTILA_DB: db,
        TEST_AUTHENTICATION: auth,
      } as never,
      "space-1",
    );
    expect(updateRes.status).toBe(200);
    const updateBody = (await updateRes.json()) as {
      space: {
        name: string;
        settings: { threadOrder: string[] };
      };
    };
    expect(updateBody.space.name).toBe("Updated Name");
    expect(updateBody.space.settings.threadOrder).toEqual(["ws-2", "ws-1"]);
    expect(updatedQuery).toContain("UPDATE spaces SET name = ?1");
    expect(updatedBindings[0]).toBe("Updated Name");

    await expect(
      handleUpdateSpace(
        new Request("https://syntila.test/api/spaces/space-1", {
          method: "PATCH",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ settings: { showAiHistory: "yes" } }),
        }),
        {
          SYNTILA_ENVIRONMENT: "development",
          SYNTILA_DB: db,
          TEST_AUTHENTICATION: auth,
        } as never,
        "space-1",
      ),
    ).rejects.toMatchObject({ status: 400 });
  });
});
