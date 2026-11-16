import { afterCursor, cursorOrder, pageOf, pageRequest } from "./pagination.js";
import { dataOf, type Row } from "../../platform/data.js";
import { NoteInputSchema } from "@syntila/protocol";
import { readBody } from "./validation.js";
import { spaceNameOf } from "../queries.js";
import { HttpError, authorizeThreadAccess, json } from "./handlers.js";
import { authorizeRequest } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";


/** Notes are private to their owner. Data layer: no global writer lock;
 * every write is one self-contained statement guarded by `revision` or a
 * unique index, so parallel writes stay correct.
 *
 * Notes are private to their owner. A note may link to one Thread; the link
 * is live only while the Thread exists and the owner is still a member of its
 * Space. Otherwise the note stays, detached, with the saved Space and Thread
 * titles. */
const NOTE_COLUMNS = `n.id, n.title, n.body, n.thread_id AS "threadId",
  n.space_id AS "spaceId", n.linked_title AS "linkedTitle",
  n.linked_space_title AS "linkedSpaceTitle", n.revision,
  n.created_at AS "createdAt", n.updated_at AS "updatedAt",
  t.name AS "liveThreadName", s.name AS "liveSpaceName",
  (t.id IS NOT NULL AND m.user_id IS NOT NULL) AS linked`;
const NOTE_FROM = `user_notes n
  LEFT JOIN threads t ON t.id = n.thread_id
  LEFT JOIN space_memberships m ON m.space_id = t.space_id AND m.user_id = n.user_id
  LEFT JOIN spaces s ON s.id = t.space_id`;

function noteView(row: Row) {
  const linked = row.linked === true;
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
  const q = dataOf(env).read;
  const row = await q.row`SELECT ${q.raw(NOTE_COLUMNS)} FROM ${q.raw(NOTE_FROM)}
     WHERE n.id = ${noteId} AND n.user_id = ${userId}`;
  if (!row) throw new HttpError(404, "Note not found");
  return noteView(row);
}

async function noteInput(request: Request) {
  return readBody(request, NoteInputSchema);
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
  const changed = await dataOf(env).read.run`
    UPDATE user_notes
       SET title = COALESCE(${input.title ?? null}::text, title),
           body = COALESCE(${input.body ?? null}::text, body),
           linked_title = COALESCE(${linked?.thread ?? null}::text, linked_title),
           linked_space_title = COALESCE(${linked?.space ?? null}::text, linked_space_title),
           revision = revision + 1, updated_at = now()
     WHERE id = ${noteId} AND user_id = ${userId} AND revision = ${input.revision}`;
  if (!changed) {
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
  const { limit, after } = pageRequest(new URL(request.url), { defaultLimit: 500, maxLimit: 500 });
  const q = dataOf(env).read;
  const rows = await q.rows`SELECT ${q.raw(NOTE_COLUMNS)} FROM ${q.raw(NOTE_FROM)}
     WHERE n.user_id = ${context.userId} AND ${afterCursor(q, "n.updated_at", "n.id", after)}
     ORDER BY ${cursorOrder(q, "n.updated_at", "n.id")} LIMIT ${limit + 1}`;
  const page = pageOf(rows, limit, (row) => ({ at: String(row.updatedAt), id: String(row.id) }));
  return json({ notes: page.items.map(noteView), nextCursor: page.nextCursor });
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
  await dataOf(env).read.run`
    INSERT INTO user_notes (id, user_id, title, body, created_at, updated_at)
    VALUES (${id}, ${context.userId}, ${input.title ?? ""}, ${input.body ?? ""}, now(), now())`;
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
    await dataOf(env).read.run`DELETE FROM user_notes WHERE id = ${noteId} AND user_id = ${context.userId}`;
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
  const existing = await dataOf(env).read.row<{ id: string }>`
    SELECT id FROM user_notes WHERE user_id = ${context.userId} AND thread_id = ${threadId}`;
  if (request.method === "GET")
    return json({
      note: existing ? await readNote(env, context.userId, existing.id) : null,
    });
  if (request.method !== "PUT") throw new HttpError(405, "Method not allowed");
  const input = await noteInput(request);
  // Saved names keep the note's Space and Thread path after the Thread is
  // deleted or the owner loses access.
  const space = await spaceNameOf(env, spaceId);
  const linked = { thread: thread.name, space: space?.name ?? "" };
  if (existing)
    return json({
      note: await updateNote(env, context.userId, existing.id, input, linked),
    });
  if (input.revision !== undefined)
    throw new HttpError(409, "Note changed since it was loaded");
  const id = `note-${crypto.randomUUID()}`;
  // A concurrent first save from another device loses on the unique index.
  // A new Thread note is titled after its Thread; the owner can rename it.
  const inserted = await dataOf(env).read.run`
    INSERT INTO user_notes
      (id, user_id, title, body, thread_id, space_id, linked_title,
       linked_space_title, created_at, updated_at)
    VALUES (${id}, ${context.userId}, ${input.title || thread.name}, ${input.body ?? ""},
            ${threadId}, ${spaceId}, ${thread.name}, ${linked.space}, now(), now())
    ON CONFLICT DO NOTHING`;
  if (!inserted)
    throw new HttpError(409, "Note changed since it was loaded");
  return json(
    { note: await readNote(env, context.userId, id) },
    { status: 201 },
  );
}
