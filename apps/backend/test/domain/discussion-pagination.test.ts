import { pgD1 } from "./helpers/pg-d1";
import { basicThread, thread } from "./helpers/seed";
import { DatabaseSync } from "node:sqlite";
import { describe, expect, it, vi } from "./helpers/vitest-compat";

const authorize = vi.fn(async () => ({
  context: { userId: "owner" },
  spaceId: "p",
}));
vi.mock("../../src/domain/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: (...args: unknown[]) => authorize(...(args as [])),
}));
import { handleListDiscussionMessages } from "../../src/domain/routes/threads.js";

type Page = {
  schemaVersion: number;
  messages: { id: string; body: string }[];
  nextCursor: string | null;
  newestCursor: string | null;
};

function fixture(count = 7) {
  const sqlite = (pgD1().sqlite as unknown as DatabaseSync);
  sqlite.exec([basicThread({ user: "owner", space: "p", thread: "w" }), thread("other-w", "p", "owner")].join("\n"));
  const insert = sqlite.prepare(
    "INSERT INTO discussion_messages(id, thread_id, author_user_id, body, references_json, edited_at, created_at) VALUES(?, ?, 'owner', ?, '[]', NULL, ?)",
  );
  // Identical timestamps exercise the stable ID tie-breaker.
  for (let i = 1; i <= count; i++)
    insert.run(
      `m${String(i).padStart(3, "0")}`,
      "w",
      `  **${i}**\n`,
      "2026-10-06T00:00:00.000Z",
    );
  insert.run("other", "other-w", "private", "2026-10-06T00:00:00.000Z");
  const db = {
    prepare(sql: string) {
      let values: (string | number)[] = [];
      return {
        bind(...args: (string | number)[]) {
          values = args;
          return this;
        },
        async all() {
          return { results: sqlite.prepare(sql).all(...values) };
        },
      };
    },
  };
  const env = { SYNTILA_DB: db } as unknown as Parameters<
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
  return { sqlite, page, insert };
}

describe("Discussion paging contract 1", () => {
  it("defaults to newest 50 in display order, with older cursor and exact Markdown", async () => {
    const { sqlite, page } = fixture(55);
    try {
      const result = await page();
      expect(result.schemaVersion).toBe(1);
      expect(result.messages).toHaveLength(50);
      expect(result.messages[0]?.id).toBe("m006");
      expect(result.messages[49]?.id).toBe("m055");
      expect(result.messages[0]?.body).toBe("  **6**\n");
      expect(result.nextCursor).toBeTruthy();
      const older = await page(
        `?before=${encodeURIComponent(result.nextCursor!)}`,
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
      sqlite.close();
    }
  });
  it("walks all older pages without skipping duplicate timestamps", async () => {
    const { sqlite, page } = fixture();
    try {
      const ids: string[] = [];
      let cursor: string | null = null;
      do {
        const result = await page(
          `?limit=2${cursor ? `&before=${encodeURIComponent(cursor)}` : ""}`,
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
      sqlite.close();
    }
  });
  it("catches up new messages in forward pages and returns stable empty anchor", async () => {
    const { sqlite, page, insert } = fixture(2);
    try {
      const head = await page();
      for (let i = 3; i <= 7; i++)
        insert.run(`m00${i}`, "w", `new ${i}`, "2026-10-06T00:00:00.000Z");
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
      sqlite.close();
    }
  });
  it("rejects invalid limits, malformed and cross-Thread cursors", async () => {
    const { sqlite, page } = fixture();
    try {
      for (const query of [
        "?limit=0",
        "?limit=101",
        "?limit=abc",
        "?limit=1.5",
        "?before=",
        "?before=bad",
        "?before=x&after=y",
      ]) {
        await expect(page(query)).rejects.toMatchObject({ status: 400 });
      }
      const head = await page("?limit=2");
      await expect(
        page(`?before=${encodeURIComponent(head.nextCursor!)}`, "other-w"),
      ).rejects.toMatchObject({ status: 400 });
    } finally {
      sqlite.close();
    }
  });
  it("authorizes every page before accessing Discussion data", async () => {
    const { sqlite, page } = fixture();
    try {
      authorize.mockRejectedValueOnce(new Error("denied"));
      await expect(page()).rejects.toThrow("denied");
    } finally {
      sqlite.close();
    }
  });
});
