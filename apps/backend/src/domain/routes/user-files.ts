import { dataOf } from "../../platform/data.js";
import type { Tx } from "../../platform/data.js";
import {
  afterCursor,
  cursorOrder,
  decodeCursor,
  encodeCursor,
  type PagePosition,
} from "./pagination.js";
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

/** Drop one owned file record (the single definition of this statement). */
function dropFileRecord(tx: Tx, fileId: string, userId: string) {
  return tx.run`DELETE FROM user_files WHERE id = ${fileId} AND user_id = ${userId}`;
}

/** True when a discussion message or Work Request in the file's Thread cites it. */
const FILE_REFERENCED = `(EXISTS (SELECT 1 FROM discussion_messages dm,
      jsonb_array_elements(COALESCE(dm.attachments_json, '[]')::jsonb) a(value)
      WHERE dm.thread_id = f.thread_id AND a.value ->> 'fileId' = f.id)
    OR EXISTS (SELECT 1 FROM work_requests wr,
      jsonb_array_elements(COALESCE(wr.input_json::jsonb -> 'attachments', '[]'::jsonb)) a(value)
      WHERE wr.thread_id = f.thread_id AND a.value ->> 'fileId' = f.id))`;

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
  const raw = new URL(request.url).searchParams.get("cursor");
  const after: PagePosition | null = raw ? decodeCursor(raw) : null;
  const q = dataOf(env).read;
  const results = await q.rows<Record<string, unknown>>`
    SELECT f.id AS "fileId", f.name, f.media_type AS "mediaType",
        f.size_bytes AS "sizeBytes", f.created_at AS "createdAt",
        f.thread_id AS "threadId", f.space_id AS "spaceId",
        CASE WHEN m.user_id IS NOT NULL THEN t.name END AS "threadName",
        CASE WHEN m.user_id IS NOT NULL THEN s.name END AS "spaceName",
        CASE WHEN ${q.raw(FILE_REFERENCED)} THEN true ELSE false END AS "inUse"
      FROM user_files f
      LEFT JOIN threads t ON t.id = f.thread_id
      LEFT JOIN space_memberships m ON m.space_id = t.space_id AND m.user_id = f.user_id
      LEFT JOIN spaces s ON s.id = t.space_id
      WHERE f.user_id = ${context.userId} AND ${afterCursor(q, "f.created_at", "f.id", after)}
      ORDER BY ${cursorOrder(q, "f.created_at", "f.id")} LIMIT ${PAGE_SIZE + 1}`;
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
      inUse: row.inUse === true,
    })),
    nextCursor:
      results.length > PAGE_SIZE
        ? encodeCursor({
            at: String(page.at(-1)!.createdAt),
            id: String(page.at(-1)!.fileId),
          })
        : null,
    usage: await userStorageUsage(env, context.userId),
  });
}

/** GET /api/files/:fileId — stream an upload only to its owner. */
export async function handleDownloadUserFile(
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
  const file = await dataOf(env).read.row<{ name: string; media_type: string }>`
    SELECT name, media_type FROM user_files WHERE id = ${fileId} AND user_id = ${context.userId}`;
  if (!file) throw new HttpError(404, "File not found");
  const object = await env.SYNTILA_ARTIFACTS?.get(workRequestFileKey(fileId));
  if (!object) throw new HttpError(404, "File not found");
  // Keep the quoted fallback ASCII-only and prevent header injection. The
  // UTF-8 filename parameter preserves the original name for modern clients.
  const filename = file.name.replace(/[^\x20-\x7e]|["\\]/g, "_") || "download";
  const encodedName = encodeURIComponent(
    new TextDecoder().decode(new TextEncoder().encode(file.name)),
  ).replace(
    /['()*]/g,
    (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );
  return new Response(object.body, {
    headers: {
      "Content-Type":
        object.httpMetadata?.contentType ||
        file.media_type ||
        "application/octet-stream",
      "Content-Disposition": `attachment; filename="${filename}"; filename*=UTF-8''${encodedName}`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
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
  const data = dataOf(env);
  const owned = await data.read.row`
    SELECT 1 AS present FROM user_files WHERE id = ${fileId} AND user_id = ${context.userId}`;
  if (!owned) throw new HttpError(404, "File not found");
  await deleteFileObjects(env, [fileId]);
  await data.tx("files.delete", (tx) => dropFileRecord(tx, fileId, context.userId));
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
  const data = dataOf(env);
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
      const thread = await data.read.row<{ space_id: string }>`
        SELECT space_id FROM threads WHERE id = ${meta.threadId}`;
      const name = meta.name || "Attachment";
      const mediaType = object.httpMetadata?.contentType || "application/octet-stream";
      await data.tx("files.sync_import", (tx) => tx.run`
        INSERT INTO user_files
          (id, user_id, thread_id, space_id, name, media_type, size_bytes, created_at)
        VALUES (${id}, ${context.userId}, ${meta.threadId}, ${thread?.space_id ?? null},
                ${name}, ${mediaType}, ${object.size}, ${object.uploaded.toISOString()})
        ON CONFLICT(id) DO UPDATE SET name = excluded.name,
          media_type = excluded.media_type, size_bytes = excluded.size_bytes
        WHERE user_files.user_id = excluded.user_id`);
    }
    next = page.truncated
      ? { phase, cursor: page.cursor }
      : { phase: "records" };
  } else {
    const page = await data.read.rows<{ id: string }>`
      SELECT id FROM user_files
      WHERE user_id = ${context.userId} AND id > ${cursor ?? ""} ORDER BY id LIMIT 50`;
    for (const row of page) {
      const object = await bucket.head(workRequestFileKey(row.id));
      if (!object) {
        await data.tx("files.sync_drop", (tx) => dropFileRecord(tx, row.id, context.userId));
      } else if (object.customMetadata?.userId === context.userId) {
        await data.tx("files.sync_size", (tx) => tx.run`
          UPDATE user_files SET size_bytes = ${object.size} WHERE id = ${row.id} AND user_id = ${context.userId}`);
      }
    }
    if (page.length === 50)
      next = { phase, cursor: page.at(-1)!.id };
  }
  return json({ next, usage: await userStorageUsage(env, context.userId) });
}

/** Daily: drops uploads that were never attached within a day. */
export async function pruneOrphanUserFiles(
  env: SecurityEnv,
  now = new Date(),
): Promise<number> {
  const cutoff = new Date(now.getTime() - ORPHAN_AGE_MS).toISOString();
  const data = dataOf(env);
  const rows = await data.read.rows<{ id: string }>`
    SELECT f.id FROM user_files f
      WHERE f.created_at < ${cutoff} AND NOT ${data.read.raw(FILE_REFERENCED)} LIMIT ${ORPHAN_BATCH}`;
  const candidates = rows.map((row) => row.id);
  if (candidates.length === 0) return 0;
  // Rows first, re-checking the rule in the same statement: a file attached
  // since the read above stays. Only the bytes of rows actually removed are
  // deleted (the old order could delete the bytes of a file just attached).
  const removed = await data.tx("files.prune_orphans", (tx) => tx.rows<{ id: string }>`
    DELETE FROM user_files f
      WHERE f.id IN ${tx.list(candidates)}
        AND f.created_at < ${cutoff} AND NOT ${tx.raw(FILE_REFERENCED)}
     RETURNING f.id`);
  const ids = removed.map((row) => row.id);
  if (ids.length) await deleteFileObjects(env, ids);
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
