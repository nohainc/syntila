/** Ended sessions are kept briefly so recent sign-outs stay auditable. */
export const ENDED_SESSION_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * Deletes desktop and web sessions (and desktop sign-in intents) that expired
 * or were revoked more than the retention window ago. Timestamps are ISO-8601
 * strings, so lexical comparison matches chronological order.
 */
export async function pruneEndedAuthSessions(
  db: D1Database,
  now = new Date(),
): Promise<number> {
  const cutoff = new Date(
    now.getTime() - ENDED_SESSION_RETENTION_MS,
  ).toISOString();
  const results = await db.batch([
    db
      .prepare(
        `DELETE FROM desktop_human_sessions
          WHERE expires_at < ?1 OR (revoked_at IS NOT NULL AND revoked_at < ?1)`,
      )
      .bind(cutoff),
    db
      .prepare("DELETE FROM desktop_auth_intents WHERE expires_at < ?1")
      .bind(cutoff),
    db.prepare("DELETE FROM auth_sessions WHERE expires_at < ?1").bind(cutoff),
  ]);
  return results.reduce(
    (total, result) =>
      total + ((result as { meta?: { changes?: number } }).meta?.changes ?? 0),
    0,
  );
}
