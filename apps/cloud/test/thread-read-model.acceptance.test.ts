import { DatabaseSync } from "node:sqlite";
import { expect, it, vi } from "vitest";

vi.mock("../src/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeRequest: async () => ({ userId: "user-owner" }),
}));
import { handleListSpaceThreads } from "../src/routes/threads.js";

it("reads threads and configuration with distinct update timestamps", async () => {
  const sqlite = new DatabaseSync(":memory:");
  try {
    sqlite.exec(`
      CREATE TABLE spaces (id TEXT, owner_user_id TEXT, kind TEXT DEFAULT 'group', settings_json TEXT);
      CREATE TABLE users (id TEXT, email TEXT, display_name TEXT);
      CREATE TABLE threads (id TEXT, space_id TEXT, name TEXT, status TEXT,
        has_other_contributions INTEGER DEFAULT 0, is_general INTEGER DEFAULT 0, access_policy_json TEXT, metadata_json TEXT NOT NULL DEFAULT '{}', lead_user_id TEXT, created_at TEXT, updated_at TEXT);
      CREATE TABLE thread_work_configs (thread_id TEXT, config_json TEXT, updated_at TEXT);
      CREATE TABLE discussion_messages (thread_id TEXT, author_user_id TEXT, body TEXT, created_at TEXT, kind TEXT NOT NULL DEFAULT 'message', worker_display_name TEXT);
      CREATE TABLE work_requests (thread_id TEXT, requested_by_user_id TEXT, status TEXT, created_at TEXT, updated_at TEXT);
      CREATE TABLE thread_read_states (thread_id TEXT, user_id TEXT, read_at TEXT);
      CREATE TABLE user_pins (user_id TEXT, kind TEXT, target_id TEXT, pinned_at TEXT, position INTEGER);
      CREATE TABLE conversations (id TEXT, thread_id TEXT);
      CREATE TABLE conversation_history_entries (conversation_id TEXT, text TEXT, occurred_at TEXT, actor_type TEXT, actor_id TEXT, kind TEXT, metadata_json TEXT NOT NULL DEFAULT '{}');
      CREATE TABLE space_memberships (id TEXT, space_id TEXT, user_id TEXT, role TEXT, created_at TEXT, updated_at TEXT);
      INSERT INTO spaces (id, owner_user_id, settings_json) VALUES ('space-test', 'user-owner', '{}');
      INSERT INTO users VALUES ('user-owner', 'owner@syntila.test', 'Owner');
      INSERT INTO threads (id, space_id, name, status, has_other_contributions, is_general, access_policy_json, metadata_json, lead_user_id, created_at, updated_at) VALUES ('stream-test', 'space-test', 'Test stream', 'active', 0, 0, '{}', '{}', 'user-owner', 'created', 'stream-updated');
      INSERT INTO thread_work_configs VALUES ('stream-test', '{"defaultWorkflowId":"direct","bindings":{}}', 'config-updated');
      INSERT INTO space_memberships VALUES ('membership', 'space-test', 'user-owner', 'owner', 'created', 'updated');
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
      updatedAt: "stream-updated",
    });

    // The latest message names its sender: a member, then a Worker answer.
    sqlite.exec(
      `INSERT INTO discussion_messages VALUES ('stream-test', 'user-owner', 'Hello team', 'm1', 'message', NULL)`,
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
      `INSERT INTO discussion_messages VALUES ('stream-test', NULL, 'Done', 'm2', 'ai_answer', 'Claude')`,
    );
    expect(await read()).toMatchObject({
      brief: "Done",
      briefAuthorName: "Claude",
    });
    sqlite.exec(`
      INSERT INTO conversations VALUES ('conversation', 'stream-test');
      INSERT INTO conversation_history_entries VALUES ('conversation', 'Latest Work reply', 'm3', 'worker', 'worker', 'worker_response', '{"workerDisplayName":"Gemini"}');
      INSERT INTO conversation_history_entries VALUES ('conversation', 'Internal context', 'm4', 'system', NULL, 'context_updated', '{}');
    `);
    expect(await read()).toMatchObject({
      brief: "Latest Work reply",
      briefAuthorName: "Gemini",
    });
    sqlite.exec(
      `INSERT INTO discussion_messages VALUES ('stream-test', 'user-owner', 'Newest discussion', 'm5', 'message', NULL)`,
    );
    expect(await read()).toMatchObject({
      brief: "Newest discussion",
      briefAuthorName: "Owner",
    });
  } finally {
    sqlite.close();
  }
});
