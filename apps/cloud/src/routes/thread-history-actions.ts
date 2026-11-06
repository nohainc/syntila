import type { SecurityEnv } from "./http-security.js";
import { HttpError } from "./http-security.js";

export function threadNotice(
  env: SecurityEnv,
  threadId: string,
  userId: string,
  name: string,
  event: string,
  text: string,
  now: string,
) {
  return env.SYNTILA_DB.prepare(
    `INSERT INTO discussion_messages
    (id, thread_id, author_user_id, body, created_at, event_type)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  ).bind(
    `notice-${crypto.randomUUID()}`,
    threadId,
    userId,
    `${name} ${text}`,
    now,
    event,
  );
}

export async function requireDestructiveThreadAccess(
  env: SecurityEnv,
  threadId: string,
  userId: string,
) {
  const row = await env.SYNTILA_DB.prepare(
    `SELECT t.lead_user_id AS creator,
    t.has_other_contributions AS contributed, s.owner_user_id AS owner,
    COALESCE(s.kind, 'group') AS spaceKind
    FROM threads t JOIN spaces s ON s.id = t.space_id WHERE t.id = ?1`,
  )
    .bind(threadId)
    .first<{
      creator: string;
      contributed: number;
      owner: string;
      spaceKind: string;
    }>();
  if (!row) throw new HttpError(404, "Thread not found");

  if (row.spaceKind === "direct") {
    if (row.creator !== userId || row.contributed !== 0) {
      throw new HttpError(
        403,
        "In a Direct Space, only the Thread creator with no other contributions may delete or clear this Thread",
      );
    }
    return;
  }

  if (
    row.owner !== userId &&
    (row.creator !== userId || row.contributed !== 0)
  )
    throw new HttpError(
      403,
      "Only the Space owner or a creator without other people's contributions may clear or delete this Thread",
    );
}

/** Recheck inside the atomic action batch to fence contributions/requests
 * admitted after the HTTP authorization read. A failed CHECK rolls it back. */
export function destructiveThreadGuard(
  env: SecurityEnv,
  threadId: string,
  userId: string,
) {
  return env.SYNTILA_DB.prepare(
    `UPDATE threads SET has_other_contributions = CASE
    WHEN ((lead_user_id = ?2 AND has_other_contributions = 0) OR EXISTS
      (SELECT 1 FROM spaces s WHERE s.id = threads.space_id AND s.owner_user_id = ?2 AND COALESCE(s.kind, 'group') <> 'direct'))
      AND NOT EXISTS (SELECT 1 FROM work_requests wr WHERE wr.thread_id = threads.id
        AND wr.status IN ('queued','running','waiting'))
    THEN has_other_contributions ELSE -1 END WHERE id = ?1`,
  ).bind(threadId, userId);
}
