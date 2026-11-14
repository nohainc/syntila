import { Database } from "bun:sqlite";
import { describe, expect, it } from "bun:test";
import { pruneExpiredIssueReports } from "../../src/domain/issue-report-retention.js";

describe("issue report retention", () => {
  it("removes reports older than 30 days after their attachments, retaining newer or failed attachments", async () => {
    const sqlite = new Database(":memory:");
    sqlite.exec(`CREATE TABLE issue_reports (id TEXT PRIMARY KEY, created_at TEXT NOT NULL);
      CREATE TABLE issue_report_diagnostics (report_id TEXT, bundle_key TEXT);
      INSERT INTO issue_reports VALUES ('old', '2026-09-01T00:00:00.000Z'), ('new', '2026-09-02T00:00:00.000Z'), ('failed', '2026-08-01T00:00:00.000Z');
      INSERT INTO issue_report_diagnostics VALUES ('old', 'old-file'), ('failed', 'failed-file');`);
    const db = { prepare: (sql: string) => ({ bind: (...args: (string | number)[]) => ({
      all: async () => ({ results: sqlite.query(sql).all(...args) }),
      run: async () => ({ meta: { changes: sqlite.query(sql).run(...args).changes } }),
    }) }) } as unknown as D1Database;
    const bucket = { delete: async (key: string) => { if (key === "failed-file") throw new Error("unavailable"); } } as unknown as R2Bucket;
    expect(await pruneExpiredIssueReports(db, bucket, new Date("2026-10-02T00:00:00.000Z"))).toBe(1);
    expect(sqlite.query("SELECT id FROM issue_reports ORDER BY id").all()).toEqual([{ id: "failed" }, { id: "new" }]);
    sqlite.close();
  });
});
