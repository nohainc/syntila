import { HttpError, authorizeThreadAccess, json } from "./handlers.js";
import { authorizeRequest } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";

const MAX_TITLE = 200;
const MAX_BODY = 200_000;

/** Notes are private to their owner. A note may link to one Thread; the link
 * is live only while the Thread exists and the owner is still a member of its
 * Space. Otherwise the note stays, detached, with the saved Space and Thread
 * titles. */
const NOTE_COLUMNS = `n.id, n.title, n.body, n.thread_id AS threadId,
  n.space_id AS spaceId, n.linked_title AS linkedTitle,
  n.linked_space_title AS linkedSpaceTitle, n.revision,
  n.created_at AS createdAt, n.updated_at AS updatedAt,
  t.name AS liveThreadName, s.name AS liveSpaceName,
  CASE WHEN t.id IS NOT NULL AND m.user_id IS NOT NULL THEN 1 ELSE 0 END AS linked`;
const NOTE_FROM = `user_notes n
  LEFT JOIN threads t ON t.id = n.thread_id
  LEFT JOIN space_memberships m ON m.space_id = t.space_id AND m.user_id = n.user_id
  LEFT JOIN spaces s ON s.id = t.space_id`;

function noteView(row: Record<string, unknown>) {
  const linked = row.linked === 1;
  return {
    id: String(row.id),
    title: String(row.title),
    body: String(row.body),
    threadId: row.threadId == null ? null : String(row.threadId),
    spaceId: row.spaceId == null ? null : String(row.spaceId),
    threadName:
      row.threadId == null
        ? null
        : String((linked ? row.liveThreadName : row.linkedTitle) ?? ""),
    spaceName:
      row.threadId == null
        ? null
        : String((linked ? row.liveSpaceName : row.linkedSpaceTitle) ?? ""),
    linked,
    revision: Number(row.revision),
    createdAt: String(row.createdAt),
    updatedAt: String(row.updatedAt),
  };
}

async function readNote(env: SecurityEnv, userId: string, noteId: string) {
  const row = await env.SYNTILA_DB.prepare(
    `SELECT ${NOTE_COLUMNS} FROM ${NOTE_FROM} WHERE n.id = ?1 AND n.user_id = ?2`,
  )
    .bind(noteId, userId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Note not found");
  return noteView(row);
}

async function noteInput(request: Request) {
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const title = body.title;
  const text = body.body;
  const revision = body.revision;
  if (
    title !== undefined &&
    (typeof title !== "string" || title.length > MAX_TITLE)
  )
    throw new HttpError(
      400,
      `title must be text up to ${MAX_TITLE} characters`,
    );
  if (
    text !== undefined &&
    (typeof text !== "string" || text.length > MAX_BODY)
  )
    throw new HttpError(400, `body must be text up to ${MAX_BODY} characters`);
  if (
    revision !== undefined &&
    (typeof revision !== "number" ||
      !Number.isInteger(revision) ||
      revision < 1)
  )
    throw new HttpError(400, "revision must be a positive integer");
  return {
    title: title as string | undefined,
    body: text as string | undefined,
    revision: revision as number | undefined,
  };
}

/** Guarded update: applies only when `revision` still matches, so a stale
 * editor (another device) gets 409 instead of overwriting newer text. */
async function updateNote(
  env: SecurityEnv,
  userId: string,
  noteId: string,
  input: { title?: string; body?: string; revision?: number },
  linked?: { thread: string; space: string },
) {
  if (input.revision === undefined)
    throw new HttpError(400, "revision is required");
  const result = await env.SYNTILA_DB.prepare(
    `UPDATE user_notes
        SET title = COALESCE(?1, title), body = COALESCE(?2, body),
            linked_title = COALESCE(?3, linked_title),
            linked_space_title = COALESCE(?8, linked_space_title),
            revision = revision + 1, updated_at = ?4
      WHERE id = ?5 AND user_id = ?6 AND revision = ?7`,
  )
    .bind(
      input.title ?? null,
      input.body ?? null,
      linked?.thread ?? null,
      new Date().toISOString(),
      noteId,
      userId,
      input.revision,
      linked?.space ?? null,
    )
    .run();
  if (!result.meta.changes) {
    await readNote(env, userId, noteId); // 404 when the note is gone
    throw new HttpError(409, "Note changed since it was loaded");
  }
  return readNote(env, userId, noteId);
}

/** GET /api/notes — every note of the caller, newest first. */
export async function handleListNotes(
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
    `SELECT ${NOTE_COLUMNS} FROM ${NOTE_FROM}
      WHERE n.user_id = ?1 ORDER BY n.updated_at DESC, n.id DESC`,
  )
    .bind(context.userId)
    .all<Record<string, unknown>>();
  return json({ notes: (rows.results ?? []).map(noteView) });
}

/** POST /api/notes — a standalone note, not linked to any Thread. */
export async function handleCreateNote(
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
  const input = await noteInput(request);
  const id = `note-${crypto.randomUUID()}`;
  const now = new Date().toISOString();
  await env.SYNTILA_DB.prepare(
    `INSERT INTO user_notes (id, user_id, title, body, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?5)`,
  )
    .bind(id, context.userId, input.title ?? "", input.body ?? "", now)
    .run();
  return json(
    { note: await readNote(env, context.userId, id) },
    { status: 201 },
  );
}

/** GET, PUT, DELETE /api/notes/:id — only the owner can see or change it. */
export async function handleNote(
  request: Request,
  env: SecurityEnv,
  noteId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:read",
    undefined,
    accessContext,
  );
  if (request.method === "GET")
    return json({ note: await readNote(env, context.userId, noteId) });
  if (request.method === "PUT") {
    const input = await noteInput(request);
    return json({
      note: await updateNote(env, context.userId, noteId, input),
    });
  }
  if (request.method === "DELETE") {
    await env.SYNTILA_DB.prepare(
      "DELETE FROM user_notes WHERE id = ?1 AND user_id = ?2",
    )
      .bind(noteId, context.userId)
      .run();
    return json({ ok: true, id: noteId });
  }
  throw new HttpError(405, "Method not allowed");
}

/** GET, PUT /api/threads/:id/note — the caller's note for this Thread.
 * GET returns `note: null` until the first save; the first PUT (without
 * `revision`) creates it. */
export async function handleThreadNote(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, thread, spaceId } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "view",
    accessContext,
  );
  const existing = await env.SYNTILA_DB.prepare(
    "SELECT id FROM user_notes WHERE user_id = ?1 AND thread_id = ?2",
  )
    .bind(context.userId, threadId)
    .first<{ id: string }>();
  if (request.method === "GET")
    return json({
      note: existing ? await readNote(env, context.userId, existing.id) : null,
    });
  if (request.method !== "PUT") throw new HttpError(405, "Method not allowed");
  const input = await noteInput(request);
  // Saved names keep the note's Space and Thread path after the Thread is
  // deleted or the owner loses access.
  const space = await env.SYNTILA_DB.prepare(
    "SELECT name FROM spaces WHERE id = ?1",
  )
    .bind(spaceId)
    .first<{ name: string }>();
  const linked = { thread: thread.name, space: space?.name ?? "" };
  if (existing)
    return json({
      note: await updateNote(env, context.userId, existing.id, input, linked),
    });
  if (input.revision !== undefined)
    throw new HttpError(409, "Note changed since it was loaded");
  const id = `note-${crypto.randomUUID()}`;
  const now = new Date().toISOString();
  // A concurrent first save from another device loses on the unique index.
  // A new Thread note is titled after its Thread; the owner can rename it.
  const result = await env.SYNTILA_DB.prepare(
    `INSERT INTO user_notes
       (id, user_id, title, body, thread_id, space_id, linked_title,
        linked_space_title, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?9, ?8, ?8)
     ON CONFLICT DO NOTHING`,
  )
    .bind(
      id,
      context.userId,
      input.title || thread.name,
      input.body ?? "",
      threadId,
      spaceId,
      thread.name,
      now,
      linked.space,
    )
    .run();
  if (!result.meta.changes)
    throw new HttpError(409, "Note changed since it was loaded");
  return json(
    { note: await readNote(env, context.userId, id) },
    { status: 201 },
  );
}
