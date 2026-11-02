import { HttpError, json } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { authorizeRequest } from "./http-security.js";
import {
  isWorkRequestFileId,
  userStorageUsage,
  workRequestFileKey,
} from "./work-request-files.js";

const PAGE_SIZE = 100;
/** Uploads never attached to a message or Work Request expire after this. */
const ORPHAN_AGE_MS = 24 * 60 * 60 * 1000;
const ORPHAN_BATCH = 100;

/** True when a discussion message or Work Request in the file's Thread cites it. */
const FILE_REFERENCED = `(EXISTS (SELECT 1 FROM discussion_messages dm,
      json_each(dm.attachments_json) a
      WHERE dm.thread_id = f.thread_id AND json_extract(a.value, '$.fileId') = f.id)
    OR EXISTS (SELECT 1 FROM work_requests wr,
      json_each(wr.input_json, '$.attachments') a
      WHERE wr.thread_id = f.thread_id AND json_extract(a.value, '$.fileId') = f.id))`;

/** GET /api/files — the caller's uploads, newest first, with quota usage. */
export async function handleListUserFiles(
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
  const before = new URL(request.url).searchParams.get("before");
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT f.id AS fileId, f.name, f.media_type AS mediaType,
        f.size_bytes AS sizeBytes, f.created_at AS createdAt,
        f.thread_id AS threadId, f.space_id AS spaceId,
        CASE WHEN m.user_id IS NOT NULL THEN t.name END AS threadName,
        CASE WHEN m.user_id IS NOT NULL THEN s.name END AS spaceName,
        CASE WHEN ${FILE_REFERENCED} THEN 1 ELSE 0 END AS inUse
      FROM user_files f
      LEFT JOIN threads t ON t.id = f.thread_id
      LEFT JOIN space_memberships m ON m.space_id = t.space_id AND m.user_id = f.user_id
      LEFT JOIN spaces s ON s.id = t.space_id
      WHERE f.user_id = ?1 AND (?2 IS NULL OR f.created_at < ?2)
      ORDER BY f.created_at DESC, f.id DESC LIMIT ?3`,
  )
    .bind(context.userId, before, PAGE_SIZE + 1)
    .all<Record<string, unknown>>();
  const results = rows.results ?? [];
  const page = results.slice(0, PAGE_SIZE);
  return json({
    files: page.map((row) => ({
      fileId: String(row.fileId),
      name: String(row.name),
      mediaType: String(row.mediaType),
      sizeBytes: Number(row.sizeBytes),
      createdAt: String(row.createdAt),
      threadId: row.threadName == null ? null : String(row.threadId),
      spaceId: row.threadName == null ? null : String(row.spaceId),
      threadName: row.threadName == null ? null : String(row.threadName),
      spaceName: row.spaceName == null ? null : String(row.spaceName),
      inUse: row.inUse === 1,
    })),
    nextCursor:
      results.length > PAGE_SIZE ? String(page.at(-1)!.createdAt) : null,
    usage: await userStorageUsage(env, context.userId),
  });
}

/**
 * DELETE /api/files/:fileId — owner only, and allowed at any quota. Removes the
 * stored bytes first and the accounting row only after storage confirms, so
 * usage drops only once the file is really gone. Messages and Work Requests
 * that cited the file keep its name and size (a reference owns no bytes, so
 * dropping one cannot change usage), but downloads 404.
 */
export async function handleDeleteUserFile(
  request: Request,
  env: SecurityEnv,
  fileId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:read",
    undefined,
    accessContext,
  );
  if (!isWorkRequestFileId(fileId)) throw new HttpError(404, "File not found");
  const owned = await env.SYNTILA_DB.prepare(
    `SELECT 1 AS present FROM user_files WHERE id = ?1 AND user_id = ?2`,
  )
    .bind(fileId, context.userId)
    .first();
  if (!owned) throw new HttpError(404, "File not found");
  await deleteFileObjects(env, [fileId]);
  await env.SYNTILA_DB.prepare(`DELETE FROM user_files WHERE id = ?1`)
    .bind(fileId)
    .run();
  return json({ usage: await userStorageUsage(env, context.userId) });
}

/** POST /api/files/sync — bounded reconciliation; never deletes stored bytes. */
export async function handleSyncUserFiles(
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
  const bucket = env.SYNTILA_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "File storage is not configured");
  const params = new URL(request.url).searchParams;
  const phase = params.get("phase") ?? "storage";
  const cursor = params.get("cursor") ?? undefined;
  if (phase !== "storage" && phase !== "records")
    throw new HttpError(400, "Invalid sync phase");
  let next: { phase: string; cursor?: string } | null = null;
  if (phase === "storage") {
    const page = await bucket.list({
      prefix: "work-request-inputs/",
      limit: 100,
      cursor,
      include: ["customMetadata", "httpMetadata"],
    });
    for (const listed of page.objects) {
      const id = listed.key.slice("work-request-inputs/".length);
      if (
        !isWorkRequestFileId(id) ||
        listed.customMetadata?.userId !== context.userId
      )
        continue;
      // Re-read before importing: a concurrent delete may have removed the object.
      const object = await bucket.head(listed.key);
      const meta = object?.customMetadata;
      if (!object || meta?.userId !== context.userId || !meta.threadId)
        continue;
      const thread = await env.SYNTILA_DB.prepare(
        "SELECT space_id FROM threads WHERE id = ?1",
      )
        .bind(meta.threadId)
        .first<{ space_id: string }>();
      await env.SYNTILA_DB.prepare(
        `INSERT INTO user_files
        (id, user_id, thread_id, space_id, name, media_type, size_bytes, created_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ON CONFLICT(id) DO UPDATE SET name = excluded.name,
          media_type = excluded.media_type, size_bytes = excluded.size_bytes
        WHERE user_files.user_id = excluded.user_id`,
      )
        .bind(
          id,
          context.userId,
          meta.threadId,
          thread?.space_id ?? null,
          meta.name || "Attachment",
          object.httpMetadata?.contentType || "application/octet-stream",
          object.size,
          object.uploaded.toISOString(),
        )
        .run();
    }
    next = page.truncated
      ? { phase, cursor: page.cursor }
      : { phase: "records" };
  } else {
    const page = await env.SYNTILA_DB.prepare(
      `SELECT id FROM user_files
      WHERE user_id = ?1 AND id > ?2 ORDER BY id LIMIT 50`,
    )
      .bind(context.userId, cursor ?? "")
      .all<{ id: string }>();
    for (const row of page.results) {
      const object = await bucket.head(workRequestFileKey(row.id));
      if (!object) {
        await env.SYNTILA_DB.prepare(
          "DELETE FROM user_files WHERE id = ?1 AND user_id = ?2",
        )
          .bind(row.id, context.userId)
          .run();
      } else if (object.customMetadata?.userId === context.userId) {
        await env.SYNTILA_DB.prepare(
          "UPDATE user_files SET size_bytes = ?1 WHERE id = ?2 AND user_id = ?3",
        )
          .bind(object.size, row.id, context.userId)
          .run();
      }
    }
    if (page.results.length === 50)
      next = { phase, cursor: page.results.at(-1)!.id };
  }
  return json({ next, usage: await userStorageUsage(env, context.userId) });
}

/** Daily: drops uploads that were never attached within a day. */
export async function pruneOrphanUserFiles(
  env: SecurityEnv,
  now = new Date(),
): Promise<number> {
  const cutoff = new Date(now.getTime() - ORPHAN_AGE_MS).toISOString();
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT f.id FROM user_files f
      WHERE f.created_at < ?1 AND NOT ${FILE_REFERENCED} LIMIT ?2`,
  )
    .bind(cutoff, ORPHAN_BATCH)
    .all<{ id: string }>();
  const ids = (rows.results ?? []).map((row) => row.id);
  if (ids.length === 0) return 0;
  await deleteFileObjects(env, ids);
  await env.SYNTILA_DB.prepare(
    `DELETE FROM user_files WHERE id IN (SELECT value FROM json_each(?1))`,
  )
    .bind(JSON.stringify(ids))
    .run();
  return ids.length;
}

async function deleteFileObjects(env: SecurityEnv, ids: string[]) {
  const bucket = env.SYNTILA_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "File storage is not configured");
  await bucket.delete(
    ids.flatMap((id) => [
      workRequestFileKey(id),
      `${workRequestFileKey(id)}/meta`,
      `${workRequestFileKey(id)}/preview`,
    ]),
  );
}
