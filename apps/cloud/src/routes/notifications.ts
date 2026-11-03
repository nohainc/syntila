import { json, parseJson } from "./handlers.js";
import { authorizeRequest } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";

const FEED_LIMIT = 50;
const FEED_WINDOW = "-14 days";

/** Finished Work in the caller's Spaces, newest first. The caller's own
 * successful Work is left out; their own failures still appear. Derived from the
 * Work Request table so every status writer is covered; only read markers
 * are stored. */
export async function handleListNotifications(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:read",
    undefined,
    accessContext,
  );
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT w.id, w.status, w.updated_at AS updatedAt, w.thread_id AS threadId,
            t.name AS threadName, t.space_id AS spaceId,
            w.requested_by_user_id AS requestedByUserId,
            CASE WHEN r.work_request_id IS NULL THEN 0 ELSE 1 END AS read
       FROM work_requests w
       JOIN threads t ON t.id = w.thread_id
       JOIN space_memberships m ON m.space_id = t.space_id AND m.user_id = ?1
       LEFT JOIN user_notification_reads r
         ON r.work_request_id = w.id AND r.user_id = ?1
      WHERE (w.status = 'failed'
             OR (w.status = 'completed' AND w.requested_by_user_id <> ?1))
        AND w.updated_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '${FEED_WINDOW}')
        AND (w.status <> 'failed' OR NOT EXISTS (
          SELECT 1 FROM work_requests newer
           WHERE newer.thread_id = w.thread_id AND newer.status = 'failed'
             AND (newer.updated_at > w.updated_at OR
                  (newer.updated_at = w.updated_at AND newer.id > w.id))
        ))
      ORDER BY w.updated_at DESC, w.id DESC
      LIMIT ${FEED_LIMIT}`,
  )
    .bind(context.userId)
    .all<Record<string, unknown>>();
  return json({
    notifications: (rows.results ?? []).map((row) => ({
      id: String(row.id),
      type:
        row.status === "failed"
          ? "work_request.failed"
          : "work_request.completed",
      spaceId: String(row.spaceId),
      threadId: String(row.threadId),
      threadName: String(row.threadName),
      requestedByUserId: String(row.requestedByUserId),
      timestamp: String(row.updatedAt),
      read: row.read === 1,
    })),
  });
}

/** Mark the listed notifications read, or every visible one when `ids` is
 * omitted. Ids outside the caller's Spaces are ignored. */
export async function handleMarkNotificationsRead(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:read",
    undefined,
    accessContext,
  );
  const body = parseJson<{ ids?: unknown }>(
    await request.text().catch(() => ""),
    {},
  );
  const ids = Array.isArray(body.ids)
    ? body.ids
        .filter((id): id is string => typeof id === "string")
        .slice(0, 200)
    : null;
  const readAt = new Date().toISOString();
  const scope = `FROM work_requests w
       JOIN threads t ON t.id = w.thread_id
       JOIN space_memberships m ON m.space_id = t.space_id AND m.user_id = ?1
      WHERE w.status IN ('completed', 'failed')`;
  const statement =
    ids === null
      ? env.SYNTILA_DB.prepare(
          `INSERT OR IGNORE INTO user_notification_reads (user_id, work_request_id, read_at)
           SELECT ?1, w.id, ?2 ${scope}`,
        ).bind(context.userId, readAt)
      : env.SYNTILA_DB.prepare(
          `INSERT OR IGNORE INTO user_notification_reads (user_id, work_request_id, read_at)
           SELECT ?1, w.id, ?2 ${scope}
              AND w.id IN (SELECT value FROM json_each(?3))`,
        ).bind(context.userId, readAt, JSON.stringify(ids));
  await statement.run();
  return json({ readAt });
}
