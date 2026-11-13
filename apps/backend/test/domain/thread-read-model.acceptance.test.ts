import { pgD1 } from "./helpers/pg-d1";
import { DatabaseSync } from "node:sqlite";
import { expect, it, vi } from "./helpers/vitest-compat";

vi.mock("../../src/domain/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeRequest: async () => ({ userId: "user-owner" }),
}));
import { handleListSpaceThreads } from "../../src/domain/routes/threads.js";

it("reads threads and configuration with distinct update timestamps", async () => {
  const sqlite = (pgD1().sqlite as unknown as DatabaseSync);
  try {
    sqlite.exec("CREATE SCHEMA IF NOT EXISTS legacy_fixture; SET search_path = legacy_fixture, public");
    sqlite.exec(`
      CREATE TABLE spaces (id TEXT, owner_user_id TEXT, kind TEXT DEFAULT 'group', settings_json TEXT);
      CREATE TABLE users (id TEXT, email TEXT, display_name TEXT);
      CREATE TABLE threads (id TEXT, space_id TEXT, name TEXT, status TEXT,
        has_other_contributions INTEGER DEFAULT 0, is_general INTEGER DEFAULT 0, access_policy_json TEXT, metadata_json TEXT NOT NULL DEFAULT '{}', lead_user_id TEXT, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ);
      CREATE TABLE thread_work_configs (thread_id TEXT, config_json TEXT, updated_at TIMESTAMPTZ);
      CREATE TABLE discussion_messages (thread_id TEXT, author_user_id TEXT, body TEXT, created_at TIMESTAMPTZ, kind TEXT NOT NULL DEFAULT 'message', worker_display_name TEXT);
      CREATE TABLE work_requests (thread_id TEXT, requested_by_user_id TEXT, status TEXT, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ);
      CREATE TABLE thread_read_states (thread_id TEXT, user_id TEXT, read_at TIMESTAMPTZ);
      CREATE TABLE user_pins (user_id TEXT, kind TEXT, target_id TEXT, pinned_at TIMESTAMPTZ, position INTEGER);
      CREATE TABLE conversations (id TEXT, thread_id TEXT);
      CREATE TABLE conversation_history_entries (conversation_id TEXT, text TEXT, occurred_at TIMESTAMPTZ, actor_type TEXT, actor_id TEXT, kind TEXT, metadata_json TEXT NOT NULL DEFAULT '{}');
      CREATE TABLE space_memberships (id TEXT, space_id TEXT, user_id TEXT, role TEXT, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ);
      CREATE TABLE support_spaces (user_id TEXT, support_user_id TEXT, space_id TEXT, created_at TIMESTAMPTZ);
      INSERT INTO spaces (id, owner_user_id, settings_json) VALUES ('space-test', 'user-owner', '{}');
      INSERT INTO users VALUES ('user-owner', 'owner@syntila.test', 'Owner');
      INSERT INTO threads (id, space_id, name, status, has_other_contributions, is_general, access_policy_json, metadata_json, lead_user_id, created_at, updated_at) VALUES ('stream-test', 'space-test', 'Test stream', 'active', 0, 0, '{}', '{}', 'user-owner', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z');
      INSERT INTO thread_work_configs VALUES ('stream-test', '{"defaultWorkflowId":"direct","bindings":{}}', '2026-01-03T00:00:00Z');
      INSERT INTO space_memberships VALUES ('membership', 'space-test', 'user-owner', 'owner', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
    `);
    const db = {
      prepare(sql: string) {
        let values: string[] = [];
        return {
          bind(...args: string[]) {
            values = args;
            return this;
          },
          async first() {
            return sqlite.prepare(sql).get(...values) ?? null;
          },
          async all() {
            return { results: sqlite.prepare(sql).all(...values) };
          },
        };
      },
    };
    const response = await handleListSpaceThreads(
      new Request("https://syntila.test/api/spaces/space-test/threads"),
      { SYNTILA_DB: db } as unknown as Parameters<
        typeof handleListSpaceThreads
      >[1],
      "space-test",
    );
    expect(response.status).toBe(200);
    const data = (await response.json()) as {
      threads: Record<string, unknown>[];
    };
    expect(data.threads).toHaveLength(1);
    expect(data.threads[0]).toMatchObject({
      id: "stream-test",
      name: "Test stream",
      lead: "user-owner",
      leadDisplayName: "Owner",
      brief: "",
      briefAuthorName: null,
      updatedAt: "2026-01-02T00:00:00.000Z",
    });

    // The latest message names its sender: a member, then a Worker answer.
    sqlite.exec(
      `INSERT INTO discussion_messages VALUES ('stream-test', 'user-owner', 'Hello team', '2026-02-01T00:00:00Z', 'message', NULL)`,
    );
    const read = async () => {
      const result = await handleListSpaceThreads(
        new Request("https://syntila.test/api/spaces/space-test/threads"),
        { SYNTILA_DB: db } as unknown as Parameters<
          typeof handleListSpaceThreads
        >[1],
        "space-test",
      );
      return ((await result.json()) as { threads: Record<string, unknown>[] })
        .threads[0];
    };
    expect(await read()).toMatchObject({
      brief: "Hello team",
      briefAuthorName: "Owner",
    });
    sqlite.exec(
      `INSERT INTO discussion_messages VALUES ('stream-test', NULL, 'Done', '2026-02-02T00:00:00Z', 'ai_answer', 'Claude')`,
    );
    expect(await read()).toMatchObject({
      brief: "Done",
      briefAuthorName: "Claude",
    });
    sqlite.exec(`
      INSERT INTO conversations VALUES ('conversation', 'stream-test');
      INSERT INTO conversation_history_entries VALUES ('conversation', 'Latest Work reply', '2026-02-03T00:00:00Z', 'worker', 'worker', 'worker_response', '{"workerDisplayName":"Gemini"}');
      INSERT INTO conversation_history_entries VALUES ('conversation', 'Internal context', '2026-02-04T00:00:00Z', 'system', NULL, 'context_updated', '{}');
    `);
    expect(await read()).toMatchObject({
      brief: "Latest Work reply",
      briefAuthorName: "Gemini",
    });
    sqlite.exec(
      `INSERT INTO discussion_messages VALUES ('stream-test', 'user-owner', 'Newest discussion', '2026-02-05T00:00:00Z', 'message', NULL)`,
    );
    expect(await read()).toMatchObject({
      brief: "Newest discussion",
      briefAuthorName: "Owner",
    });
  } finally {
    sqlite.close();
  }
});
