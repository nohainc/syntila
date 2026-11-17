import { queryOf } from "../../platform/data.js";
import { createHash } from "node:crypto";
import type { Conversation, WorkflowDefinition } from "@syntila/core";

/**
 * One canonical Conversation per Thread, shared by every manual workflow
 * (Chat and Work), so switching workflow keeps the same AI history. The row's
 * `workflow_id` records the workflow that opened it.
 */
export function threadConversationId(threadId: string): string {
  return `conversation-${createHash("sha256")
    .update(JSON.stringify([threadId]))
    .digest("hex")}`;
}

/**
 * Threads created before Conversations were Thread-scoped may already have
 * one per workflow; the oldest stays canonical so its history and Worker
 * Sessions continue.
 */
export async function resolveThreadConversationId(
  db: D1Database,
  threadId: string,
): Promise<string> {
  const existing = await queryOf(db).row<{ id: string }>`SELECT id FROM conversations WHERE thread_id = ${threadId} ORDER BY created_at, id LIMIT 1`;
  return existing?.id ?? threadConversationId(threadId);
}

export function conversationSubmissionStatements(
  db: D1Database,
  id: string,
  threadId: string,
  definition: WorkflowDefinition,
  workRequestId: string,
  now: string,
): D1PreparedStatement[] {
  return [
    db
      .prepare(
        `INSERT INTO conversations
      (id, thread_id, workflow_id, workflow_version, conversation_revision, context_revision, created_at, updated_at)
      SELECT ?1, ?2, ?3, ?4, 0, 0, ?5, ?5
      WHERE NOT EXISTS (SELECT 1 FROM conversations WHERE id = ?1)`,
      )
      .bind(id, threadId, definition.id, definition.version, now),
    db
      .prepare(
        `UPDATE conversations SET conversation_revision = conversation_revision + 1,
        context_revision = conversation_revision + 1, updated_at = ?2
      WHERE id = ?1 AND thread_id = ?3`,
      )
      .bind(id, now, threadId),
    db
      .prepare(
        `INSERT INTO conversation_work_requests
      (conversation_id, work_request_id, conversation_revision)
      SELECT id, ?2, conversation_revision FROM conversations WHERE id = ?1`,
      )
      .bind(id, workRequestId),
  ];
}
