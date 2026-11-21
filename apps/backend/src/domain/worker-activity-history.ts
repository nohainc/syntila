import { dataOf } from "../platform/data.js";

export const MAX_WORKER_ACTIVITY_HISTORY_PER_ASSIGNMENT = 256;

export async function pruneWorkerActivityHistory(
  env: { SYNTILA_DB: unknown; SYNTILA_DATA?: unknown },
  maxPerAssignment = MAX_WORKER_ACTIVITY_HISTORY_PER_ASSIGNMENT,
): Promise<number> {
  const historyResult = await dataOf(env).tx("retention.worker_activity", (tx) =>
    tx.run`DELETE FROM worker_activity_history
       WHERE history_id IN (
         SELECT history_id FROM (
           SELECT history_id,
                  ROW_NUMBER() OVER (
                    PARTITION BY assignment_id
                    ORDER BY occurred_at DESC, provider_sequence DESC, history_id DESC
                  ) AS rank
           FROM worker_activity_history
         )
         WHERE rank > ${maxPerAssignment}
       )`,
  );
  const realtimeResult = await dataOf(env).tx("retention.worker_activity_events", (tx) =>
    tx.run`DELETE FROM realtime_events
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
         WHERE rank > ${maxPerAssignment}
       )`,
  );
  return historyResult + realtimeResult;
}
