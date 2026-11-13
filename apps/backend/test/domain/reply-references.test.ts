import { describe, expect, it } from "./helpers/vitest-compat";
import { BUILTIN_WORKFLOW_CATALOG } from "@syntila/core";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import {
  REPLY_EXCERPT_MAX_CHARS,
  resolveReplyReference,
  storedReplyReference,
} from "../../src/domain/routes/reply-references.js";
import {
  renderWorkStepPrompt,
  workStepPromptInputs,
} from "../../src/domain/workflow-prompts.js";

function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec("PRAGMA foreign_keys = OFF");
  sqlite.exec(`
    INSERT INTO users(id,email,display_name,created_at,updated_at)
      VALUES ('ann','a@test','Ann','now','now');
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES ('S','ann','S','now','now');
    INSERT INTO threads (id, space_id, name, status, lead_user_id, created_at, updated_at)
      VALUES ('T', 'S', 'Thread', 'active', 'ann', 'now', 'now'),
             ('Other', 'S', 'Other', 'active', 'ann', 'now', 'now');
    INSERT INTO discussion_messages (id, thread_id, author_user_id, body, created_at)
      VALUES ('m1', 'T', 'ann', 'Can we ship on Friday?', 'now'),
             ('m-other', 'Other', 'ann', 'elsewhere', 'now');
    INSERT INTO discussion_messages (id, thread_id, author_user_id, body, created_at, attachments_json)
      VALUES ('m-file', 'T', 'ann', '', 'now', '[{"name":"spec.pdf"}]');
    INSERT INTO discussion_messages (id, thread_id, author_user_id, body, created_at, kind, worker_display_name)
      VALUES ('m-ai', 'T', 'ann', 'Archived answer', 'now', 'ai_answer', 'Gemini');
    INSERT INTO discussion_messages (id, thread_id, author_user_id, body, created_at, event_type)
      VALUES ('m-removed', 'T', 'ann', 'Message removed', 'now', 'message.removed');
    INSERT INTO work_requests (id, thread_id, requested_by_user_id, mode,
        workflow_id, workflow_version, workflow_snapshot_json, status,
        input_json, created_at, updated_at)
      VALUES ('wr', 'T', 'ann', 'stateless', 'direct', 2, '{}', 'completed',
        '{"originalRequest":"Summarise the release notes"}', 'now', 'now'),
             ('wr-open', 'T', 'ann', 'stateless', 'direct', 2, '{}', 'running',
        '{"originalRequest":"Still running"}', 'now', 'now');
  `);
  const workerTypeId = (
    sqlite
      .prepare("SELECT worker_type_id AS id FROM worker_catalog LIMIT 1")
      .get() as { id: string }
  ).id;
  const workerName = (
    sqlite
      .prepare(
        "SELECT display_name AS name FROM worker_catalog WHERE worker_type_id = ?",
      )
      .get(workerTypeId) as { name: string }
  ).name;
  sqlite
    .prepare(
      `INSERT INTO workflow_tasks (id, work_request_id, step_kind, execution_mode,
        timeout_ms, prompt_profile_version, status, output_json, created_at, updated_at)
       VALUES ('task', 'wr', 'implement', 'stateful_thread', 60000, 'v1',
        'completed', ?, 'now', 'now')`,
    )
    .run(JSON.stringify({ workerTypeId, text: "Here is the summary." }));
  const resolve = (raw: unknown, thread = "T") =>
    resolveReplyReference(db as unknown as D1Database, thread, raw);
  return { sqlite, resolve, workerName };
}

describe("Reply v1 references", () => {
  it("snapshots a person's message, an AI entry and a file-only message", async () => {
    const { sqlite, resolve } = fixture();
    try {
      expect(await resolve({ kind: "message", id: "m1" })).toEqual({
        kind: "message",
        id: "m1",
        authorName: "Ann",
        excerpt: "Can we ship on Friday?",
      });
      expect(await resolve({ kind: "message", id: "m-ai" })).toMatchObject({
        authorName: "Gemini",
        excerpt: "Archived answer",
      });
      expect(await resolve({ kind: "message", id: "m-file" })).toMatchObject({
        excerpt: "📎 spec.pdf",
      });
    } finally {
      sqlite.close();
    }
  });

  it("snapshots a request and its AI response", async () => {
    const { sqlite, resolve, workerName } = fixture();
    try {
      expect(await resolve({ kind: "request", id: "wr" })).toEqual({
        kind: "request",
        id: "wr",
        authorName: "Ann",
        excerpt: "Summarise the release notes",
      });
      expect(await resolve({ kind: "response", id: "wr" })).toEqual({
        kind: "response",
        id: "wr",
        authorName: workerName,
        excerpt: "Here is the summary.",
      });
    } finally {
      sqlite.close();
    }
  });

  it("rejects targets outside the Thread, removed messages and empty responses", async () => {
    const { sqlite, resolve } = fixture();
    try {
      await expect(resolve({ kind: "message", id: "m-other" })).rejects.toThrow(
        "not in this Thread",
      );
      await expect(
        resolve({ kind: "request", id: "wr" }, "Other"),
      ).rejects.toThrow("not in this Thread");
      await expect(
        resolve({ kind: "message", id: "m-removed" }),
      ).rejects.toThrow("removed message");
      await expect(
        resolve({ kind: "response", id: "wr-open" }),
      ).rejects.toThrow("no text");
      await expect(resolve({ kind: "user", id: "m1" })).rejects.toThrow(
        "replyTo must name",
      );
      expect(await resolve(undefined)).toBeNull();
    } finally {
      sqlite.close();
    }
  });

  it("bounds long excerpts", async () => {
    const { sqlite, resolve } = fixture();
    try {
      sqlite.exec(
        `UPDATE discussion_messages SET body = '${"x".repeat(5000)}' WHERE id = 'm1'`,
      );
      const reply = await resolve({ kind: "message", id: "m1" });
      expect(reply!.excerpt.length).toBe(REPLY_EXCERPT_MAX_CHARS);
      expect(reply!.excerpt.endsWith("…")).toBe(true);
    } finally {
      sqlite.close();
    }
  });

  it("ignores malformed stored snapshots", () => {
    expect(storedReplyReference(null)).toBeNull();
    expect(storedReplyReference('{"kind":"message"}')).toBeNull();
    expect(
      storedReplyReference(
        '{"kind":"response","id":"wr","authorName":"Grok","excerpt":"Hi"}',
      ),
    ).toEqual({
      kind: "response",
      id: "wr",
      authorName: "Grok",
      excerpt: "Hi",
    });
  });

  it("gives the AI Worker the quoted message as context", () => {
    const workflow = BUILTIN_WORKFLOW_CATALOG["direct:v2"]!;
    const inputs = workStepPromptInputs(
      {
        originalRequest: "Make it shorter",
        replyTo: {
          kind: "response",
          id: "wr",
          authorName: "Grok",
          excerpt: "Line one\nLine two",
        },
      },
      {},
    );
    const prompt = renderWorkStepPrompt(workflow, workflow.steps[0]!, inputs);
    expect(prompt).toContain(
      "The user is replying to this earlier message:\nGrok (AI response):\n> Line one\n> Line two",
    );
    expect(prompt.indexOf("replying to")).toBeLessThan(
      prompt.indexOf("Make it shorter"),
    );
    const plain = renderWorkStepPrompt(
      workflow,
      workflow.steps[0]!,
      workStepPromptInputs({ originalRequest: "Hi" }, {}),
    );
    expect(plain).not.toContain("replying to");
  });
});
