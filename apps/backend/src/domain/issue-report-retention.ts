const DAY_MS = 24 * 60 * 60 * 1000;
const MAX_REPORTS_PER_RUN = 100;

/** Diagnostic reports are retained for support investigation for one year. */
export const ISSUE_REPORT_RETENTION_DAYS = 365;

export async function pruneExpiredIssueReports(
  db: D1Database,
  bucket: R2Bucket | undefined,
  now = new Date(),
): Promise<number> {
  const cutoff = new Date(
    now.getTime() - ISSUE_REPORT_RETENTION_DAYS * DAY_MS,
  ).toISOString();
  const rows = await db
    .prepare(
      `SELECT r.id, d.bundle_key AS bundleKey
         FROM issue_reports r
         LEFT JOIN issue_report_diagnostics d ON d.report_id = r.id
        WHERE r.created_at < ?1
        ORDER BY r.created_at, r.id
        LIMIT ?2`,
    )
    .bind(cutoff, MAX_REPORTS_PER_RUN)
    .all<{ id: string; bundleKey?: string | null }>();

  let deleted = 0;
  for (const row of rows.results ?? []) {
    if (row.bundleKey) {
      if (!bucket) continue;
      try {
        await bucket.delete(row.bundleKey);
      } catch {
        // Keep the D1 row until the private attachment can be removed too.
        continue;
      }
    }
    const result = await db
      .prepare("DELETE FROM issue_reports WHERE id = ?1")
      .bind(row.id)
      .run();
    deleted += Number(result.meta.changes ?? 0);
  }
  return deleted;
}
