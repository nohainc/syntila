import { describe, expect, it, vi } from "vitest";
import { BUILTIN_WORKFLOWS } from "@syntila/core";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

const admission = vi.hoisted(() =>
  vi.fn().mockImplementation(async (_env, _spaceId, _threadId, _workflow, bindings) => {
    const workerId = bindings.chat?.workerId ?? bindings.direct?.workerId;
    return {
      issues: [],
      primaryWorkspaceId: workerId === "worker-a" ? "ws-alice" : "ws-bob",
      workerCatalogRevisions: {},
      workerModelCatalogs: {},
      workerProfiles: {},
    };
  }),
);
vi.mock("../src/routes/handlers.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/routes/handlers.js")>();
  return {
    ...actual,
    validateWorkflowWorkerEligibility: admission,
  };
});

import worker from "../src/index.js";
import { resolveWorkflowExecutionBindings } from "../src/routes/workflow-execution-configuration.js";
import { threadConversationId } from "../src/routes/conversations.js";

describe("Direct Space AI Workers, Workflows, and Workspaces (Phase 7)", () => {
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

      -- Account plans (paid for sharing if needed)
      INSERT INTO account_plans (user_id, tier, status, source, created_at, updated_at) VALUES
        ('user-alice', 'paid', 'active', 'manual', '${now}', '${now}'),
        ('user-bob', 'paid', 'active', 'manual', '${now}', '${now}'),
        ('user-charlie', 'free', 'active', 'manual', '${now}', '${now}');

      -- User workflow settings
      INSERT INTO user_workflow_settings (user_id, workspace_id, updated_at) VALUES
        ('user-alice', 'ws-alice', '${now}'),
        ('user-bob', 'ws-bob', '${now}');

      -- Inventory: Alice has worker-a on ws-alice, Bob has worker-b on ws-bob
      INSERT INTO workspace_worker_inventory (
        worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
        local_concurrency_limit, revision, created_at, updated_at, last_seen_at
      ) VALUES
        ('worker-a', 'ws-alice', 'user-alice', 'worker-alice-type', 'enabled', 'ready', 1, 1, '${now}', '${now}', '${now}'),
        ('worker-b', 'ws-bob', 'user-bob', 'worker-bob-type', 'enabled', 'ready', 1, 1, '${now}', '${now}', '${now}');

      -- Worker scheduling
      INSERT INTO worker_scheduling (worker_id, state, updated_by_user_id, updated_at) VALUES
        ('worker-a', 'enabled', 'user-alice', '${now}'),
        ('worker-b', 'enabled', 'user-bob', '${now}');

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
    const ds = await (env as { SYNTILA_DB: D1Database }).SYNTILA_DB.prepare(
      "SELECT general_thread_id AS generalThreadId FROM direct_spaces WHERE space_id = ?1",
    )
      .bind(directSpaceId)
      .first<{ generalThreadId: string }>();
    return { directSpaceId, generalThreadId: ds!.generalThreadId };
  }

  it("7.1 Human messaging: both participants share discussion messages and see each other's messages", async () => {
    const { env } = createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env);

    // Alice posts a message
    const alicePost = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ body: "Hello Bob from Alice!" }),
      }),
      env as never,
    );
    expect(alicePost.status).toBe(201);

    // Bob posts a message
    const bobPost = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        method: "POST",
        headers: { authorization: "Bearer bob", "content-type": "application/json" },
        body: JSON.stringify({ body: "Hello Alice from Bob!" }),
      }),
      env as never,
    );
    expect(bobPost.status).toBe(201);

    // Alice lists messages: sees both
    const aliceList = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        method: "GET",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(aliceList.status).toBe(200);
    const aliceMessages = (await aliceList.json() as { messages: Array<{ body: string; authorUserId: string }> }).messages;
    expect(aliceMessages.map((m) => m.body)).toEqual(["Hello Bob from Alice!", "Hello Alice from Bob!"]);

    // Bob lists messages: sees both identically
    const bobList = await worker.fetch(
      new Request(`https://syntila.test/api/threads/${generalThreadId}/discussion-messages`, {
        method: "GET",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(bobList.status).toBe(200);
    const bobMessages = (await bobList.json() as { messages: Array<{ body: string; authorUserId: string }> }).messages;
    expect(bobMessages.map((m) => m.body)).toEqual(["Hello Bob from Alice!", "Hello Alice from Bob!"]);
  });

  it("7.2 & 7.3 Per-participant workflow configurations & workspace resolution", async () => {
    const { env } = createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);

    // Alice queries workflow configurations in Direct Space: gets Alice's configurations
    const aliceConfigsRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/workflow-configurations`, {
        method: "GET",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(aliceConfigsRes.status).toBe(200);
    const aliceConfigs = (await aliceConfigsRes.json()) as { configurations: Array<{ defaults?: { worker?: string } }> };
    expect(aliceConfigs.configurations.some((c) => c.defaults?.worker === "worker-a")).toBe(true);
    expect(aliceConfigs.configurations.some((c) => c.defaults?.worker === "worker-b")).toBe(false);

    // Bob queries workflow configurations in Direct Space: gets Bob's configurations
    const bobConfigsRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/workflow-configurations`, {
        method: "GET",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(bobConfigsRes.status).toBe(200);
    const bobConfigs = (await bobConfigsRes.json()) as { configurations: Array<{ defaults?: { worker?: string } }> };
    expect(bobConfigs.configurations.some((c) => c.defaults?.worker === "worker-b")).toBe(true);
    expect(bobConfigs.configurations.some((c) => c.defaults?.worker === "worker-a")).toBe(false);

    // Alice queries workflow workspace in Direct Space: gets Alice's personal workspace
    const aliceWsRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/workflow-workspace`, {
        method: "GET",
        headers: { authorization: "Bearer alice" },
      }),
      env as never,
    );
    expect(aliceWsRes.status).toBe(200);
    const aliceWs = (await aliceWsRes.json()) as { workspaceId: string };
    expect(aliceWs.workspaceId).toBe("ws-alice");

    // Bob queries workflow workspace in Direct Space: gets Bob's personal workspace
    const bobWsRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/workflow-workspace`, {
        method: "GET",
        headers: { authorization: "Bearer bob" },
      }),
      env as never,
    );
    expect(bobWsRes.status).toBe(200);
    const bobWs = (await bobWsRes.json()) as { workspaceId: string };
    expect(bobWs.workspaceId).toBe("ws-bob");

    // Attempting to set space-level workflow overrides or space workspace on Direct Space is rejected with 403
    const putWsRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/workflow-workspace`, {
        method: "PUT",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ workspaceId: "ws-alice" }),
      }),
      env as never,
    );
    expect(putWsRes.status).toBe(403);

    const putConfigRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/workflow-configurations/chat`, {
        method: "PUT",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ schemaVersion: 1, workflowId: "chat", enabled: true }),
      }),
      env as never,
    );
    expect(putConfigRes.status).toBe(403);

    const putDefaultRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/workflow-default`, {
        method: "PUT",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ defaultWorkflowId: "direct" }),
      }),
      env as never,
    );
    expect(putDefaultRes.status).toBe(403);
  });

  it("7.2 & 7.4 Both participants can execute Workflows with their own Workers; grants are provisioned on demand", async () => {
    const { env } = createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env);

    // Alice resolves execution bindings for Chat
    const aliceChatBindings = await resolveWorkflowExecutionBindings(
      env as never,
      "user-alice",
      directSpaceId,
      generalThreadId,
      BUILTIN_WORKFLOWS.chat,
      {},
      [],
    );
    expect(aliceChatBindings.chat?.workerId).toBe("worker-a");

    // Verify workspace grant for Alice's workspace was created
    const aliceGrant = await env.SYNTILA_DB.prepare(
      "SELECT workspace_id, granted_by_user_id, status FROM workspace_space_grants WHERE space_id = ?1 AND workspace_id = ?2",
    )
      .bind(directSpaceId, "ws-alice")
      .first<{ workspace_id: string; granted_by_user_id: string; status: string }>();
    expect(aliceGrant?.workspace_id).toBe("ws-alice");
    expect(aliceGrant?.granted_by_user_id).toBe("user-alice");
    expect(aliceGrant?.status).toBe("active");

    // Bob resolves execution bindings for Chat
    const bobChatBindings = await resolveWorkflowExecutionBindings(
      env as never,
      "user-bob",
      directSpaceId,
      generalThreadId,
      BUILTIN_WORKFLOWS.chat,
      {},
      [],
    );
    expect(bobChatBindings.chat?.workerId).toBe("worker-b");

    // Verify workspace grant for Bob's workspace was created and coexists with Alice's
    const bobGrant = await env.SYNTILA_DB.prepare(
      "SELECT workspace_id, granted_by_user_id, status FROM workspace_space_grants WHERE space_id = ?1 AND workspace_id = ?2",
    )
      .bind(directSpaceId, "ws-bob")
      .first<{ workspace_id: string; granted_by_user_id: string; status: string }>();
    expect(bobGrant?.workspace_id).toBe("ws-bob");
    expect(bobGrant?.granted_by_user_id).toBe("user-bob");
    expect(bobGrant?.status).toBe("active");

    // Alice resolves stateful Work (direct workflow) on her own workspace
    const aliceWorkBindings = await resolveWorkflowExecutionBindings(
      env as never,
      "user-alice",
      directSpaceId,
      generalThreadId,
      BUILTIN_WORKFLOWS.direct,
      {},
      [],
    );
    expect(aliceWorkBindings.direct?.workerId).toBe("worker-a");

    // Bob resolves stateful Work (direct workflow) on his own workspace
    const bobWorkBindings = await resolveWorkflowExecutionBindings(
      env as never,
      "user-bob",
      directSpaceId,
      generalThreadId,
      BUILTIN_WORKFLOWS.direct,
      {},
      [],
    );
    expect(bobWorkBindings.direct?.workerId).toBe("worker-b");
  });

  it("7.4 Strict Workspace boundary: participant cannot access the other's Workspace without a grant", async () => {
    const { env } = createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env);

    // Alice attempts to use Bob's worker-b without Bob granting ws-bob to Alice
    await expect(
      resolveWorkflowExecutionBindings(
        env as never,
        "user-alice",
        directSpaceId,
        generalThreadId,
        BUILTIN_WORKFLOWS.chat,
        {},
        [],
        { workerId: "worker-b" },
      ),
    ).rejects.toThrow("Configured Worker is unavailable for this Space");

    // Bob attempts to use Alice's worker-a without Alice granting ws-alice to Bob
    await expect(
      resolveWorkflowExecutionBindings(
        env as never,
        "user-bob",
        directSpaceId,
        generalThreadId,
        BUILTIN_WORKFLOWS.chat,
        {},
        [],
        { workerId: "worker-a" },
      ),
    ).rejects.toThrow("Configured Worker is unavailable for this Space");

    // Charlie has no workspace configured: cannot execute
    await expect(
      resolveWorkflowExecutionBindings(
        env as never,
        "user-charlie",
        directSpaceId,
        generalThreadId,
        BUILTIN_WORKFLOWS.chat,
        {},
        [],
      ),
    ).rejects.toThrow();
  });

  it("7.4 Person Grants: Bob granting Workspace to Alice allows Chat but strictly forbids stateful Work", async () => {
    const { env } = createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env);
    const now = new Date().toISOString();

    // Bob explicitly grants ws-bob to Alice via Person Grant
    await env.SYNTILA_DB.prepare(
      `INSERT INTO workspace_person_grants (
        workspace_id, user_id, granted_by_user_id, status, max_concurrent_requests,
        created_at, updated_at
      ) VALUES ('ws-bob', 'user-alice', 'user-bob', 'active', 2, ?1, ?1)`,
    )
      .bind(now)
      .run();

    // Alice can now run Chat with worker-b on the borrowed workspace
    const aliceChatLent = await resolveWorkflowExecutionBindings(
      env as never,
      "user-alice",
      directSpaceId,
      generalThreadId,
      BUILTIN_WORKFLOWS.chat,
      {},
      [],
      { workerId: "worker-b" },
    );
    expect(aliceChatLent.chat?.workerId).toBe("worker-b");

    // Verify borrowed workspace grant was created for ws-bob in the space
    const lentGrant = await env.SYNTILA_DB.prepare(
      "SELECT allowed_permissions_json FROM workspace_space_grants WHERE space_id = ?1 AND workspace_id = 'ws-bob'",
    )
      .bind(directSpaceId)
      .first<{ allowed_permissions_json: string }>();
    expect(JSON.parse(lentGrant?.allowed_permissions_json ?? "[]")).toEqual(["repository:read"]);

    // Alice attempts to run stateful Work (direct workflow) on Bob's borrowed Workspace
    // Must be strictly rejected!
    await expect(
      resolveWorkflowExecutionBindings(
        env as never,
        "user-alice",
        directSpaceId,
        generalThreadId,
        BUILTIN_WORKFLOWS.direct,
        {},
        [],
        { workerId: "worker-b" },
      ),
    ).rejects.toThrow("A shared Workspace runs Chat only; choose your own Workspace for this Workflow");
  });

  it("7.5 AI sessions and context: Threads maintain independent AI history and session state", async () => {
    const { env } = createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env);

    // Create a custom topic thread in the Direct Space
    const createThreadRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        method: "POST",
        headers: { authorization: "Bearer alice", "content-type": "application/json" },
        body: JSON.stringify({ name: "Project Ideas" }),
      }),
      env as never,
    );
    expect(createThreadRes.status).toBe(201);
    const { thread } = (await createThreadRes.json()) as { thread: { id: string } };
    const customThreadId = thread.id;

    // Verify both threads have distinct conversation identities
    const row = await env.SYNTILA_DB.prepare(
      "SELECT id, is_general FROM threads WHERE space_id = ?1 ORDER BY is_general DESC",
    )
      .bind(directSpaceId)
      .all<{ id: string; is_general: number }>();
    expect(row.results.length).toBe(2);
    expect(row.results[0]?.id).toBe(generalThreadId);
    expect(row.results[0]?.is_general).toBe(1);
    expect(row.results[1]?.id).toBe(customThreadId);
    expect(row.results[1]?.is_general).toBe(0);

    // Verify both threads have distinct, isolated conversation identities
    const genConvId = threadConversationId(generalThreadId);
    const customConvId = threadConversationId(customThreadId);
    expect(genConvId).not.toBe(customConvId);

    const now = new Date().toISOString();
    // Simulate conversation history in General Thread
    await env.SYNTILA_DB.prepare(
      `INSERT INTO conversations (id, thread_id, workflow_id, workflow_version, conversation_revision, context_revision, created_at, updated_at)
       VALUES (?1, ?2, 'chat', 1, 1, 1, ?3, ?3)`,
    )
      .bind(genConvId, generalThreadId, now)
      .run();

    await env.SYNTILA_DB.prepare(
      `INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, source_id, text, occurred_at)
       VALUES (?1, 1, 'user_message', 'message', 'user', 'user-alice', 'src-gen', 'General Thread Question', ?2)`,
    )
      .bind(genConvId, now)
      .run();

    // Simulate conversation history in Custom Topic Thread
    await env.SYNTILA_DB.prepare(
      `INSERT INTO conversations (id, thread_id, workflow_id, workflow_version, conversation_revision, context_revision, created_at, updated_at)
       VALUES (?1, ?2, 'chat', 1, 1, 1, ?3, ?3)`,
    )
      .bind(customConvId, customThreadId, now)
      .run();

    await env.SYNTILA_DB.prepare(
      `INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, source_id, text, occurred_at)
       VALUES (?1, 1, 'user_message', 'message', 'user', 'user-bob', 'src-custom', 'Project Idea Discussion', ?2)`,
    )
      .bind(customConvId, now)
      .run();

    // Verify history entries are completely isolated per Thread
    const genEntries = await env.SYNTILA_DB.prepare(
      "SELECT text FROM conversation_history_entries WHERE conversation_id = ?1",
    )
      .bind(genConvId)
      .all<{ text: string }>();
    expect(genEntries.results.map((e) => e.text)).toEqual(["General Thread Question"]);

    const customEntries = await env.SYNTILA_DB.prepare(
      "SELECT text FROM conversation_history_entries WHERE conversation_id = ?1",
    )
      .bind(customConvId)
      .all<{ text: string }>();
    expect(customEntries.results.map((e) => e.text)).toEqual(["Project Idea Discussion"]);
  });
});
