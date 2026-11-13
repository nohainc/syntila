import { expect, it, vi } from "./helpers/vitest-compat";
import { readFileSync } from "node:fs";
import { conversationFixture } from "./helpers/conversation.js";
import { recordAssignmentResult } from "../../src/domain/assignment-dispatcher.js";
const { authorize } = vi.hoisted(() => ({
  authorize: vi.fn(async () => ({})),
}));
vi.mock("../../src/domain/routes/thread-policy.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: authorize,
}));
import { handleListConversationHistory } from "../../src/domain/routes/conversation-history.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";

it("records all six canonical fact kinds atomically and preserves exact response text once", async () => {
  const f = await conversationFixture();
  f.assign("A");
  f.start("A");
  const conversation = String(
    f.sqlite.prepare("SELECT id FROM conversations").get()!.id,
  );
  const reply = "**Full reply**\n" + "x".repeat(26000);
  await recordAssignmentResult(f.db as unknown as D1Database, "A", {
    assignmentId: "A",
    status: "completed",
    output: { text: reply },
    artifactIds: [],
    completedAt: "now",
  });
  await recordAssignmentResult(f.db as unknown as D1Database, "A", {
    assignmentId: "A",
    status: "completed",
    output: { text: "rewritten" },
    artifactIds: [],
    completedAt: "2030-01-01T00:00:00.000Z",
  });
  f.sqlite
    .exec(`INSERT INTO artifacts(id,space_id,assignment_id,content_digest,storage_key,created_at) VALUES('ART','P','A','digest','private-storage-key','now');
 UPDATE conversations SET conversation_revision = 2, context_revision = 2;`);
  const rows = f.sqlite
    .prepare(
      "SELECT sequence,kind,text,metadata_json FROM conversation_history_entries WHERE conversation_id=? ORDER BY sequence",
    )
    .all(conversation);
  expect(new Set(rows.map((r) => r.kind))).toEqual(
    new Set([
      "user_message",
      "worker_response",
      "workflow_event",
      "execution_event",
      "artifact_event",
      "context_event",
    ]),
  );
  expect(rows.map((r) => r.sequence)).toEqual(rows.map((_, i) => i + 1));
  expect(
    rows.filter((r) => r.kind === "worker_response").map((r) => r.text),
  ).toEqual([reply]);
  expect(rows.find((r) => r.kind === "user_message")!.text).toBe(
    "**Exact user text**",
  );
  expect(JSON.stringify(rows)).not.toContain("private-storage-key");
  expect(() =>
    f.sqlite.exec("UPDATE conversation_history_entries SET text='rewritten'"),
  ).toThrow("append-only");
  expect(() =>
    f.sqlite.exec("DELETE FROM conversation_history_entries"),
  ).toThrow("cannot be deleted");
  // Canonical facts survive execution/session-cache cleanup.
  f.sqlite.exec(
    "DELETE FROM worker_assignments WHERE id='A'; DELETE FROM work_requests WHERE id='R';",
  );
  expect(
    f.sqlite
      .prepare(
        "SELECT text FROM conversation_history_entries WHERE kind='worker_response'",
      )
      .get()?.text,
  ).toBe(reply);
  f.sqlite.exec("DELETE FROM conversations");
  expect(
    f.sqlite
      .prepare("SELECT count(*) AS n FROM conversation_history_entries")
      .get()?.n,
  ).toBe(0);
  f.sqlite.close();
});

it("scopes reads before history access and paginates against a stable high-water mark", async () => {
  const f = await conversationFixture();
  f.assign("A");
  f.start("A");
  const conversation = String(
    f.sqlite.prepare("SELECT id FROM conversations").get()!.id,
  );
  const env = { SYNTILA_DB: f.db } as unknown as SecurityEnv;
  const req = (query = "") =>
    new Request(
      `https://cloud.test/api/threads/W/conversations/${conversation}/history${query}`,
    );
  const first = (await (
    await handleListConversationHistory(req("?limit=1"), env, "W", conversation)
  ).json()) as {
    entries: { sequence: number }[];
    throughSequence: number;
    nextCursor: { afterSequence: number; throughSequence: number };
  };
  expect(first.entries).toHaveLength(1);
  f.sqlite.exec("UPDATE work_requests SET status='waiting',updated_at='2030-01-01T00:00:00.000Z'");
  const seen = [first.entries[0]!.sequence];
  let cursor = first.nextCursor;
  while (cursor) {
    const page = (await (
      await handleListConversationHistory(
        req(
          `?limit=1&afterSequence=${cursor.afterSequence}&throughSequence=${cursor.throughSequence}`,
        ),
        env,
        "W",
        conversation,
      )
    ).json()) as typeof first;
    seen.push(...page.entries.map((e) => e.sequence));
    cursor = page.nextCursor;
  }
  expect(seen).toEqual(
    Array.from({ length: first.throughSequence }, (_, i) => i + 1),
  );
  await expect(
    handleListConversationHistory(req(), env, "OTHER", conversation),
  ).rejects.toMatchObject({ status: 404 });
  for (const query of [
    "?limit=0",
    "?limit=101",
    "?afterSequence=-1",
    "?afterSequence=Infinity",
    "?throughSequence=999999",
  ])
    await expect(
      handleListConversationHistory(req(query), env, "W", conversation),
    ).rejects.toMatchObject({ status: 400 });
  authorize.mockRejectedValueOnce(new Error("access denied"));
  await expect(
    handleListConversationHistory(req(), env, "W", conversation),
  ).rejects.toThrow("access denied");
  f.sqlite.close();
});

it("rolls canonical events back with failed source mutations", async () => {
  const f = await conversationFixture();
  const before = f.sqlite
    .prepare("SELECT count(*) AS n FROM conversation_history_entries")
    .get()?.n;
  await expect(
    f.db.batch([
      f.db.prepare("UPDATE work_requests SET status='waiting'"),
      f.db.prepare("INSERT INTO conversations(id) VALUES('invalid')"),
    ]),
  ).rejects.toThrow();
  expect(
    f.sqlite
      .prepare("SELECT count(*) AS n FROM conversation_history_entries")
      .get()?.n,
  ).toBe(before);
  expect(
    f.sqlite.prepare("SELECT status FROM work_requests").get()?.status,
  ).toBe("running");
  f.sqlite.close();
});

