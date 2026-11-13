import { createHash } from "node:crypto";
import type { Conversation, WorkflowDefinition } from "@syntila/core";
import { authorizeThreadAccess, json, type SecurityEnv } from "./handlers.js";

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
  const existing = await db
    .prepare(
      "SELECT id FROM conversations WHERE thread_id = ?1 ORDER BY created_at, id LIMIT 1",
    )
    .bind(threadId)
    .first<{ id: string }>();
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

export async function handleListConversations(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeThreadAccess(request, env, threadId, "view", accessContext);
  const result = await env.SYNTILA_DB.prepare(
    `SELECT id, thread_id AS threadId,
    workflow_id AS workflowId, workflow_version AS workflowVersion,
    conversation_revision AS conversationRevision, context_revision AS contextRevision,
    created_at AS createdAt, updated_at AS updatedAt
    FROM conversations WHERE thread_id = ?1 ORDER BY created_at, id`,
  )
    .bind(threadId)
    .all<Conversation>();
  return json({ conversations: result.results ?? [] });
}
