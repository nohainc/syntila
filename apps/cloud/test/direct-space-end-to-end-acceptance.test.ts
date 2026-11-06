import { describe, expect, it, vi } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

const admission = vi.hoisted(() =>
  vi.fn().mockImplementation(async (_env, _spaceId, _threadId, _workflow, bindings) => {
    const workerId = bindings.chat?.workerId ?? bindings.direct?.workerId;
    return {
      issues: [],
      primaryWorkspaceId: workerId === "worker-a" ? "ws-alice" : workerId === "worker-b" ? "ws-bob" : "ws-charlie",
      workerCatalogRevisions: {},
      workerModelCatalogs: {},
      workerProfiles: {
        chat: { profileId: "profile-chat", profileReleaseVersion: 1 },
        direct: { profileId: "profile-direct", profileReleaseVersion: 1 },
      },
    };
  }),
);
vi.mock("../src/routes/thread-policy.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/routes/thread-policy.js")>();
  return {
    ...actual,
    validateWorkflowWorkerEligibility: admission,
  };
});
vi.mock("../src/routes/handlers.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/routes/handlers.js")>();
  return {
    ...actual,
    validateWorkflowWorkerEligibility: admission,
  };
});

import worker from "../src/index.js";

describe("Direct Spaces End-to-End Acceptance (Phase 10)", () => {
  function createTestEnv() {
    const { sqlite, db } = sqliteD1();
    const now = new Date().toISOString();

    sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at) VALUES
        ('user-alice', 'alice@test.com', 'Alice User', 'active', '${now}', '${now}'),
        ('user-bob', 'bob@test.com', 'Bob User', 'active', '${now}', '${now}'),
        ('user-charlie', 'charlie@test.com', 'Charlie User', 'active', '${now}', '${now}');

      -- Workspaces owned by Alice and Bob
      INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES
        ('ws-alice', 'user-alice', 'Alice WS', 'online', '${now}', '${now}'),
        ('ws-bob', 'user-bob', 'Bob WS', 'online', '${now}', '${now}'),
        ('ws-charlie', 'user-charlie', 'Charlie WS', 'online', '${now}', '${now}');

      -- Account plans (paid for sharing if needed)
      INSERT INTO account_plans (user_id, tier, status, source, created_at, updated_at) VALUES
        ('user-alice', 'paid', 'active', 'manual', '${now}', '${now}'),
        ('user-bob', 'paid', 'active', 'manual', '${now}', '${now}'),
        ('user-charlie', 'free', 'active', 'manual', '${now}', '${now}');

      -- User workflow settings
      INSERT INTO user_workflow_settings (user_id, workspace_id, updated_at) VALUES
        ('user-alice', 'ws-alice', '${now}'),
        ('user-bob', 'ws-bob', '${now}');

      -- Inventory: Alice has worker-a on ws-alice, Bob has worker-b on ws-bob, Charlie has worker-c on ws-charlie
      INSERT INTO workspace_worker_inventory (
        worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
        local_concurrency_limit, revision, created_at, updated_at, last_seen_at
      ) VALUES
        ('worker-a', 'ws-alice', 'user-alice', 'worker-alice-type', 'enabled', 'ready', 1, 1, '${now}', '${now}', '${now}'),
        ('worker-b', 'ws-bob', 'user-bob', 'worker-bob-type', 'enabled', 'ready', 1, 1, '${now}', '${now}', '${now}'),
        ('worker-c', 'ws-charlie', 'user-charlie', 'worker-charlie-type', 'enabled', 'ready', 1, 1, '${now}', '${now}', '${now}');

      -- Worker scheduling
      INSERT INTO worker_scheduling (worker_id, state, updated_by_user_id, updated_at) VALUES
        ('worker-a', 'enabled', 'user-alice', '${now}'),
        ('worker-b', 'enabled', 'user-bob', '${now}'),
        ('worker-c', 'enabled', 'user-charlie', '${now}');

      -- User workflow configurations
      INSERT INTO user_workflow_configurations (user_id, workspace_id, workflow_id, schema_version, configuration_json, updated_at) VALUES
        ('user-alice', 'ws-alice', 'chat', 1, '{"schemaVersion":1,"workflowId":"chat","enabled":true,"defaults":{"worker":"worker-a"},"stepOverrides":{}}', '${now}'),
        ('user-alice', 'ws-alice', 'direct', 1, '{"schemaVersion":1,"workflowId":"direct","enabled":true,"defaults":{"worker":"worker-a"},"stepOverrides":{}}', '${now}'),
        ('user-bob', 'ws-bob', 'chat', 1, '{"schemaVersion":1,"workflowId":"chat","enabled":true,"defaults":{"worker":"worker-b"},"stepOverrides":{}}', '${now}'),
        ('user-bob', 'ws-bob', 'direct', 1, '{"schemaVersion":1,"workflowId":"direct","enabled":true,"defaults":{"worker":"worker-b"},"stepOverrides":{}}', '${now}');
    `);

    const users: Record<string, { id: string; email: string; displayName: string; status: string }> = {
      alice: { id: "user-alice", email: "alice@test.com", displayName: "Alice User", status: "active" },
      bob: { id: "user-bob", email: "bob@test.com", displayName: "Bob User", status: "active" },
      charlie: { id: "user-charlie", email: "charlie@test.com", displayName: "Charlie User", status: "active" },
    };

    const env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: db,
      SYNTILA_RUN_WORKFLOW: {
        create: async () => ({ status: async () => ({ status: "queued" }) }),
        get: async () => ({ status: async () => ({ status: "queued" }) }),
      },
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

  it("Scenario A — New personal connection: email invite, acceptance, messaging, multi-threading", async () => {
    const { env, sqlite } = createTestEnv();

    // 1. Alice opens People -> empty connections
    const alicePeopleBefore = await worker.fetch(
      new Request("https://syntila.test/api/people", {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(alicePeopleBefore.status).toBe(200);

    // 2. Alice invites Bob by email
    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ email: "bob@test.com" }),
      }),
      env as never,
    );
    expect(inviteRes.status).toBe(201);
    const { invitation } = (await inviteRes.json()) as { invitation: { id: string } };

    // 3. Bob sees the incoming invitation
    const bobInvitations = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const bobInvJson = (await bobInvitations.json()) as { incoming: Array<{ id: string; inviterDisplayName: string }> };
    expect(bobInvJson.incoming.some((inv) => inv.id === invitation.id)).toBe(true);

    // 4. Bob accepts the invitation
    const acceptRes = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${invitation.id}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(acceptRes.status).toBe(200);
    const { directSpaceId } = (await acceptRes.json()) as { directSpaceId: string };

    // 5. One Direct Space and one General Thread exist
    const directSpaces = sqlite.prepare(
      "SELECT space_id, user_low_id, user_high_id, general_thread_id FROM direct_spaces WHERE space_id = ?"
    ).all(directSpaceId) as Array<{ space_id: string; user_low_id: string; user_high_id: string; general_thread_id: string }>;
    expect(directSpaces.length).toBe(1);
    const generalThreadId = directSpaces[0]!.general_thread_id;
    expect(generalThreadId).toBeTruthy();

    const generalThread = sqlite.prepare(
      "SELECT id, is_general, name FROM threads WHERE id = ?"
    ).get(generalThreadId) as { id: string; is_general: number; name: string };
    expect(generalThread.is_general).toBe(1);
    expect(generalThread.name).toBe("General");

    // 6. Both Alice and Bob open the same conversation
    const aliceGetSpace = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(aliceGetSpace.status).toBe(200);

    const bobGetSpace = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(bobGetSpace.status).toBe(200);

    // 7. Both exchange messages in General Thread
    const aliceMsg = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ body: "Hello Bob! Welcome to our direct space." }),
      }),
      env as never,
    );
    expect(aliceMsg.status).toBe(201);

    const bobMsg = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ body: "Hi Alice! Great to connect." }),
      }),
      env as never,
    );
    expect(bobMsg.status).toBe(201);

    // 8. Each creates a different topic Thread
    const aliceThreadRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ name: "Project Architecture" }),
      }),
      env as never,
    );
    expect(aliceThreadRes.status).toBe(201);
    const { thread: aliceTopicThread } = (await aliceThreadRes.json()) as { thread: { id: string } };

    const bobThreadRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ name: "Release Planning" }),
      }),
      env as never,
    );
    expect(bobThreadRes.status).toBe(201);
    const { thread: bobTopicThread } = (await bobThreadRes.json()) as { thread: { id: string } };

    // 9. Both see both Threads
    const aliceThreadsList = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    const aliceThreadsJson = (await aliceThreadsList.json()) as { threads: Array<{ id: string; name: string }> };
    expect(aliceThreadsJson.threads.some((t) => t.id === aliceTopicThread.id)).toBe(true);
    expect(aliceThreadsJson.threads.some((t) => t.id === bobTopicThread.id)).toBe(true);

    const bobThreadsList = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const bobThreadsJson = (await bobThreadsList.json()) as { threads: Array<{ id: string; name: string }> };
    expect(bobThreadsJson.threads.some((t) => t.id === aliceTopicThread.id)).toBe(true);
    expect(bobThreadsJson.threads.some((t) => t.id === bobTopicThread.id)).toBe(true);
  });

  it("Scenario B — AI collaboration: symmetric execution, visibility, separate context, unauthorized isolation", async () => {
    const { env, sqlite } = createTestEnv();

    // Connect Alice and Bob
    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ email: "bob@test.com" }),
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
    const generalThread = sqlite.prepare("SELECT general_thread_id FROM direct_spaces WHERE space_id = ?").get(directSpaceId) as { general_thread_id: string };

    // Alice configures and executes Chat with her own AI in General Thread
    const aliceWorkRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThread.general_thread_id}/work-requests`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({
          workflowId: "chat",
          executionSelection: { workerId: "worker-a" },
          input: { originalRequest: "Can you analyze this system design?" },
        }),
      }),
      env as never,
    );
    expect(aliceWorkRes.status).toBe(202);
    const { workRequest: aliceWork } = (await aliceWorkRes.json()) as { workRequest: { id: string } };

    // AI answer message is recorded in General Thread
    await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThread.general_thread_id}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({
          body: "AI: The architecture satisfies all scalability constraints.",
          kind: "ai_answer",
          workRequestId: aliceWork.id,
          workerDisplayName: "Claude Assistant",
        }),
      }),
      env as never,
    );

    // Bob sees Alice's request and AI answer
    const bobMsgs = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThread.general_thread_id}/discussion-messages`, {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const bobMsgsJson = (await bobMsgs.json()) as { messages: Array<{ body: string; kind?: string }> };
    expect(bobMsgsJson.messages.some((m) => m.body.includes("The architecture satisfies"))).toBe(true);

    // Bob asks his own Worker a follow-up using Bob's workspace
    const bobWorkRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThread.general_thread_id}/work-requests`, {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({
          workflowId: "chat",
          executionSelection: { workerId: "worker-b" },
          input: { originalRequest: "Follow up: what about failure modes?" },
        }),
      }),
      env as never,
    );
    expect(bobWorkRes.status).toBe(202);

    // Alice creates a separate Research Thread
    const researchThreadRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ name: "Deep Research" }),
      }),
      env as never,
    );
    const { thread: researchThread } = (await researchThreadRes.json()) as { thread: { id: string } };

    // Research thread has separate context
    const researchWorkRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${researchThread.id}/work-requests`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({
          workflowId: "chat",
          executionSelection: { workerId: "worker-a" },
          input: { originalRequest: "Start deep research" },
        }),
      }),
      env as never,
    );
    expect(researchWorkRes.status).toBe(202);

    // Unauthorized execution: Alice cannot execute using Charlie's workspace / worker
    const unauthorizedRes = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThread.general_thread_id}/work-requests`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({
          workflowId: "chat",
          executionSelection: { workerId: "worker-c" },
          input: { originalRequest: "Attempt unauthorized execution" },
        }),
      }),
      env as never,
    );
    expect([400, 403, 422]).toContain(unauthorizedRes.status);
  });

  it("Scenario C — Security: third-party invitation rejected, direct read rejected, destructive deletion blocked, hiding isolated", async () => {
    const { env, sqlite } = createTestEnv();

    // Establish Direct Space between Alice and Bob
    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ email: "bob@test.com" }),
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
    const generalThread = sqlite.prepare("SELECT general_thread_id FROM direct_spaces WHERE space_id = ?").get(directSpaceId) as { general_thread_id: string };

    // 1. Alice attempts to invite Charlie into Direct Space -> Rejected with 403
    const inviteCharlie = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/invitations`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ email: "charlie@test.com", role: "collaborator" }),
      }),
      env as never,
    );
    expect(inviteCharlie.status).toBe(403);

    // 2. Charlie attempts to read Direct Space directly -> Rejected with 404/403
    const charlieReadSpace = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { authorization: "Bearer charlie" },
      }),
      env as never,
    );
    expect([403, 404]).toContain(charlieReadSpace.status);

    // 3. Charlie attempts to read threads in Direct Space -> Rejected
    const charlieReadThreads = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        headers: { authorization: "Bearer charlie" },
      }),
      env as never,
    );
    expect([403, 404]).toContain(charlieReadThreads.status);

    // 4. Charlie attempts to read discussion messages in General Thread -> Rejected
    const charlieReadMsgs = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThread.general_thread_id}/discussion-messages`, {
        headers: { authorization: "Bearer charlie" },
      }),
      env as never,
    );
    expect([403, 404]).toContain(charlieReadMsgs.status);

    // 5. Alice tries to delete the Direct Space with DELETE /api/spaces/:id -> Cloud rejects destructive delete with 403
    const deleteRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        method: "DELETE",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(deleteRes.status).toBe(403);
    expect((await deleteRes.json() as { error: string }).error).toBe("Direct Spaces cannot be deleted directly");

    // 6. Alice hides the conversation
    const hideRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        method: "PATCH",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ hidden: true }),
      }),
      env as never,
    );
    expect(hideRes.status).toBe(200);

    // Alice active spaces list does not show it
    const aliceSpaces = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    const aliceSpacesJson = (await aliceSpaces.json()) as { spaces: Array<{ id: string }> };
    expect(aliceSpacesJson.spaces.some((s) => s.id === directSpaceId)).toBe(false);

    // Bob's conversation remains completely intact and active
    const bobSpaces = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const bobSpacesJson = (await bobSpaces.json()) as { spaces: Array<{ id: string }> };
    // Open for Bob
    await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}`, {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const bobActiveSpaces = await worker.fetch(
      new Request("https://syntila.test/api/spaces", {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(((await bobActiveSpaces.json()) as { spaces: Array<{ id: string }> }).spaces.some((s) => s.id === directSpaceId)).toBe(true);
  });

  it("Scenario D — Existing collaboration: Group Space remains unchanged through connect and disconnect", async () => {
    const { env, sqlite } = createTestEnv();
    const now = new Date().toISOString();

    // Alice and Bob share a normal Group Space
    sqlite.exec(`
      INSERT INTO spaces (id, name, kind, owner_user_id, created_at, updated_at) VALUES
        ('group-project', 'Shared Project', 'group', 'user-alice', '${now}', '${now}');
      INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES
        ('sm-a', 'group-project', 'user-alice', 'owner', '${now}', '${now}'),
        ('sm-b', 'group-project', 'user-bob', 'collaborator', '${now}', '${now}');
      INSERT INTO threads (id, space_id, name, status, lead_user_id, created_at, updated_at) VALUES
        ('th-project', 'group-project', 'General Project', 'active', 'user-alice', '${now}', '${now}');
    `);

    // Verify collaborator relationship is visible
    const peopleAlice = await worker.fetch(
      new Request("https://syntila.test/api/people", {
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    const peopleAliceJson = (await peopleAlice.json()) as { people: Array<{ userId: string; connectionStatus: string; sharedSpaces: Array<{ id: string }> }> };
    const bobPerson = peopleAliceJson.people.find((p) => p.userId === "user-bob");
    expect(bobPerson).toBeDefined();
    expect(bobPerson?.connectionStatus).toBe("collaborator");
    expect(bobPerson?.sharedSpaces.some((s) => s.id === "group-project")).toBe(true);

    // Alice sends Bob a personal connection invitation using stable userId
    const inviteRes = await worker.fetch(
      new Request("https://syntila.test/api/people/invitations", {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ userId: "user-bob" }),
      }),
      env as never,
    );
    expect(inviteRes.status).toBe(201);
    const { invitation } = (await inviteRes.json()) as { invitation: { id: string } };

    // Bob accepts
    const acceptRes = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${invitation.id}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(acceptRes.status).toBe(200);

    // Group Space remains untouched
    const groupSpaceAfter = sqlite.prepare("SELECT kind, owner_user_id FROM spaces WHERE id = 'group-project'").get() as { kind: string; owner_user_id: string };
    expect(groupSpaceAfter.kind).toBe("group");
    expect(groupSpaceAfter.owner_user_id).toBe("user-alice");

    const groupMemberships = sqlite.prepare("SELECT user_id, role FROM space_memberships WHERE space_id = 'group-project' ORDER BY user_id").all() as Array<{ user_id: string; role: string }>;
    expect(groupMemberships).toEqual([
      { user_id: "user-alice", role: "owner" },
      { user_id: "user-bob", role: "collaborator" },
    ]);

    // Alice removes the personal connection (disconnect)
    const disconnectRes = await worker.fetch(
      new Request("https://syntila.test/api/people/connections/user-bob/disconnect", {
        method: "POST",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(disconnectRes.status).toBe(200);

    // Group Space memberships and thread access remain completely unaffected
    const groupMembershipsAfterDisconnect = sqlite.prepare("SELECT user_id, role FROM space_memberships WHERE space_id = 'group-project' ORDER BY user_id").all() as Array<{ user_id: string; role: string }>;
    expect(groupMembershipsAfterDisconnect).toEqual([
      { user_id: "user-alice", role: "owner" },
      { user_id: "user-bob", role: "collaborator" },
    ]);

    const bobGroupRead = await worker.fetch(
      new Request("https://syntila.test/api/spaces/group-project/threads", {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(bobGroupRead.status).toBe(200);
  });

  it("Scenario E — Reliability: racing invitations establish one canonical connection and stable Direct Space", async () => {
    const { env, sqlite } = createTestEnv();

    // Alice and Bob both send invitations to each other simultaneously
    const [inviteAlice, inviteBob] = await Promise.all([
      worker.fetch(
        new Request("https://syntila.test/api/people/invitations", {
          method: "POST",
          headers: { authorization: "Bearer alice", "content-type": "application/json" },
          body: JSON.stringify({ email: "bob@test.com" }),
        }),
        env as never,
      ),
      worker.fetch(
        new Request("https://syntila.test/api/people/invitations", {
          method: "POST",
          headers: { authorization: "Bearer bob", "content-type": "application/json" },
          body: JSON.stringify({ email: "alice@test.com" }),
        }),
        env as never,
      ),
    ]);

    expect([200, 201]).toContain(inviteAlice.status);
    expect([200, 201]).toContain(inviteBob.status);
    const bodyA = (await inviteAlice.json()) as { invitation?: { id: string } };
    const bodyB = (await inviteBob.json()) as { invitation?: { id: string } };
    const invAId = bodyA.invitation?.id;
    const invBId = bodyB.invitation?.id;

    // Bob accepts Alice's invitation (idempotent if already connected via race)
    const acceptA = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${invAId}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(acceptA.status).toBe(200);
    const { directSpaceId: spaceId1 } = (await acceptA.json()) as { directSpaceId: string };

    // Alice also accepts (or retries)
    const acceptB = await worker.fetch(
      new Request(`https://syntila.test/api/people/invitations/${invBId}/accept`, {
        method: "POST",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(acceptB.status).toBe(200);
    const { directSpaceId: spaceId2 } = (await acceptB.json()) as { directSpaceId: string };

    // Both must resolve to the identical Direct Space ID!
    expect(spaceId1).toBe(spaceId2);

    // Exactly one Direct Space record exists in the database
    const directSpaces = sqlite.prepare(
      "SELECT space_id FROM direct_spaces WHERE (user_low_id = 'user-alice' AND user_high_id = 'user-bob') OR (user_low_id = 'user-bob' AND user_high_id = 'user-alice')"
    ).all() as Array<{ space_id: string }>;
    expect(directSpaces.length).toBe(1);

    // Exactly one active connection exists in person_connections
    const connections = sqlite.prepare(
      "SELECT status, direct_space_id FROM person_connections WHERE user_low_id = 'user-alice' AND user_high_id = 'user-bob'"
    ).all() as Array<{ status: string; direct_space_id: string }>;
    expect(connections.length).toBe(1);
    expect(connections[0]!.status).toBe("connected");
    expect(connections[0]!.direct_space_id).toBe(spaceId1);

    // Post message and verify stable persistence across queries
    const generalThread = sqlite.prepare("SELECT general_thread_id FROM direct_spaces WHERE space_id = ?").get(spaceId1) as { general_thread_id: string };
    await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThread.general_thread_id}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ body: "Idempotent thread check" }),
      }),
      env as never,
    );

    const msgsList = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThread.general_thread_id}/discussion-messages`, {
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    const msgsJson = (await msgsList.json()) as { messages: Array<{ body: string }> };
    expect(msgsJson.messages.length).toBe(1);
    expect(msgsJson.messages[0]!.body).toBe("Idempotent thread check");
  });
});
