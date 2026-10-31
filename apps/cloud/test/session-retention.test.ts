import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { describe, expect, it } from "vitest";
import { pruneEndedAuthSessions } from "../src/auth/session-retention.js";

function d1(sqlite: DatabaseSync): D1Database {
  const prepare = (sql: string) => ({
    bind: (...values: SQLInputValue[]) => ({
      run: async () => ({
        meta: { changes: Number(sqlite.prepare(sql).run(...values).changes) },
      }),
    }),
  });
  return {
    prepare,
    batch: async (statements: { run(): Promise<unknown> }[]) =>
      Promise.all(statements.map((statement) => statement.run())),
  } as unknown as D1Database;
}

describe("auth session retention", () => {
  it("deletes sessions and intents that ended more than seven days ago", async () => {
    const sqlite = new DatabaseSync(":memory:");
    sqlite.exec(`
      CREATE TABLE desktop_human_sessions (id TEXT, expires_at TEXT, revoked_at TEXT);
      CREATE TABLE desktop_auth_intents (id TEXT, expires_at TEXT);
      CREATE TABLE auth_sessions (id TEXT, expires_at TEXT);
      INSERT INTO desktop_human_sessions VALUES
        ('live', '2026-11-20T00:00:00.000Z', NULL),
        ('recently-revoked', '2026-11-20T00:00:00.000Z', '2026-10-30T00:00:00.000Z'),
        ('old-revoked', '2026-11-20T00:00:00.000Z', '2026-10-01T00:00:00.000Z'),
        ('old-expired', '2026-10-01T00:00:00.000Z', NULL);
      INSERT INTO desktop_auth_intents VALUES
        ('old', '2026-10-01T00:00:00.000Z'), ('recent', '2026-10-30T00:00:00.000Z');
      INSERT INTO auth_sessions VALUES
        ('old', '2026-10-01T00:00:00.000Z'), ('live', '2026-11-10T00:00:00.000Z');
    `);

    const deleted = await pruneEndedAuthSessions(
      d1(sqlite),
      new Date("2026-10-31T00:00:00.000Z"),
    );

    const ids = (table: string) =>
      sqlite
        .prepare(`SELECT id FROM ${table} ORDER BY id`)
        .all()
        .map((row) => row.id);
    expect(deleted).toBe(4);
    expect(ids("desktop_human_sessions")).toEqual(["live", "recently-revoked"]);
    expect(ids("desktop_auth_intents")).toEqual(["recent"]);
    expect(ids("auth_sessions")).toEqual(["live"]);
  });
});
