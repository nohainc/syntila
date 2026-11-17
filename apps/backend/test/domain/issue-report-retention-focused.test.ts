import { describe, expect, it } from "bun:test";
import { pgD1 } from "./helpers/pg-d1";
import { pruneExpiredIssueReports } from "../../src/domain/issue-report-retention.js";

describe("issue report retention", () => {
  it("removes reports older than 30 days after their attachments, retaining newer or failed attachments", async () => {
    const { sqlite, db } = await pgD1();
    await sqlite.exec(`INSERT INTO issue_reports
      (id, public_reference, request_id, attempt_key, component, error_code, failure_stage, fingerprint, status, diagnostic_state, created_at, updated_at)
      VALUES ('old','ref-old','req','old','test','error','test','fp','open','complete','2026-09-01T00:00:00Z','2026-09-01T00:00:00Z'),
             ('new','ref-new','req','new','test','error','test','fp','open','complete','2026-09-02T00:00:00Z','2026-09-02T00:00:00Z'),
             ('failed','ref-failed','req','failed','test','error','test','fp','open','complete','2026-08-01T00:00:00Z','2026-08-01T00:00:00Z');
      INSERT INTO issue_report_diagnostics (report_id, diagnostic_json, bundle_key, created_at)
      VALUES ('old', '{}', 'old-file', '2026-09-01T00:00:00Z'), ('failed', '{}', 'failed-file', '2026-08-01T00:00:00Z');`);
    const bucket = { delete: async (key: string) => { if (key === "failed-file") throw new Error("unavailable"); } } as unknown as R2Bucket;
    expect(await pruneExpiredIssueReports({ SYNTILA_DB: db }, bucket, new Date("2026-10-02T00:00:00.000Z"))).toBe(1);
    expect(await sqlite.prepare("SELECT id FROM issue_reports ORDER BY id").all()).toEqual([{ id: "failed" }, { id: "new" }]);
  });
});
