import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";

it("preserves existing General Threads and allows empty personal Spaces", () => {
  const { sqlite } = sqliteD1({ beforeOptionalDirectThread: true });
  const now = "2026-01-01T00:00:00Z";
  sqlite.prepare("INSERT INTO users (id, email, display_name, status, created_at, updated_at) VALUES (?, ?, ?, 'active', ?, ?)").run("a", "a@example.com", "A", now, now);
  sqlite.prepare("INSERT INTO users (id, email, display_name, status, created_at, updated_at) VALUES (?, ?, ?, 'active', ?, ?)").run("b", "b@example.com", "B", now, now);
  sqlite.prepare("INSERT INTO spaces (id, owner_user_id, name, kind, settings_json, created_at, updated_at) VALUES ('s', 'a', 'Direct', 'direct', '{}', ?, ?)").run(now, now);
  sqlite.prepare("INSERT INTO threads (id, space_id, name, status, lead_user_id, is_general, created_at, updated_at) VALUES ('t', 's', 'General', 'active', 'a', 1, ?, ?)").run(now, now);
  sqlite.prepare("INSERT INTO direct_spaces VALUES ('s', 'a', 'b', 't', ?)").run(now);
  sqlite.exec(readFileSync(new URL("../migrations-v8/0107_optional_direct_general_thread.sql", import.meta.url), "utf8"));
  expect(sqlite.prepare("SELECT general_thread_id FROM direct_spaces WHERE space_id = 's'").get()).toEqual({ general_thread_id: "t" });
  expect(() => sqlite.prepare("DELETE FROM threads WHERE id = 't'").run()).toThrow();
  expect(() => sqlite.prepare("UPDATE direct_spaces SET general_thread_id = 'missing' WHERE space_id = 's'").run()).toThrow();
  sqlite.prepare("UPDATE direct_spaces SET general_thread_id = NULL WHERE space_id = 's'").run();
  expect(sqlite.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
});
