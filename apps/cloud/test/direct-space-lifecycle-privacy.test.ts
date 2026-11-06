import { describe, expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import worker from "../src/index.js";
import { handleAccountDeletionCleanup } from "../src/auth/better-auth.js";

describe("Direct Space Lifecycle, Privacy, and Account Deletion (Phase 9)", () => {
  function createTestEnv() {
    const { sqlite, db } = sqliteD1();
    const now = new Date().toISOString();

    sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at) VALUES
        ('user-alice', 'alice@test.com', 'Alice User', 'active', '${now}', '${now}'),
        ('user-bob', 'bob@test.com', 'Bob User', 'active', '${now}', '${now}'),
        ('user-charlie', 'charlie@test.com', 'Charlie User', 'active', '${now}', '${now}');

      -- Known collaborator relationship between Alice and Bob
      INSERT INTO people_relationships (user_low_id, user_high_id, established_at) VALUES
        ('user-alice', 'user-bob', '${now}');

      -- Workspaces owned by Alice and Bob
      INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES
        ('ws-alice', 'user-alice', 'Alice WS', 'online', '${now}', '${now}'),
        ('ws-bob', 'user-bob', 'Bob WS', 'online', '${now}', '${now}');
    `);

    const users: Record<string, { id: string; email: string; displayName: string; status: string }> = {
      alice: { id: "user-alice", email: "alice@test.com", displayName: "Alice User", status: "active" },
      bob: { id: "user-bob", email: "bob@test.com", displayName: "Bob User", status: "active" },
      charlie: { id: "user-charlie", email: "charlie@test.com", displayName: "Charlie User", status: "active" },
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

  async function establishDirectSpace(env: unknown, sqlite: any) {
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
    const row = sqlite.prepare("SELECT general_thread_id FROM direct_spaces WHERE space_id = ?").get(directSpaceId) as {
      general_thread_id: string;
    };
    return { directSpaceId, generalThreadId: row.general_thread_id };
  }

  it("9.1 Hide & unhide: Alice hides conversation; Bob still sees it; Bob's new message unhides it for Alice", async () => {
    const { env, sqlite } = createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env, sqlite);

    // Alice opens the direct space so it is active
    await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );

    // Initial check: visible in Alice's spaces list
    const listBeforeAlice = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    const aliceListJson1 = (await listBeforeAlice.json()) as { spaces: Array<{ id: string }> };
    expect(aliceListJson1.spaces.some((s) => s.id === directSpaceId)).toBe(true);

    // Alice hides the conversation
    const hideRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        method: "PATCH",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ hidden: true }),
      }),
      env as never,
    );
    expect(hideRes.status).toBe(200);

    // Alice no longer sees it in active spaces
    const listAfterAlice = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    const aliceListJson2 = (await listAfterAlice.json()) as { spaces: Array<{ id: string }> };
    expect(aliceListJson2.spaces.some((s) => s.id === directSpaceId)).toBe(false);

    // Bob opens and still sees it
    await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const listBob = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const bobListJson = (await listBob.json()) as { spaces: Array<{ id: string }> };
    expect(bobListJson.spaces.some((s) => s.id === directSpaceId)).toBe(true);

    // Bob sends a new discussion message to the Direct Space
    const msgRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ body: "Hey Alice, are you there?" }),
      }),
      env as never,
    );
    expect(msgRes.status).toBe(201);

    // Conversation is automatically unhidden for Alice
    const listAfterMsg = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    const aliceListJson3 = (await listAfterMsg.json()) as { spaces: Array<{ id: string }> };
    expect(aliceListJson3.spaces.some((s) => s.id === directSpaceId)).toBe(true);
  });

  it("9.2 & 9.3 Contact removal & destructive deletion prevention: Group Spaces unchanged, generic delete blocked, messaging frozen", async () => {
    const { env, sqlite } = createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env, sqlite);

    // Put Alice and Bob into a shared Group Space
    const now = new Date().toISOString();
    sqlite.exec(`
      INSERT INTO spaces (id, name, kind, owner_user_id, created_at, updated_at) VALUES
        ('space-shared-team', 'Team Project', 'group', 'user-alice', '${now}', '${now}');
      INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES
        ('sm-alice-team', 'space-shared-team', 'user-alice', 'owner', '${now}', '${now}'),
        ('sm-bob-team', 'space-shared-team', 'user-bob', 'collaborator', '${now}', '${now}');
    `);

    // 1. Generic DELETE /api/spaces/:id on Direct Space is rejected with 403
    const deleteAlice = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        method: "DELETE",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(deleteAlice.status).toBe(403);
    expect((await deleteAlice.json() as { error: string }).error).toBe("Direct Spaces cannot be deleted directly");

    const deleteBob = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        method: "DELETE",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(deleteBob.status).toBe(403);

    // 2. Alice removes connection (disconnects)
    const disconnectRes = await worker.fetch(
      new Request("https://syntila.test/api/people/connections/user-bob/disconnect", {
        method: "POST",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(disconnectRes.status).toBe(200);

    // 3. Shared Group Space membership remains completely intact
    const sharedMembers = sqlite.prepare(
      "SELECT user_id FROM space_memberships WHERE space_id = 'space-shared-team' ORDER BY user_id ASC"
    ).all() as Array<{ user_id: string }>;
    expect(sharedMembers.map((m) => m.user_id)).toEqual(["user-alice", "user-bob"]);

    // 4. In People list, Bob is still visible as a known collaborator with status 'disconnected'
    const peopleRes = await worker.fetch(
      new Request("https://syntila.test/api/people", {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    const peopleJson = (await peopleRes.json()) as { people: Array<{ userId: string; connectionStatus: string }> };
    const bobInPeople = peopleJson.people.find((p) => p.userId === "user-bob");
    expect(bobInPeople).toBeDefined();
    expect(bobInPeople?.connectionStatus).toBe("disconnected");

    // 5. Direct messaging is frozen while disconnected -> 403
    const postMsgRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ body: "Trying to message while disconnected" }),
      }),
      env as never,
    );
    expect(postMsgRes.status).toBe(403);
    expect((await postMsgRes.json() as { error: string }).error).toContain("disconnected");

    // 6. Direct AI work creation is frozen while disconnected -> 403
    const postAiRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/work-requests`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({
          spaceId: directSpaceId,
          threadId: generalThreadId,
          prompt: "Run assistant",
        }),
      }),
      env as never,
    );
    expect(postAiRes.status).toBe(403);
    expect((await postAiRes.json() as { error: string }).error).toContain("disconnected");
  });

  it("9.4 Reconnection reuses canonical pair and existing Direct Space without duplicating", async () => {
    const { env, sqlite } = createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env, sqlite);

    // Disconnect
    await worker.fetch(
      new Request("https://syntila.test/api/people/connections/user-bob/disconnect", {
        method: "POST",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );

    // Reconnect: Bob sends invitation to Alice
    const reinviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-alice" }),
      }),
      env as never,
    );
    expect(reinviteRes.status).toBe(201);
    const { invitation } = (await reinviteRes.json()) as { invitation: { id: string } };

    // Alice accepts reconnection
    const acceptRes = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${invitation.id}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(acceptRes.status).toBe(200);
    const acceptJson = (await acceptRes.json()) as { directSpaceId: string };

    // Must reuse exact same Direct Space and General Thread
    expect(acceptJson.directSpaceId).toBe(directSpaceId);

    // Messaging is restored
    const msgRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ body: "We are reconnected!" }),
      }),
      env as never,
    );
    expect(msgRes.status).toBe(201);
  });

  it("9.1 & 9.2 Blocking: Alice blocks Bob; Bob cannot send invitations, messages, or AI requests; unblocking restores capability", async () => {
    const { env, sqlite } = createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env, sqlite);

    // Alice blocks Bob
    const blockRes = await worker.fetch(
      new Request("https://syntila.test/api/people/blocks/user-bob", {
        method: "POST",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(blockRes.status).toBe(200);

    // Alice sees Bob as 'blocked'
    const peopleAlice = await worker.fetch(
      new Request("https://syntila.test/api/people", {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    const peopleAliceJson = (await peopleAlice.json()) as { people: Array<{ userId: string; connectionStatus: string }> };
    expect(peopleAliceJson.people.find((p) => p.userId === "user-bob")?.connectionStatus).toBe("blocked");

    // Bob cannot send invitation to Alice -> 403
    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-alice" }),
      }),
      env as never,
    );
    expect(inviteRes.status).toBe(403);

    // Bob cannot message Alice in Direct Space -> 403
    const msgRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ body: "Are you blocking me?" }),
      }),
      env as never,
    );
    expect(msgRes.status).toBe(403);
    expect((await msgRes.json() as { error: string }).error).toContain("blocked");

    // Bob cannot trigger AI workflow in Direct Space -> 403
    const aiRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/work-requests`, {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({
          spaceId: directSpaceId,
          threadId: generalThreadId,
          prompt: "AI task",
        }),
      }),
      env as never,
    );
    expect(aiRes.status).toBe(403);
    expect((await aiRes.json() as { error: string }).error).toContain("blocked");

    // Alice unblocks Bob
    const unblockRes = await worker.fetch(
      new Request("https://syntila.test/api/people/blocks/user-bob", {
        method: "DELETE",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(unblockRes.status).toBe(200);

    // Bob can now send an invitation to reconnect
    const reinviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-alice" }),
      }),
      env as never,
    );
    expect(reinviteRes.status).toBe(201);
  });

  it("9.5 Account deletion: technical owner deletion safely transfers Direct Space ownership without FK violation or history loss", async () => {
    const { env, db, sqlite, users } = createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env, sqlite);

    // Alice (technical owner) and Bob have message history in Direct Space
    await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ body: "First message from Alice" }),
      }),
      env as never,
    );
    await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ body: "Reply from Bob" }),
      }),
      env as never,
    );

    // Verify initial owner is Alice
    const spaceBefore = sqlite.prepare("SELECT owner_user_id FROM spaces WHERE id = ?").get(directSpaceId) as {
      owner_user_id: string;
    };
    expect(spaceBefore.owner_user_id).toBe("user-alice");

    // Alice deletes her account: handleAccountDeletionCleanup is triggered
    await handleAccountDeletionCleanup(db, "user-alice");

    // Foreign key check: spaces.owner_user_id must now be user-bob
    const spaceAfter = sqlite.prepare("SELECT owner_user_id FROM spaces WHERE id = ?").get(directSpaceId) as {
      owner_user_id: string;
    };
    expect(spaceAfter.owner_user_id).toBe("user-bob");

    // Bob's membership in Direct Space is now 'owner'
    const bobMembership = sqlite.prepare(
      "SELECT role FROM space_memberships WHERE space_id = ? AND user_id = 'user-bob'"
    ).get(directSpaceId) as { role: string };
    expect(bobMembership.role).toBe("owner");

    // Alice's membership is removed
    const aliceMembership = sqlite.prepare(
      "SELECT role FROM space_memberships WHERE space_id = ? AND user_id = 'user-alice'"
    ).get(directSpaceId);
    expect(aliceMembership).toBeUndefined();

    // Alice account transitions to deactivated
    sqlite.exec("UPDATE users SET status = 'deactivated', display_name = 'Deactivated User' WHERE id = 'user-alice'");
    users.alice!.status = "deactivated";

    // Bob can still fetch thread messages and retains all conversation history
    const msgsRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(msgsRes.status).toBe(200);
    const msgsJson = (await msgsRes.json()) as { messages: Array<{ body: string; authorUserId: string }> };
    expect(msgsJson.messages.length).toBe(2);
    expect(msgsJson.messages[0]!.body).toBe("First message from Alice");
    expect(msgsJson.messages[1]!.body).toBe("Reply from Bob");
  });
});
