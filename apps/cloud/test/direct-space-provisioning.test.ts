import { describe, expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import worker from "../src/index.js";

describe("Direct Space & General Thread Provisioning (Phase 3)", () => {
  function createTestEnv() {
    const { sqlite, db } = sqliteD1();
    const now = new Date().toISOString();

    sqlite.exec(`
      INSERT INTO users (id, email, display_name, avatar_url, status, created_at, updated_at) VALUES
        ('user-alice', 'alice@test.com', 'Alice User', 'r2://avatars/user-alice/alice-v1', 'active', '${now}', '${now}'),
        ('user-bob', 'bob@test.com', 'Bob User', 'r2://avatars/user-bob/bob-v1', 'active', '${now}', '${now}'),
        ('user-charlie', 'charlie@test.com', 'Charlie User', NULL, 'active', '${now}', '${now}');

      -- Known collaborator relationship between Alice and Bob
      INSERT INTO people_relationships (user_low_id, user_high_id, established_at) VALUES
        ('user-alice', 'user-bob', '${now}');
    `);

    const users: Record<string, { id: string; email: string; displayName: string; avatarUrl: string | null; status: string }> = {
      alice: { id: "user-alice", email: "alice@test.com", displayName: "Alice User", avatarUrl: "r2://avatars/user-alice/alice-v1", status: "active" },
      bob: { id: "user-bob", email: "bob@test.com", displayName: "Bob User", avatarUrl: "r2://avatars/user-bob/bob-v1", status: "active" },
      charlie: { id: "user-charlie", email: "charlie@test.com", displayName: "Charlie User", avatarUrl: null, status: "active" },
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
            user: { id: "anonymous", email: "anon@test.com", displayName: "Anon", status: "active" },
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

  it("automatically provisions Direct Space and General Thread upon invitation acceptance", async () => {
    const { env, sqlite } = createTestEnv();

    // 1. Alice invites Bob
    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-bob" }),
      }),
      env as never,
    );
    expect(inviteRes.status).toBe(201);
    const inviteBody = (await inviteRes.json()) as { invitation: { id: string } };

    // 2. Bob accepts
    const acceptRes = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${inviteBody.invitation.id}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(acceptRes.status).toBe(200);
    const acceptBody = (await acceptRes.json()) as {
      status: string;
      directSpaceId: string;
      connection: { userLowId: string; userHighId: string; status: string };
    };
    expect(acceptBody.status).toBe("accepted");
    expect(acceptBody.directSpaceId).toMatch(/^space-direct-/);
    expect(acceptBody.connection.status).toBe("connected");
    expect(acceptBody.connection.userLowId).toBe("user-alice");
    expect(acceptBody.connection.userHighId).toBe("user-bob");

    // 3. Verify Database entities
    const directSpaceRow = sqlite.prepare("SELECT * FROM direct_spaces WHERE space_id = ?").get(acceptBody.directSpaceId) as {
      space_id: string;
      user_low_id: string;
      user_high_id: string;
      general_thread_id: string;
    };
    expect(directSpaceRow).toBeDefined();
    expect(directSpaceRow.user_low_id).toBe("user-alice");
    expect(directSpaceRow.user_high_id).toBe("user-bob");
    expect(directSpaceRow.general_thread_id).toMatch(/^thread-gen-/);

    const spaceRow = sqlite.prepare("SELECT * FROM spaces WHERE id = ?").get(acceptBody.directSpaceId) as {
      id: string;
      kind: string;
      name: string;
      owner_user_id: string;
    };
    expect(spaceRow.kind).toBe("direct");
    expect(spaceRow.owner_user_id).toBe("user-alice");

    const threadRow = sqlite.prepare("SELECT * FROM threads WHERE id = ?").get(directSpaceRow.general_thread_id) as {
      id: string;
      space_id: string;
      name: string;
    };
    expect(threadRow.space_id).toBe(acceptBody.directSpaceId);
    expect(threadRow.name).toBe("General");

    const memberships = sqlite.prepare("SELECT user_id, role FROM space_memberships WHERE space_id = ? ORDER BY user_id").all(acceptBody.directSpaceId) as {
      user_id: string;
      role: string;
    }[];
    expect(memberships).toHaveLength(2);
    expect(memberships).toEqual([
      { user_id: "user-alice", role: "owner" },
      { user_id: "user-bob", role: "collaborator" },
    ]);
  });

  it("handles acceptance retry idempotently without duplicating resources", async () => {
    const { env, sqlite } = createTestEnv();

    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-bob" }),
      }),
      env as never,
    );
    const { invitation } = (await inviteRes.json()) as { invitation: { id: string } };

    // Accept first time
    const acceptRes1 = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${invitation.id}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const acceptBody1 = (await acceptRes1.json()) as { directSpaceId: string };

    // Accept second time (retry)
    const acceptRes2 = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${invitation.id}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(acceptRes2.status).toBe(200);
    const acceptBody2 = (await acceptRes2.json()) as { directSpaceId: string };
    expect(acceptBody2.directSpaceId).toBe(acceptBody1.directSpaceId);

    // Verify exactly one Direct Space and one General Thread exist
    const spaceCount = sqlite.prepare("SELECT COUNT(*) AS count FROM spaces WHERE kind = 'direct'").get() as { count: number };
    expect(spaceCount.count).toBe(1);

    const threadCount = sqlite.prepare("SELECT COUNT(*) AS count FROM threads WHERE space_id = ?").get(acceptBody1.directSpaceId) as { count: number };
    expect(threadCount.count).toBe(1);
  });

  it("automatically provisions Direct Space on reciprocal invitations", async () => {
    const { env, sqlite } = createTestEnv();

    // Alice invites Bob
    await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-bob" }),
      }),
      env as never,
    );

    // Bob simultaneously invites Alice -> automatic connection
    const reciprocalRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-alice" }),
      }),
      env as never,
    );
    expect(reciprocalRes.status).toBe(200);
    const body = (await reciprocalRes.json()) as { status: string; directSpaceId: string };
    expect(body.status).toBe("connected");
    expect(body.directSpaceId).toBeDefined();

    const directSpace = sqlite.prepare("SELECT * FROM direct_spaces WHERE space_id = ?").get(body.directSpaceId);
    expect(directSpace).toBeDefined();
  });

  it("safeguards ordinary POST /api/spaces from creating direct spaces manually", async () => {
    const { env } = createTestEnv();

    // Trying to pass kind = 'direct' to normal space creation
    const res = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ name: "Manual Direct", kind: "direct" }),
      }),
      env as never,
    );
    expect(res.status).toBe(400);
    const errorBody = (await res.json()) as { error: string };
    expect(errorBody.error).toBe("Direct Spaces cannot be created manually");

    // Ordinary creation creates kind = 'group'
    const normalRes = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ name: "Group Space" }),
      }),
      env as never,
    );
    expect(normalRes.status).toBe(201);
    const normalBody = (await normalRes.json()) as { space: { kind: string } };
    expect(normalBody.space.kind).toBe("group");
  });

  it("protects General Thread from deletion while allowing custom threads", async () => {
    const { env, sqlite } = createTestEnv();

    // Connect Alice & Bob
    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-bob" }),
      }),
      env as never,
    );
    const { invitation } = (await inviteRes.json()) as { invitation: { id: string } };
    const acceptRes = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${invitation.id}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const { directSpaceId } = (await acceptRes.json()) as { directSpaceId: string };
    const { general_thread_id } = sqlite.prepare("SELECT general_thread_id FROM direct_spaces WHERE space_id = ?").get(directSpaceId) as { general_thread_id: string };

    // Attempt to delete the General Thread -> forbidden 403
    const deleteGenRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${general_thread_id}`, {
        method: "DELETE",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(deleteGenRes.status).toBe(403);
    const errorBody = (await deleteGenRes.json()) as { error: string };
    expect(errorBody.error).toBe("The default General Thread of a Direct Space cannot be deleted");

    // Create a custom thread -> allowed
    const createThreadRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ name: "Custom Project" }),
      }),
      env as never,
    );
    expect(createThreadRes.status).toBe(201);
    const customThread = (await createThreadRes.json()) as { thread: { id: string } };

    // Deleting custom thread -> allowed
    const deleteCustomRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${customThread.thread.id}`, {
        method: "DELETE",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(deleteCustomRes.status).toBe(200);
  });

  it("provides dynamic viewer-specific display identity and peer avatar", async () => {
    const { env, sqlite } = createTestEnv();

    // Connect Alice & Bob
    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-bob" }),
      }),
      env as never,
    );
    const { invitation } = (await inviteRes.json()) as { invitation: { id: string } };
    const acceptRes = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${invitation.id}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const { directSpaceId } = (await acceptRes.json()) as { directSpaceId: string };

    // Alice views the Direct Space -> name is Bob User, avatar is Bob's avatar
    const aliceGetRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(aliceGetRes.status).toBe(200);
    const aliceView = (await aliceGetRes.json()) as { space: { name: string; avatarUrl: string | null; kind: string } };
    expect(aliceView.space.kind).toBe("direct");
    expect(aliceView.space.name).toBe("Bob User");
    expect(aliceView.space.avatarUrl).toContain("/api/users/user-bob/avatar?v=bob-v1");

    // Bob views the Direct Space -> name is Alice User, avatar is Alice's avatar
    const bobGetRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(bobGetRes.status).toBe(200);
    const bobView = (await bobGetRes.json()) as { space: { name: string; avatarUrl: string | null; kind: string } };
    expect(bobView.space.name).toBe("Alice User");
    expect(bobView.space.avatarUrl).toContain("/api/users/user-alice/avatar?v=alice-v1");

    // Alice lists spaces -> Direct Space name is Bob User
    const aliceListRes = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    const aliceList = (await aliceListRes.json()) as { spaces: { id: string; name: string; avatarUrl: string | null }[] };
    const directForAlice = aliceList.spaces.find((s) => s.id === directSpaceId);
    expect(directForAlice?.name).toBe("Bob User");
    expect(directForAlice?.avatarUrl).toContain("/api/users/user-bob/avatar?v=bob-v1");

    // Dynamic profile display name change:
    // Bob updates his profile displayName in users table
    sqlite.prepare("UPDATE users SET display_name = 'Robert (Bob) User' WHERE id = 'user-bob'").run();

    // Alice fetches space again: name is immediately updated to Bob's new display name
    const aliceGetAfterRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    const aliceViewAfter = (await aliceGetAfterRes.json()) as { space: { name: string } };
    expect(aliceViewAfter.space.name).toBe("Robert (Bob) User");

    // Underlying spaces table name was NOT altered
    const rawSpace = sqlite.prepare("SELECT name FROM spaces WHERE id = ?").get(directSpaceId) as { name: string };
    expect(rawSpace.name).toBe("Direct Space");
  });

  it("enforces discovery isolation and access control against unrelated users", async () => {
    const { env } = createTestEnv();

    // Connect Alice & Bob
    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-bob" }),
      }),
      env as never,
    );
    const { invitation } = (await inviteRes.json()) as { invitation: { id: string } };
    const acceptRes = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${invitation.id}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const { directSpaceId } = (await acceptRes.json()) as { directSpaceId: string };

    // Charlie lists spaces -> Direct Space must not appear
    const charlieListRes = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { authorization: "Bearer charlie" },
      }),
      env as never,
    );
    const charlieList = (await charlieListRes.json()) as { spaces: { id: string }[] };
    expect(charlieList.spaces.some((s) => s.id === directSpaceId)).toBe(false);

    // Charlie fetches Direct Space directly -> 404
    const charlieGetRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { authorization: "Bearer charlie" },
      }),
      env as never,
    );
    expect(charlieGetRes.status).toBe(404);

    // Charlie fetches Direct Space threads -> 403 or 404
    const charlieThreadsRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        headers: { authorization: "Bearer charlie" },
      }),
      env as never,
    );
    expect(charlieThreadsRes.status).toBe(403);
  });

  it("restricts administrative owner actions that disrupt the other participant", async () => {
    const { env } = createTestEnv();

    // Connect Alice & Bob
    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-bob" }),
      }),
      env as never,
    );
    const { invitation } = (await inviteRes.json()) as { invitation: { id: string } };
    const acceptRes = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${invitation.id}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const { directSpaceId } = (await acceptRes.json()) as { directSpaceId: string };

    // 1. Inviting a 3rd member -> 403
    const inviteThirdRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/invitations`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-charlie", role: "collaborator" }),
      }),
      env as never,
    );
    expect(inviteThirdRes.status).toBe(403);
    const inviteThirdErr = (await inviteThirdRes.json()) as { error: string };
    expect(inviteThirdErr.error).toBe("Direct Spaces cannot have additional members");

    // 2. Removing member from Direct Space -> 403
    const removeMemberRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/members/user-bob/remove`, {
        method: "POST",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(removeMemberRes.status).toBe(403);
    const removeMemberErr = (await removeMemberRes.json()) as { error: string };
    expect(removeMemberErr.error).toBe("Direct Space members cannot be modified or removed");

    // 3. Changing member role -> 403
    const changeRoleRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/members/user-bob/role`, {
        method: "PATCH",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ role: "viewer" }),
      }),
      env as never,
    );
    expect(changeRoleRes.status).toBe(403);
    const changeRoleErr = (await changeRoleRes.json()) as { error: string };
    expect(changeRoleErr.error).toBe("Direct Space members cannot be modified or removed");

    // 4. Deleting Direct Space directly -> 403
    const deleteSpaceRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        method: "DELETE",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(deleteSpaceRes.status).toBe(403);
    const deleteSpaceErr = (await deleteSpaceRes.json()) as { error: string };
    expect(deleteSpaceErr.error).toBe("Direct Spaces cannot be deleted directly");

    // 5. Renaming Direct Space -> 400
    const renameRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        method: "PATCH",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ name: "Changed Direct Space Name" }),
      }),
      env as never,
    );
    expect(renameRes.status).toBe(400);
    const renameErr = (await renameRes.json()) as { error: string };
    expect(renameErr.error).toBe("Direct Space name cannot be modified");
  });

  it("publishes space.created and people.updated realtime events atomically upon provisioning", async () => {
    const { env, sqlite } = createTestEnv();

    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-bob" }),
      }),
      env as never,
    );
    const { invitation } = (await inviteRes.json()) as { invitation: { id: string } };
    const acceptRes = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${invitation.id}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const { directSpaceId } = (await acceptRes.json()) as { directSpaceId: string };

    // Check realtime_events
    const spaceCreatedEvents = sqlite.prepare("SELECT * FROM realtime_events WHERE event_type = 'space.created' AND space_id = ?").all(directSpaceId);
    expect(spaceCreatedEvents.length).toBeGreaterThan(0);

    const peopleUpdatedEvents = sqlite.prepare("SELECT * FROM realtime_events WHERE event_type = 'people.updated'").all();
    expect(peopleUpdatedEvents.length).toBeGreaterThanOrEqual(2);
  });
});
