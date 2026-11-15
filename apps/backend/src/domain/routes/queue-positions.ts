/**
 * Positions in a Thread's request queue, safe under parallel writes.
 *
 * A position is computed from the queue's current contents, so reading and
 * inserting must not interleave with another writer of the same queue. Each
 * write therefore goes into one batch (one transaction) that first takes a
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

/** First statement of every batch that writes queue positions. */
export const lockQueue = (db: D1Database, threadId: string): D1PreparedStatement =>
  db.prepare("SELECT pg_advisory_xact_lock(hashtextextended('syntila.queue:' || ?1, 0))").bind(threadId);

const INSERT = `INSERT INTO thread_request_queue
  (id, thread_id, author_user_id, request_json, position, status, created_at, updated_at)
  VALUES (?1, ?2, ?3, ?4, `;
const TAIL = `, 'queued', ?5, ?5)`;
const bind = (statement: D1PreparedStatement, item: QueueItem) =>
  statement.bind(item.id, item.threadId, item.authorUserId, item.requestJson, item.now);

/** At the end of the queue. */
export const appendToQueue = (db: D1Database, item: QueueItem) =>
  bind(db.prepare(`${INSERT}
    COALESCE((SELECT MAX(position) FROM thread_request_queue WHERE thread_id = ?2), 0) + 1${TAIL}`), item);

/** At the front of the queue. */
export const prependToQueue = (db: D1Database, item: QueueItem) =>
  bind(db.prepare(`${INSERT}
    COALESCE((SELECT MIN(position) FROM thread_request_queue WHERE thread_id = ?2), 1) - 1${TAIL}`), item);

/**
 * A person's request: after earlier requests but before the next phase of an
 * implementation plan, so it runs between phases instead of after the plan.
 */
export const enqueueBeforePhases = (db: D1Database, item: QueueItem) =>
  bind(db.prepare(`${INSERT}
    (WITH phase AS (
       SELECT MIN(position) AS p FROM thread_request_queue
        WHERE thread_id = ?2 AND (request_json::jsonb #>> '{isPhased}') IN ('true', '1'))
     SELECT CASE
       WHEN phase.p IS NULL THEN
         COALESCE((SELECT MAX(position) FROM thread_request_queue WHERE thread_id = ?2), 0) + 1
       ELSE (COALESCE((SELECT MAX(position) FROM thread_request_queue
                        WHERE thread_id = ?2 AND position < phase.p), phase.p - 1) + phase.p) / 2
     END FROM phase)${TAIL}`), item);

/** Moves an item to the front of its queue. */
export const moveToFront = (db: D1Database, threadId: string, itemId: string, now: string) =>
  db.prepare(`UPDATE thread_request_queue
      SET position = (SELECT MIN(position) FROM thread_request_queue WHERE thread_id = ?1) - 1,
          updated_at = ?3
    WHERE id = ?2 AND thread_id = ?1`).bind(threadId, itemId, now);
