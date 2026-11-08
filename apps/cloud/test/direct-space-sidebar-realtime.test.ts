/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import worker from "../src/index.js";

describe("Direct Space Sidebar, Realtime & Synchronization (Phase 8)", () => {
  function createTestEnv() {
    const { sqlite, db } = sqliteD1();
    const now = new Date().toISOString();

    sqlite.exec(`
      INSERT INTO users (id, email, display_name, avatar_url, status, created_at, updated_at) VALUES
        ('user-alice', 'alice@test.com', 'Alice User', 'r2://avatars/user-alice/alice-v1', 'active', '${now}', '${now}'),
        ('user-bob', 'bob@test.com', 'Bob User', 'r2://avatars/user-bob/bob-v1', 'active', '${now}', '${now}');

      INSERT INTO people_relationships (user_low_id, user_high_id, established_at) VALUES
        ('user-alice', 'user-bob', '${now}');
    `);

    const users: Record<
      string,
      {
        id: string;
        email: string;
        displayName: string;
        avatarUrl: string | null;
        status: string;
      }
    > = {
      alice: {
        id: "user-alice",
        email: "alice@test.com",
        displayName: "Alice User",
        avatarUrl: "r2://avatars/user-alice/alice-v1",
        status: "active",
      },
      bob: {
        id: "user-bob",
        email: "bob@test.com",
        displayName: "Bob User",
        avatarUrl: "r2://avatars/user-bob/bob-v1",
        status: "active",
      },
    };

    const env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: db,
      TEST_AUTHENTICATION: async (req: Request) => {
        const authHeader = req.headers.get("authorization");
        const key = authHeader?.replace("Bearer ", "");
        const user = key ? users[key] : null;
        if (!user) {
          return {
            userId: "anonymous",
            user: {
              id: "anonymous",
              email: "anon@test.com",
              displayName: "Anon",
              status: "active",
            },
            workspaceId: "",
            spaceRoles: {},
            sessionId: "sess-anon",
            clientType: "web",
          };
        }
        return {
          userId: user.id,
          user,
          workspaceId: "",
          spaceRoles: {},
          sessionId: `sess-${user.id}`,
          clientType: "web",
        };
      },
    };

    return { sqlite, db, env, users };
  }

  async function establishDirectSpace(env: any) {
    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer alice",
        },
        body: JSON.stringify({ userId: "user-bob" }),
      }),
      env as never,
    );
    expect(inviteRes.status).toBe(201);
    const { invitation } = (await inviteRes.json()) as any;

    const acceptRes = await worker.fetch(
      new Request(
        `https://syntila.test/api/people/invitations/${invitation.id}/accept`,
        {
          method: "POST",
          headers: { Authorization: "Bearer bob" },
        },
      ),
      env as never,
    );
    expect(acceptRes.status).toBe(200);
    const { directSpaceId } = (await acceptRes.json()) as any;
    return { directSpaceId, invitationId: invitation.id };
  }

  it("keeps a People Space name personal and resets to the current profile name", async () => {
    const { env, sqlite } = createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);
    const url = `https://syntila.test/api/spaces/${directSpaceId}`;
    const requestAs = (user: string, body?: object) =>
      worker.fetch(
        new Request(url, {
          method: body ? "PATCH" : "GET",
          headers: {
            Authorization: `Bearer ${user}`,
            ...(body ? { "Content-Type": "application/json" } : {}),
          },
          ...(body ? { body: JSON.stringify(body) } : {}),
        }),
        env as never,
      );
    expect(
      (await requestAs("alice", { settings: { personalName: "Bob (work)" } }))
        .status,
    ).toBe(200);
    expect(((await (await requestAs("alice")).json()) as any).space.name).toBe(
      "Bob (work)",
    );
    expect(((await (await requestAs("bob")).json()) as any).space.name).toBe(
      "Alice User",
    );
    sqlite.exec(
      "UPDATE users SET display_name = 'Robert' WHERE id = 'user-bob'",
    );
    const listed = await worker.fetch(
      new Request("https://syntila.test/api/spaces?archived=true", {
        headers: { Authorization: "Bearer alice" },
      }),
      env as never,
    );
    const personal = ((await listed.json()) as any).spaces.find(
      (s: any) => s.id === directSpaceId,
    );
    expect(personal.name).toBe("Bob (work)");
    expect(personal.settings.originalName).toBe("Robert");
    expect(
      (await requestAs("alice", { settings: { personalName: null } })).status,
    ).toBe(200);
    expect(((await (await requestAs("alice")).json()) as any).space.name).toBe(
      "Robert",
    );
    expect(((await (await requestAs("bob")).json()) as any).space.name).toBe(
      "Alice User",
    );
    expect(
      (await requestAs("alice", { settings: { personalName: "  " } })).status,
    ).toBe(400);
    expect(
      (
        await requestAs("alice", {
          settings: { personalName: "Alias", color: "red" },
        })
      ).status,
    ).toBe(400);
  });

  for (const role of ["viewer", "collaborator"]) {
    it(`archives and restores a shared Space for the ${role} only`, async () => {
      const { env, sqlite } = createTestEnv();
      sqlite.exec(`
        INSERT INTO spaces (id, name, kind, owner_user_id, created_at, updated_at)
        VALUES ('shared', 'Shared', 'group', 'user-alice', 'now', 'now');
        INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES
          ('owner-membership', 'shared', 'user-alice', 'owner', 'now', 'now'),
          ('member-membership', 'shared', 'user-bob', '${role}', 'now', 'now');
      `);
      const patch = (body: object) =>
        worker.fetch(
          new Request("https://syntila.test/api/spaces/shared", {
            method: "PATCH",
            headers: {
              Authorization: "Bearer bob",
              "Content-Type": "application/json",
            },
            body: JSON.stringify(body),
          }),
          env as never,
        );
      const list = async (user: string, archived = false) => {
        const response = await worker.fetch(
          new Request(
            `https://syntila.test/api/spaces${archived ? "?archived=true" : ""}`,
            {
              headers: { Authorization: `Bearer ${user}` },
            },
          ),
          env as never,
        );
        return ((await response.json()) as any).spaces;
      };

      const outsider = await worker.fetch(
        new Request("https://syntila.test/api/spaces/shared", {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ archived: true }),
        }),
        env as never,
      );
      expect(outsider.status).toBe(403);
      expect(
        (await patch({ archived: true, description: "changed" })).status,
      ).toBe(403);
      expect((await patch({ archived: true })).status).toBe(200);
      expect((await list("bob")).some((s: any) => s.id === "shared")).toBe(
        false,
      );
      expect(
        (await list("bob", true)).find((s: any) => s.id === "shared").archived,
      ).toBe(true);
      expect(
        (await list("alice")).find((s: any) => s.id === "shared").archived,
      ).toBe(false);
      expect((await patch({ settings: { archived: false } })).status).toBe(200);
      expect(
        (await list("bob")).find((s: any) => s.id === "shared").archived,
      ).toBe(false);
    });
  }

  it("archives and restores a People Space for the caller only", async () => {
    const { env } = createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);
    const url = `https://syntila.test/api/spaces/${directSpaceId}`;
    await worker.fetch(
      new Request(url, { headers: { Authorization: "Bearer bob" } }),
      env as never,
    );
    const patch = (body: object) =>
      worker.fetch(
        new Request(url, {
          method: "PATCH",
          headers: {
            Authorization: "Bearer bob",
            "Content-Type": "application/json",
          },
          body: JSON.stringify(body),
        }),
        env as never,
      );
    const list = async (user: string, archived = false) => {
      const response = await worker.fetch(
        new Request(
          `https://syntila.test/api/spaces${archived ? "?archived=true" : ""}`,
          {
            headers: { Authorization: `Bearer ${user}` },
          },
        ),
        env as never,
      );
      return ((await response.json()) as any).spaces;
    };
    expect((await patch({ archived: true })).status).toBe(200);
    expect((await list("bob")).some((s: any) => s.id === directSpaceId)).toBe(
      false,
    );
    expect(
      (await list("bob", true)).find((s: any) => s.id === directSpaceId)
        .archived,
    ).toBe(true);
    expect(
      (await list("alice", true)).find((s: any) => s.id === directSpaceId)
        .archived,
    ).toBe(false);
    expect((await patch({ settings: { archived: false } })).status).toBe(200);
    expect(
      (await list("bob")).find((s: any) => s.id === directSpaceId).archived,
    ).toBe(false);
  });

  it("inactive/unused Direct Space is not in sidebar until opened, messaged, or pinned", async () => {
    const { env } = createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);

    // Alice lists spaces (sidebar query with archived=false)
    let listRes = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { Authorization: "Bearer alice" },
      }),
      env as never,
    );
    let listData = (await listRes.json()) as any;
    // Before opening or messaging, it should be excluded from active sidebar
    expect(listData.spaces.some((s: any) => s.id === directSpaceId)).toBe(
      false,
    );

    // Alice opens the Direct Space (GET /api/spaces/:id)
    const getRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { Authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(getRes.status).toBe(200);

    // Now Alice lists spaces again: it should be visible!
    listRes = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { Authorization: "Bearer alice" },
      }),
      env as never,
    );
    listData = (await listRes.json()) as any;
    const directSpace = listData.spaces.find(
      (s: any) => s.id === directSpaceId,
    );
    expect(directSpace).toBeDefined();
    expect(directSpace.name).toBe("Bob User");
    expect(directSpace.kind).toBe("direct");
    expect(directSpace.archived).toBe(false);

    // For Bob who hasn't opened it yet, it's still excluded
    const bobListRes = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { Authorization: "Bearer bob" },
      }),
      env as never,
    );
    const bobListData = (await bobListRes.json()) as any;
    expect(bobListData.spaces.some((s: any) => s.id === directSpaceId)).toBe(
      false,
    );
  });

  it("dynamic titles & avatar URL reflect peer's latest profile", async () => {
    const { env, sqlite, users } = createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);

    // Alice opens direct space
    await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { Authorization: "Bearer alice" },
      }),
      env as never,
    );

    let listRes = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { Authorization: "Bearer alice" },
      }),
      env as never,
    );
    let directSpace = ((await listRes.json()) as any).spaces.find(
      (s: any) => s.id === directSpaceId,
    );
    expect(directSpace.name).toBe("Bob User");
    expect(directSpace.avatarUrl).toContain("user-bob");

    // Bob updates his display name in users table
    sqlite.exec(
      "UPDATE users SET display_name = 'Robert Marley' WHERE id = 'user-bob'",
    );
    users.bob!.displayName = "Robert Marley";

    listRes = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { Authorization: "Bearer alice" },
      }),
      env as never,
    );
    directSpace = ((await listRes.json()) as any).spaces.find(
      (s: any) => s.id === directSpaceId,
    );
    expect(directSpace.name).toBe("Robert Marley");
  });

  it("personal hide removes conversation from active sidebar and incoming message unhides it", async () => {
    const { env } = createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);

    // Alice opens direct space
    await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { Authorization: "Bearer alice" },
      }),
      env as never,
    );

    // Alice hides conversation (Hide Conversation action sends PATCH /api/spaces/:id with { hidden: true })
    const hideRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer alice",
        },
        body: JSON.stringify({ hidden: true }),
      }),
      env as never,
    );
    expect(hideRes.status).toBe(200);
    const hideData = (await hideRes.json()) as any;
    expect(hideData.space.archived).toBe(true);

    // Alice's active sidebar no longer includes direct space
    let listRes = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { Authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(
      ((await listRes.json()) as any).spaces.some(
        (s: any) => s.id === directSpaceId,
      ),
    ).toBe(false);

    // Archived spaces query DOES include it
    const archivedRes = await worker.fetch(
      new Request("https://syntila.test/api/spaces?archived=true", {
        headers: { Authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(
      ((await archivedRes.json()) as any).spaces.some(
        (s: any) => s.id === directSpaceId,
      ),
    ).toBe(true);

    // Get general thread id
    // Create a thread in that Direct Space
    const createThreadRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer bob",
        },
        body: JSON.stringify({ name: "General" }),
      }),
      env as never,
    );
    expect(createThreadRes.status).toBe(201);
    const threadId = ((await createThreadRes.json()) as any).thread.id;

    // Bob sends a message in that Direct Space thread
    const postRes = await worker.fetch(
      new Request(
        `https://syntila.test/api/threads/${threadId}/discussion-messages`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: "Bearer bob",
          },
          body: JSON.stringify({ body: "Hey Alice!" }),
        },
      ),
      env as never,
    );
    expect(postRes.status).toBe(201);

    // Alice's active sidebar now includes the unhidden direct space!
    listRes = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { Authorization: "Bearer alice" },
      }),
      env as never,
    );
    const unhidden = ((await listRes.json()) as any).spaces.find(
      (s: any) => s.id === directSpaceId,
    );
    expect(unhidden).toBeDefined();
    expect(unhidden.archived).toBe(false);
  });

  it("invitation and connection lifecycle emits privacy-safe realtime events with ID payloads only", async () => {
    const { env, sqlite } = createTestEnv();

    // Alice creates personal invitation
    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: "Bearer alice",
        },
        body: JSON.stringify({ userId: "user-bob" }),
      }),
      env as never,
    );
    expect(inviteRes.status).toBe(201);
    const { invitation } = (await inviteRes.json()) as any;

    // Verify people.updated events in realtime_events table
    const inviteEvents = sqlite
      .prepare(
        "SELECT stream_kind, stream_id, event_type, payload_json FROM realtime_events WHERE event_type = 'people.updated'",
      )
      .all() as any[];

    expect(inviteEvents.length).toBeGreaterThanOrEqual(2);
    for (const event of inviteEvents) {
      const payload = JSON.parse(event.payload_json);
      expect(payload).toHaveProperty("entityId");
      // Must not leak email, body, or profile fields
      expect(payload.email).toBeUndefined();
      expect(payload.message).toBeUndefined();
      expect(payload.displayName).toBeUndefined();
      expect(payload.avatarUrl).toBeUndefined();
    }

    // Bob accepts invitation
    await worker.fetch(
      new Request(
        `https://syntila.test/api/people/invitations/${invitation.id}/accept`,
        {
          method: "POST",
          headers: { Authorization: "Bearer bob" },
        },
      ),
      env as never,
    );

    // Alice disconnects connection
    const discRes = await worker.fetch(
      new Request("https://syntila.test/api/people/connections/user-bob", {
        method: "DELETE",
        headers: { Authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(discRes.status).toBe(200);

    const allPeopleEvents = sqlite
      .prepare(
        "SELECT payload_json FROM realtime_events WHERE event_type = 'people.updated'",
      )
      .all() as any[];

    for (const event of allPeopleEvents) {
      const payload = JSON.parse(event.payload_json);
      expect(Object.keys(payload)).toEqual(["entityId"]);
    }
  });
});

describe("Support Space sidebar visibility", () => {
  async function setup() {
    const { sqliteD1 } = await import("./helpers/sqlite-d1.js");
    const { sqlite, db } = sqliteD1();
    const now = new Date().toISOString();
    sqlite.exec(`
      INSERT INTO users (id, email, display_name, avatar_url, status, created_at, updated_at) VALUES
        ('user-alice','alice@test.com','Alice',NULL,'active','${now}','${now}'),
        ('user-support','support@syntila.test','Support',NULL,'active','${now}','${now}');
    `);
    const users: Record<string, any> = {
      alice: {
        id: "user-alice",
        email: "alice@test.com",
        displayName: "Alice",
        avatarUrl: null,
        status: "active",
      },
      support: {
        id: "user-support",
        email: "support@syntila.test",
        displayName: "Support",
        avatarUrl: null,
        status: "active",
      },
    };
    const env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: db,
      SYNTILA_SUPPORT_ACCOUNT_EMAIL: "support@syntila.test",
      TEST_AUTHENTICATION: async (req: Request) => {
        const u =
          users[req.headers.get("authorization")!.replace("Bearer ", "")];
        return {
          userId: u.id,
          user: u,
          workspaceId: "",
          spaceRoles: {},
          sessionId: `s-${u.id}`,
          clientType: "web",
        };
      },
    };
    const f = (who: string, path: string, init: RequestInit = {}) =>
      worker.fetch(
        new Request(`https://syntila.test${path}`, {
          ...init,
          headers: {
            authorization: `Bearer ${who}`,
            "content-type": "application/json",
          },
        }),
        env as never,
      );
    const ids = async (who: string) =>
      ((await (await f(who, "/api/spaces")).json()) as any).spaces.map(
        (s: any) => s.id,
      );
    const res = await f("alice", "/api/people/support", { method: "POST" });
    const { spaceId } = (await res.json()) as { spaceId: string };
    return { sqlite, f, ids, spaceId };
  }

  it("is hidden by default, stays hidden after open and replies, and follows the user's setting", async () => {
    const { sqlite, f, ids, spaceId } = await setup();
    expect(await ids("alice")).not.toContain(spaceId);
    await f("alice", `/api/spaces/${spaceId}`); // opening does not unhide
    expect(await ids("alice")).not.toContain(spaceId);

    expect(
      (
        await f("alice", `/api/spaces/${spaceId}`, {
          method: "PATCH",
          body: JSON.stringify({ hidden: false }),
        })
      ).status,
    ).toBe(200);
    expect(await ids("alice")).toContain(spaceId);
    expect(
      sqlite
        .prepare(
          "SELECT hidden FROM direct_space_user_state WHERE space_id=? AND user_id='user-alice'",
        )
        .get(spaceId),
    ).toEqual({ hidden: 0 });

    await f("alice", `/api/spaces/${spaceId}`, {
      method: "PATCH",
      body: JSON.stringify({ hidden: true }),
    });
    expect(await ids("alice")).not.toContain(spaceId);
    expect(
      sqlite
        .prepare(
          "SELECT hidden FROM direct_space_user_state WHERE space_id=? AND user_id='user-alice'",
        )
        .get(spaceId),
    ).toEqual({ hidden: 1 });
  });
});
