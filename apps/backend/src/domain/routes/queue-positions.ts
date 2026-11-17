import type { Tx } from "../../platform/data.js";
/**
 * Positions in a Thread's request queue, safe under parallel writes.
 *
 * A position is computed from the queue's current contents, so reading and
 * inserting must not interleave with another writer of the same queue. Each
 * write therefore goes into one transaction that first takes a
 * lock for that Thread's queue and then computes the position in SQL: in
 * READ COMMITTED every statement sees what committed before it started, so
 * the statements after the lock see the queue as the previous writer left
 * it. Queues of different Threads never wait for each other. A unique index
 * on (thread_id, position) backs this up.
 */
export interface QueueItem {
  readonly id: string;
  readonly threadId: string;
  readonly authorUserId: string;
  readonly requestJson: string;
  readonly now: string;
}

type Runner = Pick<Tx, "run">;

/** First statement of every transaction that writes queue positions. */
export const lockQueue = (tx: Tx, threadId: string): Promise<void> => tx.lock("syntila.queue", threadId);

const insertAt = (q: Runner, item: QueueItem, position: unknown) =>
  q.run`INSERT INTO thread_request_queue
  (id, thread_id, author_user_id, request_json, position, status, created_at, updated_at)
  VALUES (${item.id}, ${item.threadId}, ${item.authorUserId}, ${item.requestJson}, ${position}, 'queued', ${item.now}::timestamptz, ${item.now}::timestamptz)`;

/** At the end of the queue. */
export const appendToQueue = (q: Tx, item: QueueItem) =>
  insertAt(q, item, q.frag`COALESCE((SELECT MAX(position) FROM thread_request_queue WHERE thread_id = ${item.threadId}), 0) + 1`);

/** At the front of the queue. */
export const prependToQueue = (q: Tx, item: QueueItem) =>
  insertAt(q, item, q.frag`COALESCE((SELECT MIN(position) FROM thread_request_queue WHERE thread_id = ${item.threadId}), 1) - 1`);

/**
 * A person's request: after earlier requests but before the next phase of an
 * implementation plan, so it runs between phases instead of after the plan.
 */
export const enqueueBeforePhases = (q: Tx, item: QueueItem) =>
  insertAt(q, item, q.frag`(WITH phase AS (
       SELECT MIN(position) AS p FROM thread_request_queue
        WHERE thread_id = ${item.threadId} AND (request_json::jsonb #>> '{isPhased}') IN ('true', '1'))
     SELECT CASE
       WHEN phase.p IS NULL THEN
         COALESCE((SELECT MAX(position) FROM thread_request_queue WHERE thread_id = ${item.threadId}), 0) + 1
       ELSE (COALESCE((SELECT MAX(position) FROM thread_request_queue
                        WHERE thread_id = ${item.threadId} AND position < phase.p), phase.p - 1) + phase.p) / 2
     END FROM phase)`);

/** Moves an item to the front of its queue. */
export const moveToFront = (q: Runner, threadId: string, itemId: string, now: string) =>
  q.run`UPDATE thread_request_queue
      SET position = (SELECT MIN(position) FROM thread_request_queue WHERE thread_id = ${threadId}) - 1,
          updated_at = ${now}
    WHERE id = ${itemId} AND thread_id = ${threadId} AND status = 'queued'`;
