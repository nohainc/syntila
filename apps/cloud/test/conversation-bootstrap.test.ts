import { expect, it } from "vitest";
import { CONVERSATION_WORKFLOWS } from "@syntila/core";
import { conversationFixture } from "./helpers/conversation.js";
import {
  conversationSubmissionStatements,
  threadConversationId,
} from "../src/routes/conversations.js";
import { loadConversationBootstrap } from "../src/routes/conversation-bootstrap.js";
import { recordAssignmentResult } from "../src/assignment-dispatcher.js";

it("includes late prior replies while excluding the current request", async () => {
  const f = await conversationFixture();
  try {
    f.assign("A");
    f.start("A");
    f.sqlite
      .exec(`INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
      VALUES('R2','W','U','stateless','chat',1,'{}','running','{"originalRequest":"Current request"}','now','now')`);
    await f.db.batch(
      conversationSubmissionStatements(
        f.db as unknown as D1Database,
        threadConversationId("W"),
        "W",
        CONVERSATION_WORKFLOWS.chat!,
        "R2",
        "now",
      ),
    );
    await recordAssignmentResult(f.db as unknown as D1Database, "A", {
      assignmentId: "A",
      status: "completed",
      output: { text: "Previous answer" },
      artifactIds: [],
      completedAt: "2026-10-07T10:02:00Z",
    });
    const conversation = f.sqlite
      .prepare("SELECT id FROM conversations")
      .get() as { id: string };
    const bootstrap = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      conversation.id,
      "R2",
      1,
    );
    const history = JSON.parse(bootstrap.text) as {
      history: { text: string | null }[];
    };
    expect(history.history.map((item) => item.text).filter(Boolean)).toEqual([
      "**Exact user text**",
      "Previous answer",
    ]);
    expect(bootstrap.text).not.toContain("Current request");
    expect(bootstrap.conversationId).toBe(conversation.id);
    expect(bootstrap.contextRevision).toBe(1);
    expect(bootstrap.turnRevision).toBe(2);
    const document = JSON.parse(bootstrap.text);
    expect(document.kind).toBe("BootstrapContext");
    expect(document.context.workflowState.value).toMatchObject({
      workflowId: "chat",
      workflowVersion: 1,
      workRequestId: "R2",
      status: "running",
    });
    expect(document.context.importantDecisions).toEqual({});
    const stateless = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      conversation.id,
      "R2",
      1,
      "stateless",
    );
    expect(JSON.parse(stateless.text).kind).toBe("StatelessContext");
    expect(JSON.parse(stateless.text).context.workflowState).toEqual(
      document.context.workflowState,
    );

    await expect(
      loadConversationBootstrap(
        f.db as unknown as D1Database,
        "foreign",
        "R2",
        0,
      ),
    ).rejects.toThrow(/boundary/);
    await expect(
      loadConversationBootstrap(
        f.db as unknown as D1Database,
        conversation.id,
        "missing",
        0,
      ),
    ).rejects.toThrow(/boundary/);
    f.sqlite
      .prepare(
        `INSERT INTO conversation_history_entries
      (conversation_id, sequence, kind, event_type, actor_type, source_id, text, metadata_json, occurred_at)
      SELECT ?1, MAX(sequence)+1, 'user_message', 'user_message', 'user', 'huge-source', ?2, '{}', 'now'
      FROM conversation_history_entries WHERE conversation_id = ?1`,
      )
      .run(conversation.id, "x".repeat(256 * 1024 + 1));
    f.sqlite
      .exec(`INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
      VALUES('R3','W','U','stateless','chat',1,'{}','running','{"originalRequest":"Next request"}','now','now')`);
    await f.db.batch(
      conversationSubmissionStatements(
        f.db as unknown as D1Database,
        threadConversationId("W"),
        "W",
        CONVERSATION_WORKFLOWS.chat!,
        "R3",
        "now",
      ),
    );
    // History over the transport budget is left out instead of failing the
    // turn; the Worker's CLI reports a real context overflow itself.
    const trimmed = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      conversation.id,
      "R3",
      2,
    );
    expect(trimmed.text).not.toContain("huge-source");
    expect(new TextEncoder().encode(trimmed.text).byteLength).toBeLessThan(
      256 * 1024,
    );
  } finally {
    f.sqlite.close();
  }
});

it("assembles Work environment and scoped prerequisite results for the receiving step", async () => {
  const f = await conversationFixture();
  try {
    const snapshot = JSON.stringify({
      spaceInstructions: "Space rules",
      threadInstructions: "Stream rules",
      resolvedBindings: { direct: { workerId: "worker-chatgpt" } },
    });
    f.sqlite
      .prepare(
        `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,primary_workspace_id,status,input_json,created_at,updated_at)
      VALUES('RW','W','U','stateful','direct',2,'{}',?,'WS','running','{}','now','now')`,
      )
      .run(snapshot);
    await f.db.batch(
      conversationSubmissionStatements(
        f.db as unknown as D1Database,
        threadConversationId("W"),
        "W",
        CONVERSATION_WORKFLOWS.work!,
        "RW",
        "now",
      ),
    );
    f.sqlite
      .exec(`INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,attempt,output_json,created_at,updated_at) VALUES
      ('IMPLEMENT','RW','implement','stateful_thread',1000,'implement:v1','completed',1,'{"text":"Implementation result","workerId":"ChatGPT"}','now','now'),
      ('VERIFY','RW','verify','stateless_read',1000,'verify:v1','queued',0,NULL,'now','now'),
      ('TEST','RW','test','stateless_read',1000,'test:v1','completed',1,'{"text":"Unrelated test output"}','now','now');
      INSERT INTO workflow_task_dependencies(task_id,depends_on_task_id) VALUES('VERIFY','IMPLEMENT');
      INSERT INTO artifacts(id,space_id,thread_id,work_request_id,content_digest,storage_key,created_at) VALUES('AR','P','W','RW','digest','secret-storage-key','now');`);
    const row = { id: threadConversationId("W") };
    const result = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      row.id,
      "RW",
      // RW follows the fixture's Chat request in the shared Thread Conversation.
      1,
      "bootstrap",
      "VERIFY",
    );
    const context = JSON.parse(result.text);
    expect(context.workflowExecutionContext).toMatchObject({
      activeStepId: "VERIFY",
      environment: {
        spaceId: "P",
        threadId: "W",
        workspaceId: "WS",
        spaceInstructions: "Space rules",
      },
      artifacts: [{ id: "AR", contentDigest: "digest" }],
      prerequisiteResults: [
        {
          stepId: "IMPLEMENT",
          workerId: "ChatGPT",
          text: "Implementation result",
        },
      ],
    });
    expect(context.conversationContext).not.toHaveProperty("workflowState");
    expect(result.text).not.toContain("Unrelated test output");
    expect(result.text).not.toContain("secret-storage-key");
    await expect(
      loadConversationBootstrap(
        f.db as unknown as D1Database,
        row.id,
        "RW",
        1,
        "bootstrap",
        "T",
      ),
    ).rejects.toThrow(/outside/);
    const chatRow = row;
    const chat = JSON.parse(
      (
        await loadConversationBootstrap(
          f.db as unknown as D1Database,
          chatRow.id,
          "R",
          0,
          "bootstrap",
          "T",
        )
      ).text,
    );
    expect(chat.workflowExecutionContext.environment).toBeNull();
    expect(chat.workflowExecutionContext.artifacts).toEqual([]);
  } finally {
    f.sqlite.close();
  }
});

it("parallel worker steps preserve one base and never acquire a sibling's response retroactively", async () => {
  const f = await conversationFixture();
  try {
    f.sqlite
      .exec(`INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
      VALUES('VERIFY','R','verify','stateless_read',1000,'verify:v1','running','now','now')`);
    const { id } = f.sqlite.prepare("SELECT id FROM conversations").get() as {
      id: string;
    };
    const first = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      id,
      "R",
      0,
      "bootstrap",
      "T",
    );
    const second = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      id,
      "R",
      0,
      "bootstrap",
      "VERIFY",
    );
    const evidence = (snapshot: typeof first) => ({
      schemaVersion: 1,
      baseContextRevision: snapshot.contextRevision,
      turnRevision: snapshot.turnRevision,
      throughSequence: snapshot.throughSequence,
    });
    f.assign(
      "PARALLEL-A",
      "model-x",
      "medium",
      "durable_session",
      0,
      evidence(first),
    );
    f.start("PARALLEL-A");
    f.sqlite
      .prepare(
        `INSERT INTO worker_assignments
      (id,space_id,execution_workspace_id,runtime_identity_id,worker_type_id,workspace_worker_id,task_id,status,model,permission_snapshot_json,session_policy,created_at,updated_at)
      VALUES('PARALLEL-B','P','WS','RT','gemini','worker-b','VERIFY','created','model-y',?,'durable_session','now','now')`,
      )
      .run(
        JSON.stringify({
          profileDefinitionId: "gemini-antigravity",
          profileReleaseVersion: 1,
          workerSessionId: "gemini-session",
          baseContextRevision: 0,
          contextSnapshot: evidence(second),
        }),
      );
    f.sqlite.exec(
      "UPDATE worker_assignments SET status='running' WHERE id='PARALLEL-B'",
    );
    await recordAssignmentResult(f.db as unknown as D1Database, "PARALLEL-B", {
      assignmentId: "PARALLEL-B",
      status: "completed",
      output: { text: "Sibling private response" },
      artifactIds: [],
      completedAt: "first-completion",
    });
    const afterSibling = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      id,
      "R",
      0,
      "bootstrap",
      "T",
    );
    expect(first.text).not.toContain("Sibling private response");
    expect(second.text).not.toContain("Sibling private response");
    expect(afterSibling.text).not.toContain("Sibling private response");
    f.sqlite.exec(
      "UPDATE conversations SET conversation_revision=107,context_revision=107",
    );
    await recordAssignmentResult(f.db as unknown as D1Database, "PARALLEL-A", {
      assignmentId: "PARALLEL-A",
      status: "completed",
      output: { text: "Independent answer" },
      artifactIds: [],
      completedAt: "second-completion",
    });
    const turns = await f.turns();
    expect(turns).toHaveLength(2);
    expect(turns.map((t) => t.baseContextRevision)).toEqual([0, 0]);
    const metadata = f.sqlite
      .prepare(
        "SELECT metadata_json FROM conversation_history_entries WHERE kind='worker_response'",
      )
      .all() as { metadata_json: string }[];
    expect(
      metadata.map((row) => JSON.parse(row.metadata_json).baseContextRevision),
    ).toEqual([0, 0]);
    expect(() =>
      f.sqlite.exec(
        `UPDATE worker_assignments SET permission_snapshot_json=json_set(permission_snapshot_json,'$.contextSnapshot.baseContextRevision',107) WHERE id='PARALLEL-B'`,
      ),
    ).toThrow(/snapshot is immutable/);
  } finally {
    f.sqlite.close();
  }
});

it("leaves exchanges before an AI History clear out of later context", async () => {
  const f = await conversationFixture();
  try {
    f.assign("A");
    f.start("A");
    await recordAssignmentResult(f.db as unknown as D1Database, "A", {
      assignmentId: "A",
      status: "completed",
      output: { text: "Previous answer" },
      artifactIds: [],
      completedAt: "2026-10-07T10:02:00Z",
    });
    // Clearing AI History moves the context floor past everything so far.
    f.sqlite.exec(`UPDATE conversations SET context_floor_sequence =
      (SELECT MAX(sequence) FROM conversation_history_entries)`);
    f.sqlite
      .exec(`INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
      VALUES('R2','W','U','stateless','chat',1,'{}','running','{"originalRequest":"Current request"}','now','now')`);
    await f.db.batch(
      conversationSubmissionStatements(
        f.db as unknown as D1Database,
        threadConversationId("W"),
        "W",
        CONVERSATION_WORKFLOWS.chat!,
        "R2",
        "now",
      ),
    );
    const conversation = f.sqlite
      .prepare("SELECT id FROM conversations")
      .get() as { id: string };
    const bootstrap = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      conversation.id,
      "R2",
      1,
    );
    expect(bootstrap.text).not.toContain("Exact user text");
    expect(bootstrap.text).not.toContain("Previous answer");
    // Context-limit recovery retains the latest answer as the only prior text.
    f.sqlite.exec(`UPDATE conversations SET context_floor_sequence =
      (SELECT MAX(sequence) - 1 FROM conversation_history_entries WHERE kind='worker_response')`);
    const recovered = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      conversation.id,
      "R2",
      1,
    );
    const document = JSON.parse(recovered.text);
    expect(
      document.history
        .filter((entry: { text: string | null }) => entry.text)
        .map((entry: { text: string }) => entry.text),
    ).toEqual(["Previous answer"]);
    expect(recovered.text).not.toContain("Exact user text");
  } finally {
    f.sqlite.close();
  }
});

it("excludes late pre-reset replies from fresh context while retaining visible history", async () => {
  const f = await conversationFixture();
  try {
    f.assign("A");
    f.start("A");
    f.sqlite.exec(`UPDATE conversations SET context_floor_sequence =
      (SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = conversations.id);
      UPDATE threads SET ai_context_generation = ai_context_generation + 1 WHERE id='W';`);
    await recordAssignmentResult(f.db as unknown as D1Database, "A", {
      assignmentId: "A",
      status: "completed",
      output: { text: "Late old answer" },
      artifactIds: [],
      completedAt: "2026-10-07T10:02:00Z",
    });
    f.sqlite
      .exec(`INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at)
      VALUES('R2','W','U','stateless','chat',1,'{}','running','{"originalRequest":"Fresh request"}','now','now')`);
    await f.db.batch(
      conversationSubmissionStatements(
        f.db as unknown as D1Database,
        threadConversationId("W"),
        "W",
        CONVERSATION_WORKFLOWS.chat!,
        "R2",
        "now",
      ),
    );
    const result = await loadConversationBootstrap(
      f.db as unknown as D1Database,
      threadConversationId("W"),
      "R2",
      1,
    );
    expect(result.text).not.toContain("Late old answer");
    expect(
      f.sqlite
        .prepare(
          "SELECT text FROM conversation_history_entries WHERE text = 'Late old answer'",
        )
        .get(),
    ).toBeTruthy();
  } finally {
    f.sqlite.close();
  }
});
