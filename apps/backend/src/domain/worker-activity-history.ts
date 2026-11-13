import {
  isReplayableWorkerActivityType,
  type RealtimeEventPayload,
} from "@syntila/protocol";

export const MAX_WORKER_ACTIVITY_HISTORY_PER_ASSIGNMENT = 256;

export function shouldPersistWorkerActivity(
  payload: RealtimeEventPayload,
): boolean {
  return (
    typeof payload.activityType === "string" &&
    isReplayableWorkerActivityType(payload.activityType)
  );
}

export async function pruneWorkerActivityHistory(
  db: D1Database,
  maxPerAssignment = MAX_WORKER_ACTIVITY_HISTORY_PER_ASSIGNMENT,
): Promise<number> {
  const historyResult = await db
    .prepare(
      `DELETE FROM worker_activity_history
       WHERE history_id IN (
         SELECT history_id FROM (
           SELECT history_id,
                  ROW_NUMBER() OVER (
                    PARTITION BY assignment_id
                    ORDER BY occurred_at DESC, provider_sequence DESC, history_id DESC
                  ) AS rank
           FROM worker_activity_history
         )
         WHERE rank > ?1
       )`,
    )
    .bind(maxPerAssignment)
    .run();
  const realtimeResult = await db
    .prepare(
      `DELETE FROM realtime_events
       WHERE event_id IN (
         SELECT event_id FROM (
           SELECT event_id,
                  ROW_NUMBER() OVER (
                    PARTITION BY assignment_id
                    ORDER BY occurred_at DESC, sequence DESC, event_id DESC
                  ) AS rank
           FROM realtime_events
           WHERE event_type = 'assignment.activity'
         )
         WHERE rank > ?1
       )`,
    )
    .bind(maxPerAssignment)
    .run();
  return (
    Number(historyResult.meta.changes ?? 0) +
    Number(realtimeResult.meta.changes ?? 0)
  );
}
