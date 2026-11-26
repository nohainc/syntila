import type { FixtureDb } from "./helpers/fixture-db";
import { pgD1 } from "./helpers/pg-d1";
import { basicThread, thread } from "./helpers/seed";
import { describe, expect, it, vi } from "./helpers/vitest-compat";
import { encryptProviderFailure } from "../../src/domain/provider-failure-encryption.js";

const authorize = vi.fn(async () => ({
  context: { userId: "owner" },
  spaceId: "p",
}));
vi.mock("../../src/domain/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: (...args: unknown[]) => authorize(...(args as [])),
}));
import { handleGetDiscussionMessage, handleListDiscussionMessages } from "../../src/domain/routes/threads.js";

type Page = {
  schemaVersion: number;
  messages: { id: string; body: string }[];
  nextCursor: string | null;
  newestCursor: string | null;
};

async function fixture(count = 7) {
  const handle = await pgD1();
  const sqlite = handle.sqlite as unknown as FixtureDb;
  await sqlite.exec([basicThread({ user: "owner", space: "p", thread: "w" }), thread("other-w", "p", "owner")].join("\n"));
  const insert = sqlite.prepare(
    "INSERT INTO discussion_messages(id, thread_id, author_user_id, body, references_json, edited_at, created_at) VALUES(?, ?, 'owner', ?, '[]', NULL, ?)",
  );
  // Identical timestamps exercise the stable ID tie-breaker.
  for (let i = 1; i <= count; i++)
    await insert.run(
      `m${String(i).padStart(3, "0")}`,
      "w",
      `  **${i}**\n`,
      "2026-10-06T00:00:00.000Z",
    );
  await insert.run("other", "other-w", "private", "2026-10-06T00:00:00.000Z");
  const env = { SYNTILA_DB: handle.db } as unknown as Parameters<
    typeof handleListDiscussionMessages
  >[1];
  async function page(parameters = "", id = "w") {
    const response = await handleListDiscussionMessages(
      new Request(
        `https://syntila.test/api/threads/${id}/discussion-messages${parameters}`,
      ),
      env,
      id,
    );
    return (await response.json()) as Page;
  }
  return { sqlite, page, insert, env };
}

describe("Discussion paging contract 1", () => {
  it("returns the assigned Worker's encrypted error for a failed timeline answer", async () => {
    const { sqlite, page, env } = await fixture(0);
    try {
      const key = "ab".repeat(32);
      (env as unknown as { SYNTILA_PROVIDER_FAILURE_KEY: string }).SYNTILA_PROVIDER_FAILURE_KEY = key;
      const encrypted = encryptProviderFailure({ schemaVersion: 1, source: "structured_error", providerErrorText: "Usage limit reached; retry at 4:47 AM.", failedRunResponse: "Partial work completed." }, "assignment", Buffer.from(key, "hex"));
      await sqlite.exec(`INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES ('worker','','owner','chatgpt','ChatGPT');
        INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,input_json,created_at,updated_at) VALUES ('request','w','owner','stateless','chat',1,'{}','failed','{}',now(),now());
        INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at) VALUES ('task','request','chat','stateless_read',1000,'v1','failed',now(),now());
        INSERT INTO worker_assignments(id,space_id,worker_instance_id,worker_snapshot_json,worker_type_id,task_id,status,created_at,updated_at) VALUES ('assignment','p','worker','{}','chatgpt','task','failed',now(),now());
        INSERT INTO discussion_messages(id,thread_id,author_user_id,author_actor_id,body,created_at,kind,event_type,work_request_id) VALUES ('answer','w','owner','actor-system-platform','This request did not finish.',now(),'ai_answer','work_failed','request');`);
      await sqlite.prepare("UPDATE worker_assignments SET error_json=? WHERE id='assignment'").run(JSON.stringify({ error: { code: 'quota_exhausted', message: "The provider's usage limit has been reached." }, providerFailureEncrypted: encrypted }));
      const stored = await sqlite.prepare("SELECT error_json::text AS error FROM worker_assignments WHERE id='assignment'").get();
      expect(String(stored?.error)).not.toContain('retry at 4:47');
      const response = await page();
      expect(response.messages[0]).toMatchObject({ body: 'This request did not finish.', workerFailure: { workerId: 'worker', workerName: 'ChatGPT', errorCode: 'quota_exhausted', providerFailure: { providerErrorText: 'Usage limit reached; retry at 4:47 AM.', failedRunResponse: 'Partial work completed.' } } });
      const detail = await handleGetDiscussionMessage(new Request('https://syntila.test/api/messages/answer'), env, 'answer');
      expect(await detail.json()).toMatchObject({ message: { workerFailure: { workerId: 'worker', providerFailure: { providerErrorText: 'Usage limit reached; retry at 4:47 AM.' } } } });
      authorize.mockRejectedValueOnce(new Error('denied'));
      await expect(page()).rejects.toThrow('denied');
      authorize.mockRejectedValueOnce(new Error('denied'));
      await expect(handleGetDiscussionMessage(new Request('https://syntila.test/api/messages/answer'), env, 'answer')).rejects.toThrow('denied');
      (env as unknown as { SYNTILA_PROVIDER_FAILURE_KEY: string }).SYNTILA_PROVIDER_FAILURE_KEY = 'cd'.repeat(32);
      const withoutKey = await page();
      expect(withoutKey.messages[0]).toMatchObject({ workerFailure: { errorCode: 'quota_exhausted', providerFailure: null, providerFailureUnavailable: true } });
    } finally { await sqlite.close(); }
  });
  it("defaults to newest 50 in display order, with older cursor and exact Markdown", async () => {
    const { sqlite, page } = await fixture(55);
    try {
      const result = await page();
      expect(result.schemaVersion).toBe(1);
      expect(result.messages).toHaveLength(50);
      expect(result.messages[0]?.id).toBe("m006");
      expect(result.messages[49]?.id).toBe("m055");
      expect(result.messages[0]?.body).toBe("  **6**\n");
      expect(result.nextCursor).toBeTruthy();
      const older = await page(
        `?cursor=${encodeURIComponent(result.nextCursor!)}`,
      );
      expect(older.messages.map((m) => m.id)).toEqual([
        "m001",
        "m002",
        "m003",
        "m004",
        "m005",
      ]);
      expect(older.nextCursor).toBeNull();
    } finally {
      await sqlite.close();
    }
  });
  it("walks all older pages without skipping duplicate timestamps", async () => {
    const { sqlite, page } = await fixture();
    try {
      const ids: string[] = [];
      let cursor: string | null = null;
      do {
        const result = await page(
          `?limit=2${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`,
        );
        ids.unshift(...result.messages.map((m) => m.id));
        cursor = result.nextCursor;
      } while (cursor);
      expect(ids).toEqual([
        "m001",
        "m002",
        "m003",
        "m004",
        "m005",
        "m006",
        "m007",
      ]);
    } finally {
      await sqlite.close();
    }
  });
  it("catches up new messages in forward pages and returns stable empty anchor", async () => {
    const { sqlite, page, insert } = await fixture(2);
    try {
      const head = await page();
      for (let i = 3; i <= 7; i++)
        await insert.run(`m00${i}`, "w", `new ${i}`, "2026-10-06T00:00:00.000Z");
      let cursor = head.newestCursor!;
      const ids: string[] = [];
      let next: string | null;
      do {
        const result = await page(
          `?limit=2&after=${encodeURIComponent(cursor)}`,
        );
        ids.push(...result.messages.map((m) => m.id));
        next = result.nextCursor;
        cursor = next ?? result.newestCursor!;
      } while (next);
      expect(ids).toEqual(["m003", "m004", "m005", "m006", "m007"]);
      const empty = await page(`?after=${encodeURIComponent(cursor)}`);
      expect(empty.messages).toEqual([]);
      expect(empty.newestCursor).toBe(cursor);
    } finally {
      await sqlite.close();
    }
  });
  it("rejects invalid limits, malformed and cross-Thread cursors", async () => {
    const { sqlite, page } = await fixture();
    try {
      for (const query of [
        "?limit=0",
        "?limit=101",
        "?limit=abc",
        "?limit=1.5",
        "?cursor=",
        "?cursor=bad",
        "?cursor=x&after=y",
      ]) {
        await expect(page(query)).rejects.toMatchObject({ status: 400 });
      }
      const head = await page("?limit=2");
      await expect(page(`?cursor=${encodeURIComponent(head.nextCursor!)}`, "other-w"),).rejects.toMatchObject({ status: 400 });
    } finally {
      await sqlite.close();
    }
  });
  it("authorizes every page before accessing Discussion data", async () => {
    const { sqlite, page } = await fixture();
    try {
      authorize.mockRejectedValueOnce(new Error("denied"));
      await expect(page()).rejects.toThrow("denied");
    } finally {
      await sqlite.close();
    }
  });
});
