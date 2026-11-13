const DAY_MS = 24 * 60 * 60 * 1000;
const DELETE_BATCH_SIZE = 1_000;
const MAX_DELETE_BATCHES_PER_RUN = 10;

/**
 * The log only serves reconnect replay. A client whose cursor is older than
 * the oldest kept event sees a sequence gap and does a full resync instead.
 */
export const DURABLE_EVENT_RETENTION_DAYS = 7;

export async function pruneExpiredRealtimeEvents(
  db: D1Database,
  now = new Date(),
): Promise<number> {
  const cutoff = new Date(
    now.getTime() - DURABLE_EVENT_RETENTION_DAYS * DAY_MS,
  ).toISOString();
  let deleted = 0;

  for (let batch = 0; batch < MAX_DELETE_BATCHES_PER_RUN; batch += 1) {
    const result = await db
      .prepare(
        `DELETE FROM realtime_events
         WHERE event_id IN (
           SELECT event_id FROM realtime_events
           WHERE occurred_at < ?1
           ORDER BY occurred_at, event_id
           LIMIT ?2
         )`,
      )
      .bind(cutoff, DELETE_BATCH_SIZE)
      .run();
    const batchDeleted = Number(result.meta.changes ?? 0);
    deleted += batchDeleted;
    if (batchDeleted < DELETE_BATCH_SIZE) break;
  }

  return deleted;
}
