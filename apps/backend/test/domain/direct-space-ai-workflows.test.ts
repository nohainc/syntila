import { fixtureStatement } from "./helpers/fixture-sql";
import { describe, expect, it } from "./helpers/vitest-compat";
import { BUILTIN_WORKFLOWS, DEFAULT_THREAD_ACCESS_POLICY } from "@syntila/core";
import { pgD1 } from "./helpers/pg-d1";
import worker from "../../src/domain/index.js";
import { resolveWorkerTargetBindings } from "../../src/domain/routes/worker-target-bindings.js";
import { threadConversationId } from "../../src/domain/routes/conversations.js";

describe("Direct Space AI Workers and Workflows (Phase 7)", () => {
  async function createTestEnv() {
    const { sqlite, db } = await pgD1();
    const now = new Date().toISOString();

    await sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at) VALUES
        ('user-alice', 'alice@test.com', 'Alice User', 'active', '${now}', '${now}'),
        ('user-bob', 'bob@test.com', 'Bob User', 'active', '${now}', '${now}'),
        ('user-charlie', 'charlie@test.com', 'Charlie User', 'active', '${now}', '${now}');

      -- Known collaborator relationship between Alice and Bob
      INSERT INTO people_relationships (user_low_id, user_high_id, established_at) VALUES
        ('user-alice', 'user-bob', '${now}');

      -- Account plans (paid for sharing if needed)
      INSERT INTO account_plans (user_id, tier, status, source, created_at, updated_at) VALUES
        ('user-alice', 'paid', 'active', 'manual', '${now}', '${now}'),
        ('user-bob', 'paid', 'active', 'manual', '${now}', '${now}'),
        ('user-charlie', 'free', 'active', 'manual', '${now}', '${now}');

      -- Workers: Alice has worker-a, Bob has worker-b
      INSERT INTO worker_instances (id, actor_id, owner_user_id, worker_type_id, name) VALUES
        ('worker-a', '', 'user-alice', 'chatgpt', 'Alice Worker'),
        ('worker-b', '', 'user-bob', 'chatgpt', 'Bob Worker');
      INSERT INTO worker_credentials (id, worker_instance_id, public_key, key_fingerprint) VALUES
        ('cred-a', 'worker-a', '${"a".repeat(43)}', '${"a".repeat(64)}'),
        ('cred-b', 'worker-b', '${"b".repeat(43)}', '${"b".repeat(64)}');
      INSERT INTO worker_agent_sessions (worker_instance_id, session_id, session_epoch, credential_id, token_digest, lease_expires_at) VALUES
        ('worker-a', 'sess-a', 1, 'cred-a', 'digest-a', now() + interval '5 minutes'),
        ('worker-b', 'sess-b', 1, 'cred-b', 'digest-b', now() + interval '5 minutes');
      INSERT INTO worker_profiles (worker_type_id, schema_version, profile_json, revision, digest, updated_at) VALUES
        ('chatgpt', 1, '{"schemaVersion":1,"profileDefinitionId":"chatgpt-codex"}', 1, '${"a".repeat(64)}', now())
        ON CONFLICT (worker_type_id) DO NOTHING;

      -- User workflow configurations
      INSERT INTO user_worker_workflow_configurations (user_id, workflow_id, schema_version, configuration_json, updated_at) VALUES
        ('user-alice', 'chat', 1, '{"schemaVersion":1,"workflowId":"chat","enabled":true,"defaults":{"worker":"worker-a"},"stepOverrides":{}}', '${now}'),
        ('user-alice', 'direct', 1, '{"schemaVersion":1,"workflowId":"direct","enabled":true,"defaults":{"worker":"worker-a"},"stepOverrides":{}}', '${now}'),
        ('user-bob', 'chat', 1, '{"schemaVersion":1,"workflowId":"chat","enabled":true,"defaults":{"worker":"worker-b"},"stepOverrides":{}}', '${now}'),
        ('user-bob', 'direct', 1, '{"schemaVersion":1,"workflowId":"direct","enabled":true,"defaults":{"worker":"worker-b"},"stepOverrides":{}}', '${now}');
    `);

    const users: Record<
      string,
      { id: string; email: string; displayName: string; status: string }
    > = {
      alice: {
        id: "user-alice",
        email: "alice@test.com",
        displayName: "Alice User",
        status: "active",
      },
      bob: {
        id: "user-bob",
        email: "bob@test.com",
        displayName: "Bob User",
        status: "active",
      },
      charlie: {
        id: "user-charlie",
        email: "charlie@test.com",
        displayName: "Charlie User",
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
            spaceRoles: {},
            sessionId: "sess-anon",
            clientType: "web",
          };
        }
        return {
          userId: user.id,
          user,
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
        headers: {
          authorization: "Bearer alice",
          "content-type": "application/json",
        },
        body: JSON.stringify({ userId: "user-bob" }),
      }),
      env as never,
    );
    const { invitation } = (await inviteRes.json()) as {
      invitation: { id: string };
    };

    const acceptRes = await worker.fetch(
      new Request(
        `https://syntila.test/api/people/invitations/${invitation.id}/accept`,
        {
          method: "POST",
          headers: { authorization: "Bearer bob" },
        },
      ),
      env as never,
    );
    const { directSpaceId } = (await acceptRes.json()) as {
      directSpaceId: string;
    };
    const generalThreadId = `legacy-gen-${directSpaceId}`;
    const now = new Date().toISOString();
    await fixtureStatement((env as { SYNTILA_DB: D1Database }).SYNTILA_DB, "INSERT INTO threads (id, space_id, name, status, lead_user_id, is_general, access_policy_json, created_at, updated_at) VALUES (?1, ?2, 'General', 'active', 'user-alice', TRUE, ?3, ?4, ?4)", [generalThreadId, directSpaceId, JSON.stringify(DEFAULT_THREAD_ACCESS_POLICY), now])
      .run();
    await fixtureStatement((env as { SYNTILA_DB: D1Database }).SYNTILA_DB, "UPDATE direct_spaces SET general_thread_id = ?1 WHERE space_id = ?2", [generalThreadId, directSpaceId])
      .run();
    return { directSpaceId, generalThreadId };
  }

  it("7.1 Human messaging: both participants share discussion messages and see each other's messages", async () => {
    const { env } = await createTestEnv();
    const { generalThreadId } = await establishDirectSpace(env);

    // Alice posts a message
    const alicePost = await worker.fetch(
      new Request(
        `https://syntila.test/api/threads/${generalThreadId}/discussion-messages`,
        {
          method: "POST",
          headers: {
            authorization: "Bearer alice",
            "content-type": "application/json",
          },
          body: JSON.stringify({ body: "Hello Bob from Alice!" }),
        },
      ),
      env as never,
    );
    expect(alicePost.status).toBe(201);

    // Bob posts a message
    const bobPost = await worker.fetch(
      new Request(
        `https://syntila.test/api/threads/${generalThreadId}/discussion-messages`,
        {
          method: "POST",
          headers: {
            authorization: "Bearer bob",
            "content-type": "application/json",
          },
          body: JSON.stringify({ body: "Hello Alice from Bob!" }),
        },
      ),
      env as never,
    );
    expect(bobPost.status).toBe(201);

    // Alice lists messages: sees both
    const aliceList = await worker.fetch(
      new Request(
        `https://syntila.test/api/threads/${generalThreadId}/discussion-messages`,
        {
          method: "GET",
          headers: { authorization: "Bearer alice" },
        },
      ),
      env as never,
    );
    expect(aliceList.status).toBe(200);
    const aliceMessages = (
      (await aliceList.json()) as {
        messages: Array<{ body: string; authorUserId: string }>;
      }
    ).messages;
    expect(aliceMessages.map((m) => m.body)).toEqual([
      "Hello Bob from Alice!",
      "Hello Alice from Bob!",
    ]);

    // Bob lists messages: sees both identically
    const bobList = await worker.fetch(
      new Request(
        `https://syntila.test/api/threads/${generalThreadId}/discussion-messages`,
        {
          method: "GET",
          headers: { authorization: "Bearer bob" },
        },
      ),
      env as never,
    );
    expect(bobList.status).toBe(200);
    const bobMessages = (
      (await bobList.json()) as {
        messages: Array<{ body: string; authorUserId: string }>;
      }
    ).messages;
    expect(bobMessages.map((m) => m.body)).toEqual([
      "Hello Bob from Alice!",
      "Hello Alice from Bob!",
    ]);
  });

  it("7.2 & 7.3 Direct Space workflow configuration rejects space-level overrides", async () => {
    const { env } = await createTestEnv();
    const { directSpaceId } = await establishDirectSpace(env);

    // Workflow configurations query on Direct Space returns 200 with schemaVersion
    const aliceConfigsRes = await worker.fetch(
      new Request(
        `https://syntila.test/api/spaces/${directSpaceId}/workflow-configurations`,
        {
          method: "GET",
          headers: { authorization: "Bearer alice" },
        },
      ),
      env as never,
    );
    expect(aliceConfigsRes.status).toBe(200);
    const aliceConfigs = (await aliceConfigsRes.json()) as {
      schemaVersion: number;
      configurations: Array<unknown>;
    };
    expect(aliceConfigs.schemaVersion).toBe(1);
    expect(Array.isArray(aliceConfigs.configurations)).toBe(true);

    const putConfigRes = await worker.fetch(
      new Request(
        `https://syntila.test/api/spaces/${directSpaceId}/workflow-configurations/chat`,
        {
          method: "PUT",
          headers: {
            authorization: "Bearer alice",
            "content-type": "application/json",
          },
          body: JSON.stringify({
            schemaVersion: 1,
            workflowId: "chat",
            enabled: true,
          }),
        },
      ),
      env as never,
    );
    expect(putConfigRes.status).toBe(403);

    const putDefaultRes = await worker.fetch(
      new Request(
        `https://syntila.test/api/spaces/${directSpaceId}/workflow-default`,
        {
          method: "PUT",
          headers: {
            authorization: "Bearer alice",
            "content-type": "application/json",
          },
          body: JSON.stringify({ defaultWorkflowId: "direct" }),
        },
      ),
      env as never,
    );
    expect(putDefaultRes.status).toBe(403);
  });

  it("7.2 & 7.4 Both participants can execute Chat with their own Workers; non-chat workflows rejected", async () => {
    const { env } = await createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env);

    // Alice resolves execution bindings for Chat with her own worker
    const aliceChatBindings = await resolveWorkerTargetBindings(env as never, {
      userId: "user-alice",
      spaceId: directSpaceId,
      threadId: generalThreadId,
      definition: BUILTIN_WORKFLOWS.chat,
      request: { workerId: "worker-a" },
    });
    expect(aliceChatBindings.ok).toBe(true);
    if (aliceChatBindings.ok) {
      expect(aliceChatBindings.bindings.chat?.workerId).toBe("worker-a");
    }

    // Bob resolves execution bindings for Chat with his own worker
    const bobChatBindings = await resolveWorkerTargetBindings(env as never, {
      userId: "user-bob",
      spaceId: directSpaceId,
      threadId: generalThreadId,
      definition: BUILTIN_WORKFLOWS.chat,
      request: { workerId: "worker-b" },
    });
    expect(bobChatBindings.ok).toBe(true);
    if (bobChatBindings.ok) {
      expect(bobChatBindings.bindings.chat?.workerId).toBe("worker-b");
    }

    // Attempting stateful Work (direct workflow) in Direct Space is rejected with 403
    await expect(
      resolveWorkerTargetBindings(env as never, {
        userId: "user-alice",
        spaceId: directSpaceId,
        threadId: generalThreadId,
        definition: BUILTIN_WORKFLOWS.direct,
        request: { workerId: "worker-a" },
      }),
    ).rejects.toThrow("Personal Spaces support Chat only");

    await expect(
      resolveWorkerTargetBindings(env as never, {
        userId: "user-bob",
        spaceId: directSpaceId,
        threadId: generalThreadId,
        definition: BUILTIN_WORKFLOWS.direct,
        request: { workerId: "worker-b" },
      }),
    ).rejects.toThrow("Personal Spaces support Chat only");
  });

  it("7.4 Strict Worker boundary: participant cannot use the other's Worker without a share", async () => {
    const { env } = await createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env);

    // Alice attempts to use Bob's worker-b without owning it or a share
    await expect(
      resolveWorkerTargetBindings(env as never, {
        userId: "user-alice",
        spaceId: directSpaceId,
        threadId: generalThreadId,
        definition: BUILTIN_WORKFLOWS.chat,
        request: { workerId: "worker-b" },
      }),
    ).rejects.toThrow("Choose one of your own Workers in a personal Space");

    // Bob attempts to use Alice's worker-a without owning it or a share
    await expect(
      resolveWorkerTargetBindings(env as never, {
        userId: "user-bob",
        spaceId: directSpaceId,
        threadId: generalThreadId,
        definition: BUILTIN_WORKFLOWS.chat,
        request: { workerId: "worker-a" },
      }),
    ).rejects.toThrow("Choose one of your own Workers in a personal Space");

    // Charlie is not a member of the Direct Space: cannot execute
    await expect(
      resolveWorkerTargetBindings(env as never, {
        userId: "user-charlie",
        spaceId: directSpaceId,
        threadId: generalThreadId,
        definition: BUILTIN_WORKFLOWS.chat,
        request: { workerId: "worker-a" },
      }),
    ).rejects.toThrow();
  });

  it("7.5 AI sessions and context: Threads maintain independent AI history and session state", async () => {
    const { env } = await createTestEnv();
    const { directSpaceId, generalThreadId } = await establishDirectSpace(env);

    // Create a custom topic thread in the Direct Space
    const createThreadRes = await worker.fetch(
      new Request(`https://syntila.test/api/spaces/${directSpaceId}/threads`, {
        method: "POST",
        headers: {
          authorization: "Bearer alice",
          "content-type": "application/json",
        },
        body: JSON.stringify({ name: "Project Ideas" }),
      }),
      env as never,
    );
    expect(createThreadRes.status).toBe(201);
    const { thread } = (await createThreadRes.json()) as {
      thread: { id: string };
    };
    const customThreadId = thread.id;

    // Verify both threads have distinct conversation identities
    const row = await fixtureStatement(env.SYNTILA_DB, "SELECT id, is_general FROM threads WHERE space_id = ?1 ORDER BY is_general DESC", [directSpaceId])
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
    await fixtureStatement(env.SYNTILA_DB, `INSERT INTO conversations (id, thread_id, workflow_id, workflow_version, conversation_revision, context_revision, created_at, updated_at)
       VALUES (?1, ?2, 'chat', 1, 1, 1, ?3, ?3)`, [genConvId, generalThreadId, now])
      .run();

    await fixtureStatement(env.SYNTILA_DB, `INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, source_id, text, occurred_at)
       VALUES (?1, 1, 'user_message', 'message', 'user', 'user-alice', 'src-gen', 'General Thread Question', ?2)`, [genConvId, now])
      .run();

    // Simulate conversation history in Custom Topic Thread
    await fixtureStatement(env.SYNTILA_DB, `INSERT INTO conversations (id, thread_id, workflow_id, workflow_version, conversation_revision, context_revision, created_at, updated_at)
       VALUES (?1, ?2, 'chat', 1, 1, 1, ?3, ?3)`, [customConvId, customThreadId, now])
      .run();

    await fixtureStatement(env.SYNTILA_DB, `INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, source_id, text, occurred_at)
       VALUES (?1, 1, 'user_message', 'message', 'user', 'user-bob', 'src-custom', 'Project Idea Discussion', ?2)`, [customConvId, now])
      .run();

    // Verify history entries are completely isolated per Thread
    const genEntries = await fixtureStatement(env.SYNTILA_DB, "SELECT text FROM conversation_history_entries WHERE conversation_id = ?1", [genConvId])
      .all<{ text: string }>();
    expect(genEntries.results.map((e) => e.text)).toEqual([
      "General Thread Question",
    ]);

    const customEntries = await fixtureStatement(env.SYNTILA_DB, "SELECT text FROM conversation_history_entries WHERE conversation_id = ?1", [customConvId])
      .all<{ text: string }>();
    expect(customEntries.results.map((e) => e.text)).toEqual([
      "Project Idea Discussion",
    ]);
  });
});
