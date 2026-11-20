import { expect, it } from "./helpers/vitest-compat";
import { conversationFixture } from "./helpers/conversation.js";
import { recordAssignmentResult } from "../../src/domain/assignment-dispatcher.js";

async function finish(f: Awaited<ReturnType<typeof conversationFixture>>) {
  await f.assign("A");
  await recordAssignmentResult(f.db as unknown as D1Database, "A", {
    assignmentId: "A", status: "completed", output: { text: "**Answer**" }, artifactIds: [], completedAt: "x",
  });
  await f.sqlite.exec("UPDATE work_requests SET status='completed' WHERE id='R'");
}

it("writes one request and one answer per Work Request, however often it replays", async () => {
  const f = await conversationFixture();
  await finish(f);
  for (let i = 0; i < 3; i++) await f.sqlite.exec("SELECT backfill_ai_timeline((SELECT thread_id FROM work_requests WHERE id='R'))");
  const rows = (await f.sqlite.prepare("SELECT id, kind, body, author_actor_id, author_display_snapshot FROM discussion_messages WHERE work_request_id='R' ORDER BY kind").all()) as Array<Record<string, unknown>>;
  expect(rows.map((r) => r.kind)).toEqual(["ai_answer", "ai_request"]);
  expect(rows[0]).toMatchObject({ id: "ai-answer-R", body: "**Answer**" });
  expect(rows[0]!.author_actor_id).not.toBeNull();
  expect(rows[1]).toMatchObject({ id: "ai-request-R", body: "**Exact user text**" });
  await f.sqlite.close();
});

it("keeps the author name written at the time after the Worker is renamed", async () => {
  const f = await conversationFixture();
  await finish(f);
  await f.sqlite.exec("SELECT backfill_ai_timeline((SELECT thread_id FROM work_requests WHERE id='R'))");
  const before = (await f.sqlite.prepare("SELECT author_display_snapshot AS s FROM discussion_messages WHERE id='ai-answer-R'").get())?.s;
  await f.sqlite.exec("UPDATE worker_catalog SET display_name = 'Renamed' WHERE worker_type_id = 'chatgpt'");
  expect((await f.sqlite.prepare("SELECT author_display_snapshot AS s FROM discussion_messages WHERE id='ai-answer-R'").get())?.s).toBe(before);
  await f.sqlite.close();
});

it("shows a failed or cancelled request as a fixed System item, and a later answer replaces it", async () => {
  const f = await conversationFixture();
  await f.assign("A");
  await f.sqlite.exec("UPDATE work_requests SET status='failed' WHERE id='R'");
  await f.sqlite.exec("SELECT record_ai_outcome('R')");
  await f.sqlite.exec("SELECT record_ai_outcome('R')");
  const failed = (await f.sqlite.prepare("SELECT body, event_type, author_actor_id FROM discussion_messages WHERE id='ai-answer-R'").all()) as Array<Record<string, unknown>>;
  expect(failed).toEqual([{ body: "This request did not finish.", event_type: "work_failed", author_actor_id: "actor-system-platform" }]);

  await f.sqlite.exec("UPDATE work_requests SET status='cancelled' WHERE id='R'");
  await f.sqlite.exec("SELECT record_ai_outcome('R')");
  expect((await f.sqlite.prepare("SELECT body FROM discussion_messages WHERE id='ai-answer-R'").get())?.body).toBe("This request was cancelled.");

  // A retry removes the item; the answer of the retried request is then a normal one.
  await f.sqlite.exec("SELECT record_ai_outcome_clear('R')");
  expect(((await f.sqlite.prepare("SELECT id FROM discussion_messages WHERE id='ai-answer-R'").all()) as unknown[]).length).toBe(0);
  await f.sqlite.exec("UPDATE work_requests SET status='failed' WHERE id='R'");
  await f.sqlite.exec("SELECT record_ai_outcome('R')");
  await recordAssignmentResult(f.db as unknown as D1Database, "A", {
    assignmentId: "A", status: "completed", output: { text: "**Answer**" }, artifactIds: [], completedAt: "x",
  });
  await f.sqlite.exec("UPDATE work_requests SET status='completed' WHERE id='R'");
  await f.sqlite.exec("SELECT record_ai_answer('R')");
  expect(await f.sqlite.prepare("SELECT body, event_type FROM discussion_messages WHERE id='ai-answer-R'").get()).toMatchObject({ body: "**Answer**", event_type: null });
  // An outcome never overwrites a real answer.
  await f.sqlite.exec("UPDATE work_requests SET status='failed' WHERE id='R'");
  await f.sqlite.exec("SELECT record_ai_outcome('R')");
  expect((await f.sqlite.prepare("SELECT body FROM discussion_messages WHERE id='ai-answer-R'").get())?.body).toBe("**Answer**");
  await f.sqlite.close();
});
