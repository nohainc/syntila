import { HttpError, parseJson } from "./handlers.js";

/**
 * Reply v1 (docs/specifications/REPLY_V1.md). A reply names its target by
 * kind and id; Cloud verifies the target is in the same Thread and stores a
 * snapshot of who said it and what, so the quote never depends on the
 * client and survives later edits or deletion of the original.
 */
export type ReplyKind = "message" | "request" | "response";

export interface ReplyReference {
  readonly kind: ReplyKind;
  readonly id: string;
  readonly authorName: string;
  readonly excerpt: string;
}

/** Long enough to give an AI Worker the quoted context; UIs clamp further. */
export const REPLY_EXCERPT_MAX_CHARS = 1_000;

function excerpt(text: string): string {
  const trimmed = text.trim();
  return trimmed.length > REPLY_EXCERPT_MAX_CHARS
    ? `${trimmed.slice(0, REPLY_EXCERPT_MAX_CHARS - 1)}…`
    : trimmed;
}

function attachmentSummary(value: unknown): string {
  const files = Array.isArray(value) ? value : [];
  if (files.length === 0) return "";
  const names = files
    .map((file) =>
      file && typeof file === "object" && typeof file.name === "string"
        ? file.name
        : "file",
    )
    .join(", ");
  return `📎 ${names}`;
}

/**
 * Resolves the client's `replyTo: {kind, id}` into a stored snapshot, or
 * null when the request is not a reply. Throws 400 for a target outside
 * this Thread, a removed message, or a response that has no text yet.
 */
export async function resolveReplyReference(
  db: D1Database,
  threadId: string,
  raw: unknown,
): Promise<ReplyReference | null> {
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== "object" || Array.isArray(raw))
    throw new HttpError(400, "replyTo must be an object");
  const { kind, id } = raw as Record<string, unknown>;
  if (
    (kind !== "message" && kind !== "request" && kind !== "response") ||
    typeof id !== "string" ||
    !id.trim() ||
    id.length > 128
  )
    throw new HttpError(
      400,
      "replyTo must name a message, request or response",
    );
  const notFound = () =>
    new HttpError(400, "The message you replied to is not in this Thread");
  if (kind === "message") {
    const row = await db
      .prepare(
        `SELECT dm.body, dm.kind, dm.event_type AS eventType,
                dm.attachments_json AS attachmentsJson,
                dm.worker_display_name AS workerDisplayName,
                COALESCE(u.display_name, 'Member') AS authorName
           FROM discussion_messages dm
           LEFT JOIN users u ON u.id = dm.author_user_id
          WHERE dm.id = ?1 AND dm.thread_id = ?2`,
      )
      .bind(id, threadId)
      .first<Record<string, string | null>>();
    if (!row) throw notFound();
    if (row.eventType)
      throw new HttpError(400, "You cannot reply to a removed message");
    const text =
      row.body?.trim() || attachmentSummary(parseJson(row.attachmentsJson, []));
    return {
      kind,
      id,
      authorName:
        row.kind === "ai_answer"
          ? row.workerDisplayName || "AI"
          : row.authorName || "Member",
      excerpt: excerpt(text),
    };
  }
  const request = await db
    .prepare(
      `SELECT wr.input_json AS inputJson,
              COALESCE(u.display_name, 'Member') AS authorName
         FROM work_requests wr
         LEFT JOIN users u ON u.id = wr.requested_by_user_id
        WHERE wr.id = ?1 AND wr.thread_id = ?2`,
    )
    .bind(id, threadId)
    .first<{ inputJson: string; authorName: string }>();
  if (!request) throw notFound();
  if (kind === "request") {
    const input = parseJson<Record<string, unknown>>(request.inputJson, {});
    const text =
      (typeof input.originalRequest === "string"
        ? input.originalRequest
        : ""
      ).trim() || attachmentSummary(input.attachments);
    return { kind, id, authorName: request.authorName, excerpt: excerpt(text) };
  }
  const task = await db
    .prepare(
      `SELECT wt.output_json AS outputJson, catalog.display_name AS workerName
         FROM workflow_tasks wt
         LEFT JOIN worker_catalog catalog
           ON catalog.worker_type_id = (wt.output_json::jsonb #>> '{workerTypeId}')
        WHERE wt.work_request_id = ?1 AND wt.status = 'completed'
        ORDER BY wt.updated_at DESC, wt.id DESC LIMIT 1`,
    )
    .bind(id)
    .first<{ outputJson: string | null; workerName: string | null }>();
  const output = parseJson<Record<string, unknown>>(task?.outputJson, {});
  const text = typeof output.text === "string" ? output.text.trim() : "";
  if (!text)
    throw new HttpError(400, "This response has no text to reply to yet");
  return {
    kind,
    id,
    authorName: task?.workerName || "AI",
    excerpt: excerpt(text),
  };
}

/** Parses a stored snapshot; anything malformed reads as no reply. */
export function storedReplyReference(value: unknown): ReplyReference | null {
  const parsed =
    typeof value === "string" ? parseJson<unknown>(value, null) : value;
  if (!parsed || typeof parsed !== "object") return null;
  const reply = parsed as Record<string, unknown>;
  return (reply.kind === "message" ||
    reply.kind === "request" ||
    reply.kind === "response") &&
    typeof reply.id === "string" &&
    typeof reply.authorName === "string" &&
    typeof reply.excerpt === "string"
    ? {
        kind: reply.kind,
        id: reply.id,
        authorName: reply.authorName,
        excerpt: reply.excerpt,
      }
    : null;
}
