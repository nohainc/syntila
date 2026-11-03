import { expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { conversationFixture } from "./helpers/conversation.js";
vi.mock("../src/routes/thread-policy.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: vi.fn(async () => ({
    context: { userId: "U", user: { displayName: "User" } },
    spaceId: "P",
  })),
}));
vi.mock("../src/collaboration-events.js", () => ({
  publishCollaborationEvent: vi.fn(async () => {}),
}));
import { publishCollaborationEvent } from "../src/collaboration-events.js";
import { handleClearWorkHistory } from "../src/routes/work-lifecycle.js";
import { handleClearChatHistory } from "../src/routes/threads.js";
import { routeHandlers } from "../src/index.js";
import {
  routeWorkerRequest,
  type WorkerRouteDependencies,
} from "../src/routes/router.js";
import { HttpError, json } from "../src/routes/handlers.js";
import { RealtimeEventEnvelopeSchema } from "@syntila/protocol";
import type { SecurityEnv } from "../src/routes/handlers.js";

it("routes through production handler registration and clears remote history", async () => {
  const f = await conversationFixture();
  try {
    f.sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0054_thread_work_session_generation.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    f.sqlite.exec("UPDATE work_requests SET status='completed' WHERE id='R'");
    const response = await routeWorkerRequest(
      new Request("https://test/api/threads/W/work-history/clear", {
        method: "POST",
      }),
      { SYNTILA_DB: f.db } as unknown as Env,
      undefined,
      routeHandlers,
      {
        json,
        HttpError: HttpError as unknown as WorkerRouteDependencies["HttpError"],
        errorMessage: String,
        requireSameOriginForCookieMutation: () => undefined,
      },
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body).toMatchObject({ threadId: "W", cleared: true });
    expect(typeof body.aiHistoryClearedAt).toBe("string");
    // AI History is cut off, not deleted: the Conversation keeps every
    // request, answer and diagnostic unchanged.
    for (const table of [
      "work_requests",
      "conversations",
      "conversation_history_entries",
    ]) {
      expect(
        f.sqlite.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get()!.count,
      ).toBeGreaterThan(0);
    }
    expect(
      f.sqlite
        .prepare(
          "SELECT ai_history_cleared_at AS clearedAt FROM threads WHERE id='W'",
        )
        .get()!.clearedAt,
    ).toBe(body.aiHistoryClearedAt);
    // Later Worker context starts after everything that existed at the clear.
    const floors = f.sqlite
      .prepare(
        `SELECT c.context_floor_sequence AS floor,
           (SELECT MAX(sequence) FROM conversation_history_entries) AS latest
         FROM conversations c`,
      )
      .get()!;
    expect(floors.floor).toBe(floors.latest);
    expect(
      f.sqlite
        .prepare(
          "SELECT work_session_generation AS generation FROM threads WHERE id='W'",
        )
        .get()!.generation,
    ).toBe(1);
    expect(publishCollaborationEvent).toHaveBeenCalledWith(
      expect.anything(),
      "thread.work_cleared",
      "P",
      "W",
      { threadId: "W" },
    );
  } finally {
    f.sqlite.close();
  }
});

it("resets AI context during active work without deleting remote history", async () => {
  const f = await conversationFixture();
  try {
    f.sqlite.exec(
      "ALTER TABLE threads ADD COLUMN work_session_generation INTEGER NOT NULL DEFAULT 0",
    );
    await handleClearWorkHistory(
      new Request("https://test/api/threads/W/work-history/clear", {
        method: "POST",
      }),
      { SYNTILA_DB: f.db } as unknown as SecurityEnv,
      "W",
    );
    expect(
      f.sqlite.prepare("SELECT COUNT(*) AS count FROM work_requests").get()!
        .count,
    ).toBe(1);
    expect(
      f.sqlite
        .prepare("SELECT COUNT(*) AS count FROM conversation_history_entries")
        .get()!.count,
    ).toBeGreaterThan(0);
  } finally {
    f.sqlite.close();
  }
});

it("emits a clear event that the protocol's realtime envelope accepts", async () => {
  const f = await conversationFixture();
  try {
    f.sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0054_thread_work_session_generation.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    f.sqlite.exec("UPDATE work_requests SET status='completed' WHERE id='R'");
    f.sqlite.exec(
      "INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at) VALUES('T2','R','plan','stateless_read',1000,'plan:v1','completed','now','now'); INSERT INTO workflow_task_dependencies(task_id, depends_on_task_id) VALUES('T2', 'T');",
    );
    vi.mocked(publishCollaborationEvent).mockClear();

    await handleClearWorkHistory(
      new Request("https://test/api/threads/W/work-history/clear", {
        method: "POST",
      }),
      { SYNTILA_DB: f.db } as unknown as SecurityEnv,
      "W",
    );

    const calls = vi.mocked(publishCollaborationEvent).mock.calls;
    expect(calls).toHaveLength(1);
    const [, type, spaceId, entityId, options] = calls[0]!;
    // Validate the same envelope shape the publisher builds, using the real
    // protocol schema rather than a mock, so an invalid event name fails here.
    const envelope = RealtimeEventEnvelopeSchema.parse({
      eventId: "evt-clear-work-1",
      type,
      version: "1.1",
      timestamp: new Date().toISOString(),
      stream: { kind: "space", id: spaceId },
      spaceId,
      threadId: "W",
      sequence: 1,
      payload: { entityId, ...options },
    });
    expect(envelope.type).toBe("thread.work_cleared");
  } finally {
    f.sqlite.close();
  }
});

it("clears the whole Conversation remotely, including Work history", async () => {
  const f = await conversationFixture();
  try {
    f.sqlite.exec(
      `INSERT INTO discussion_messages(id,thread_id,author_user_id,body,created_at) VALUES('M1','W','U','hi','now'),('M2','W','U','there','now')`,
    );
    f.sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0054_thread_work_session_generation.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    f.sqlite.exec("UPDATE work_requests SET status='completed' WHERE id='R'");
    f.sqlite.exec(
      "INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at) VALUES('T2','R','plan','stateless_read',1000,'plan:v1','completed','now','now'); INSERT INTO workflow_task_dependencies(task_id, depends_on_task_id) VALUES('T2', 'T');",
    );
    vi.mocked(publishCollaborationEvent).mockClear();
    const response = await handleClearChatHistory(
      new Request("https://test/api/threads/W/chat/clear", { method: "POST" }),
      { SYNTILA_DB: f.db } as unknown as SecurityEnv,
      "W",
    );
    expect(response.status).toBe(200);
    const calls = vi.mocked(publishCollaborationEvent).mock.calls;
    expect(calls).toHaveLength(1);
    const [, type, , entityId, options] = calls[0]!;
    expect(type).toBe("thread.chat_cleared");
    expect(entityId).toBe("W");
    expect(options).toMatchObject({ threadId: "W" });
    // The deletion rides on the event so both commit together.
    for (const mutation of options!.mutations!) await mutation.run();
    expect(
      f.sqlite
        .prepare("SELECT COUNT(*) AS count FROM discussion_messages")
        .get()!.count,
    ).toBe(1);
    for (const table of [
      "work_requests",
      "workflow_tasks",
      "workflow_task_dependencies",
      "conversations",
      "conversation_history_entries",
    ]) {
      expect(
        f.sqlite.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get()!.count,
      ).toBe(0);
    }
  } finally {
    f.sqlite.close();
  }
});

it("refuses to clear the Conversation while Work is active", async () => {
  const f = await conversationFixture();
  try {
    await expect(
      handleClearChatHistory(
        new Request("https://test/api/threads/W/chat/clear", {
          method: "POST",
        }),
        { SYNTILA_DB: f.db } as unknown as SecurityEnv,
        "W",
      ),
    ).rejects.toMatchObject({ status: 409 });
  } finally {
    f.sqlite.close();
  }
});

it("announces a retried work-history clear even when the receipt replays", async () => {
  const f = await conversationFixture();
  try {
    f.sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0054_thread_work_session_generation.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    f.sqlite.exec("UPDATE work_requests SET status='completed' WHERE id='R'");
    const env = { SYNTILA_DB: f.db } as unknown as SecurityEnv;
    const clear = () =>
      handleClearWorkHistory(
        new Request("https://test/api/threads/W/work-history/clear", {
          method: "POST",
          headers: { "Idempotency-Key": "clear-work-history-key-1" },
        }),
        env,
        "W",
        { userId: "U" } as unknown as ExecutionContext,
      );
    vi.mocked(publishCollaborationEvent).mockClear();
    await clear();
    await clear();
    const types = vi
      .mocked(publishCollaborationEvent)
      .mock.calls.map((call) => call[1]);
    expect(types).toEqual(["thread.work_cleared", "thread.work_cleared"]);
  } finally {
    f.sqlite.close();
  }
});

it("keeps cleared AI exchanges readable but out of later Worker context", async () => {
  const f = await conversationFixture();
  try {
    f.sqlite.exec(
      readFileSync(
        new URL(
          "../migrations-v8/0054_thread_work_session_generation.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    f.assign("A");
    f.start("A");
    f.sqlite.exec(`
      UPDATE worker_assignments SET status='completed', updated_at='2026-10-07T10:02:00Z', output_json='{"output":{"text":"The answer"}}' WHERE id='A';
      UPDATE work_requests SET status='completed' WHERE id='R';`);
    const before = await f.turns();
    expect(before.at(-1)?.resultText).toBeTruthy();

    await handleClearWorkHistory(
      new Request("https://test/api/threads/W/work-history/clear", {
        method: "POST",
      }),
      { SYNTILA_DB: f.db } as unknown as SecurityEnv,
      "W",
    );

    // Nothing is copied into Chat and the original exchange is untouched.
    expect(
      f.sqlite
        .prepare("SELECT COUNT(*) AS count FROM discussion_messages")
        .get()!.count,
    ).toBe(1);
    expect(await f.turns()).toEqual(before);
  } finally {
    f.sqlite.close();
  }
});

it("refuses to edit an archived AI entry", async () => {
  const f = await conversationFixture();
  try {
    f.sqlite.exec(
      `INSERT INTO discussion_messages(id,thread_id,author_user_id,body,kind,work_request_id,worker_display_name,created_at)
       VALUES('A1','W','U','answer','ai_answer','R','ChatGPT','now')`,
    );
    const { authorizeThreadAccess } =
      await import("../src/routes/thread-policy.js");
    vi.mocked(authorizeThreadAccess).mockResolvedValueOnce({
      context: { userId: "U" },
      spaceId: "P",
    } as never);
    const { handleEditDiscussionMessage } =
      await import("../src/routes/threads.js");
    await expect(
      handleEditDiscussionMessage(
        new Request("https://test/api/discussion/A1", {
          method: "PATCH",
          body: JSON.stringify({ body: "changed" }),
        }),
        { SYNTILA_DB: f.db } as unknown as SecurityEnv,
        "A1",
      ),
    ).rejects.toMatchObject({ status: 409 });
  } finally {
    f.sqlite.close();
  }
});
