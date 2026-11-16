import { inTransaction } from "../platform/tx-env.js";
import { dataOf } from "../platform/data.js";
const DAY_MS = 24 * 60 * 60 * 1000;
const MAX_REPORTS_PER_RUN = 100;

/** Diagnostic reports are retained for support investigation for 30 days. */
export const ISSUE_REPORT_RETENTION_DAYS = 30;

export async function pruneExpiredIssueReports(
  env: { SYNTILA_DB: unknown; SYNTILA_DATA?: unknown },
  bucket: R2Bucket | undefined,
  now = new Date(),
): Promise<number> {
  const cutoff = new Date(
    now.getTime() - ISSUE_REPORT_RETENTION_DAYS * DAY_MS,
  ).toISOString();
  const rows = await dataOf(env).read.rows<{ id: string; bundleKey?: string | null }>`
      SELECT r.id, d.bundle_key AS "bundleKey"
         FROM issue_reports r
         LEFT JOIN issue_report_diagnostics d ON d.report_id = r.id
        WHERE r.created_at < ${cutoff}
        ORDER BY r.created_at, r.id
        LIMIT ${MAX_REPORTS_PER_RUN}`;

  let deleted = 0;
  for (const row of rows) {
    if (row.bundleKey) {
      if (!bucket) continue;
      try {
        await bucket.delete(row.bundleKey);
      } catch {
        // Keep the D1 row until the private attachment can be removed too.
        continue;
      }
    }
    deleted += await inTransaction(env, "issue_report.prune", (_txEnv, tx) =>
      tx.run`DELETE FROM issue_reports WHERE id = ${row.id}`,
    );
  }
  return deleted;
}
