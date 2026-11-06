import { describe, expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import worker from "../src/index.js";

describe("Direct Space Security Contract & Authorization Matrix (Phase 4)", () => {
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

  async function establishDirectSpace(env: unknown) {
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
    return { directSpaceId };
  }

  it("4.1 Fixed membership: strictly rejects invitations, member removals, role changes, conversions, and ownership transfers", async () => {
    const { env } = createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);

    // 1. Inviting a third member -> 403
    const inviteRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/invitations`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-charlie", role: "viewer" }),
      }),
      env as never,
    );
    expect(inviteRes.status).toBe(403);
    expect((await inviteRes.json() as { error: string }).error).toBe("Direct Spaces cannot have additional members");

    // 2. Changing participant role -> 403
    const changeRoleRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/members/user-bob/role`, {
        method: "PATCH",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ role: "viewer" }),
      }),
      env as never,
    );
    expect(changeRoleRes.status).toBe(403);
    expect((await changeRoleRes.json() as { error: string }).error).toBe("Direct Space members cannot be modified or removed");

    // 3. Removing the other participant -> 403
    const removeRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/members/user-bob/remove`, {
        method: "POST",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(removeRes.status).toBe(403);
    expect((await removeRes.json() as { error: string }).error).toBe("Direct Space members cannot be modified or removed");

    // 4. Deleting the Space directly -> 403
    const deleteRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        method: "DELETE",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(deleteRes.status).toBe(403);
    expect((await deleteRes.json() as { error: string }).error).toBe("Direct Spaces cannot be deleted directly");

    // 5. Transferring ownership -> 400
    const transferRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        method: "PATCH",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ ownerUserId: "user-bob" }),
      }),
      env as never,
    );
    expect(transferRes.status).toBe(400);
    expect((await transferRes.json() as { error: string }).error).toBe("Space ownership cannot be transferred");

    // 6. Converting Space to group -> 400
    const convertRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        method: "PATCH",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ kind: "group" }),
      }),
      env as never,
    );
    expect(convertRes.status).toBe(400);
    expect((await convertRes.json() as { error: string }).error).toBe("Space kind cannot be changed");

    // 7. Global archive -> 400
    const archiveRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        method: "PATCH",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ archived: true }),
      }),
      env as never,
    );
    expect(archiveRes.status).toBe(400);
    expect((await archiveRes.json() as { error: string }).error).toBe("Direct Spaces cannot be archived globally");
  });

  it("4.2 & 4.4 Symmetric conversation permissions & thread management boundaries", async () => {
    const { env, sqlite } = createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);
    const { general_thread_id } = sqlite.prepare("SELECT general_thread_id FROM direct_spaces WHERE space_id = ?").get(directSpaceId) as { general_thread_id: string };

    // General Thread cannot be renamed
    const renameGenRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${general_thread_id}`, {
        method: "PATCH",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ name: "Renamed General" }),
      }),
      env as never,
    );
    expect(renameGenRes.status).toBe(400);
    expect((await renameGenRes.json() as { error: string }).error).toBe("The default General Thread of a Direct Space cannot be renamed");

    // General Thread cannot be archived
    const archiveGenRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${general_thread_id}`, {
        method: "PATCH",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ status: "archived" }),
      }),
      env as never,
    );
    expect(archiveGenRes.status).toBe(400);
    expect((await archiveGenRes.json() as { error: string }).error).toBe("The default General Thread of a Direct Space cannot be archived");

    // General Thread cannot be deleted
    const deleteGenRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${general_thread_id}`, {
        method: "DELETE",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(deleteGenRes.status).toBe(403);
    expect((await deleteGenRes.json() as { error: string }).error).toBe("The default General Thread of a Direct Space cannot be deleted");

    // Bob creates a custom thread
    const bobCreateRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ name: "Bob's Work" }),
      }),
      env as never,
    );
    expect(bobCreateRes.status).toBe(201);
    const bobThreadId = ((await bobCreateRes.json()) as { thread: { id: string } }).thread.id;

    // Alice attempts to rename Bob's custom thread -> 403 Forbidden
    const aliceRenameBobThread = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${bobThreadId}`, {
        method: "PATCH",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ name: "Alice Renamed Bob's Thread" }),
      }),
      env as never,
    );
    expect(aliceRenameBobThread.status).toBe(403);

    // Bob renames Bob's custom thread -> 200 OK
    const bobRenameSelfThread = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${bobThreadId}`, {
        method: "PATCH",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ name: "Bob's Renamed Work" }),
      }),
      env as never,
    );
    expect(bobRenameSelfThread.status).toBe(200);

    // Alice attempts to delete Bob's custom thread -> 403 Forbidden
    const aliceDeleteBobThread = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${bobThreadId}`, {
        method: "DELETE",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(aliceDeleteBobThread.status).toBe(403);

    // Bob deletes Bob's custom thread -> 200 OK
    const bobDeleteSelfThread = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${bobThreadId}`, {
        method: "DELETE",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(bobDeleteSelfThread.status).toBe(200);
  });

  it("4.4 Message removal: technical owner cannot delete the other participant's messages", async () => {
    const { env, sqlite } = createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);
    const { general_thread_id } = sqlite.prepare("SELECT general_thread_id FROM direct_spaces WHERE space_id = ?").get(directSpaceId) as { general_thread_id: string };

    // Bob sends a message
    const bobSendRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${general_thread_id}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ body: "Hello from Bob" }),
      }),
      env as never,
    );
    expect(bobSendRes.status).toBe(201);
    const bobMsgId = ((await bobSendRes.json()) as { message: { id: string } }).message.id;

    // Alice (technical owner) attempts to delete Bob's message -> 403 Forbidden
    const aliceDeleteBobMsg = await worker.fetch(
      new Request(`https://syntila.test/api/discussion-messages/${bobMsgId}`, {
        method: "DELETE",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(aliceDeleteBobMsg.status).toBe(403);
    expect((await aliceDeleteBobMsg.json() as { error: string }).error).toBe("In a Direct Space, only the message author may delete their message");

    // Bob deletes his own message -> 200 OK
    const bobDeleteOwnMsg = await worker.fetch(
      new Request(`https://syntila.test/api/discussion-messages/${bobMsgId}`, {
        method: "DELETE",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(bobDeleteOwnMsg.status).toBe(200);
  });

  it("4.3 & 4.5 Workspace & tool call authorization boundaries", async () => {
    const { env } = createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);

    // Attempting to attach a Space-wide execution Workspace to a Direct Space -> 403
    const attachWsRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/workflow-workspace`, {
        method: "PUT",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ workspaceId: "ws-alice" }),
      }),
      env as never,
    );
    expect(attachWsRes.status).toBe(403);
    expect((await attachWsRes.json() as { error: string }).error).toContain("Direct Spaces do not support Space-level Workspace attachments");
  });

  it("disconnected personal connection becomes read-only and rejects new mutations", async () => {
    const { env, sqlite } = createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);
    const { general_thread_id } = sqlite.prepare("SELECT general_thread_id FROM direct_spaces WHERE space_id = ?").get(directSpaceId) as { general_thread_id: string };

    // Disconnect connection
    sqlite.prepare("UPDATE person_connections SET status = 'disconnected', disconnected_at = 'now' WHERE direct_space_id = ?").run(directSpaceId);

    // Reading messages is still allowed for audit retention
    const readRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${general_thread_id}/discussion-messages`, {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(readRes.status).toBe(200);

    // Sending new message is rejected -> 403
    const postRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${general_thread_id}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ body: "Should fail" }),
      }),
      env as never,
    );
    expect(postRes.status).toBe(403);
    expect((await postRes.json() as { error: string }).error).toBe("This personal conversation is disconnected and read-only");

    // Creating new thread is rejected -> 403
    const newThreadRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ name: "New Thread" }),
      }),
      env as never,
    );
    expect(newThreadRes.status).toBe(403);
    expect((await newThreadRes.json() as { error: string }).error).toBe("This personal conversation is disconnected and read-only");
  });

  it("isolates unrelated users (Charlie) completely from Direct Spaces", async () => {
    const { env } = createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);

    // Charlie lists spaces -> Direct Space is not included
    const listRes = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { authorization: "Bearer charlie" },
      }),
      env as never,
    );
    const listBody = (await listRes.json()) as { spaces: { id: string }[] };
    expect(listBody.spaces.some((s) => s.id === directSpaceId)).toBe(false);

    // Charlie fetches Direct Space -> 404
    const getRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { authorization: "Bearer charlie" },
      }),
      env as never,
    );
    expect(getRes.status).toBe(404);

    // Charlie tries to post in Direct Space -> 404 or 403
    const postRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        method: "POST",
        headers: { authorization: "Bearer charlie", "content-type": "application/json" },
        body: JSON.stringify({ name: "Intruder Thread" }),
      }),
      env as never,
    );
    expect(postRes.status).toBe(403);
  });
});
