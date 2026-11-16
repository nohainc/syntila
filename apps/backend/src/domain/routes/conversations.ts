import { createHash } from "node:crypto";
import type { Conversation, WorkflowDefinition } from "@syntila/core";
import { dataOf } from "../../platform/data.js";

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
  const existing = await dataOf(env).read.row<{ id: string }>`SELECT id FROM conversations WHERE thread_id = ${threadId} ORDER BY created_at, id LIMIT 1`;
  return existing?.id ?? threadConversationId(threadId);
}

export async function conversationSubmissionStatements(
  tx: Tx,
  id: string,
  threadId: string,
  definition: WorkflowDefinition,
  workRequestId: string,
  now: string,
): Promise<void> {
  await tx.run`
    INSERT INTO conversations
      (id, thread_id, workflow_id, workflow_version, conversation_revision, context_revision, created_at, updated_at)
      SELECT ${id}, ${threadId}, ${definition.id}, ${definition.version}, 0, 0, ${now}, ${now}
      WHERE NOT EXISTS (SELECT 1 FROM conversations WHERE id = ${id})
  `;
  await tx.run`
    UPDATE conversations SET conversation_revision = conversation_revision + 1,
      context_revision = conversation_revision + 1, updated_at = ${now}
    WHERE id = ${id} AND thread_id = ${threadId}
  `;
  await tx.run`
    INSERT INTO conversation_work_requests
      (conversation_id, work_request_id, conversation_revision)
      SELECT id, ${workRequestId}, conversation_revision FROM conversations WHERE id = ${id}
  `;
}
