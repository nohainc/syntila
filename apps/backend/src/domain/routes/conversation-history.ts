import type {
  ConversationHistoryEntry,
  ConversationHistoryPage,
} from "@syntila/core";
import { authorizeThreadAccess } from "./thread-policy.js";
import { HttpError, json, type SecurityEnv } from "./http-security.js";
import { decodeSequenceCursor, encodeSequenceCursor } from "./pagination.js";

export async function handleListConversationHistory(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  conversationId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeThreadAccess(request, env, threadId, "view", accessContext);
  const scope = await env.SYNTILA_DB.prepare(
    "SELECT id FROM conversations WHERE id = ?1 AND thread_id = ?2",
  )
    .bind(conversationId, threadId)
    .first();
  if (!scope) throw new HttpError(404, "Conversation not found");
  const params = new URL(request.url).searchParams;
  const rawLimit = params.get("limit") ?? "50";
  const limit = Number(rawLimit);
  if (!/^\d+$/.test(rawLimit) || limit < 1 || limit > 100)
    throw new HttpError(400, "limit must be between 1 and 100");
  // The first page pins the current end of history; the cursor carries it,
  // so later pages read the same snapshot while new entries are appended.
  const rawCursor = params.get("cursor");
  const position = rawCursor ? decodeSequenceCursor(rawCursor) : null;
  const afterSequence = position?.after ?? 0;
  const revision = await env.SYNTILA_DB.prepare(
    "SELECT COALESCE(MAX(sequence),0) AS revision FROM conversation_history_entries WHERE conversation_id = ?1",
  )
    .bind(conversationId)
    .first<{ revision: number }>();
  const historyRevision = revision?.revision ?? 0;
  const throughSequence = position?.through ?? historyRevision;
  if (throughSequence > historyRevision)
    throw new HttpError(
      400,
      "History cursor is outside this Conversation history",
    );
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT id, conversation_id AS conversationId, sequence,
 schema_version AS schemaVersion, kind, event_type AS eventType, actor_type AS actorType,
 actor_id AS actorId, work_request_id AS workRequestId, turn_id AS turnId, artifact_id AS artifactId,
 source_id AS sourceId, text, metadata_json AS metadataJson, occurred_at AS occurredAt, recorded_at AS recordedAt
 FROM conversation_history_entries WHERE conversation_id = ?1 AND sequence > ?2 AND sequence <= ?3 ORDER BY sequence LIMIT ?4`,
  )
    .bind(conversationId, afterSequence, throughSequence, limit + 1)
    .all<
      Omit<ConversationHistoryEntry, "metadata"> & { metadataJson: string }
    >();
  const entries = (rows.results ?? [])
    .slice(0, limit)
    .map(({ metadataJson, ...entry }) => ({
      ...entry,
      metadata: JSON.parse(metadataJson) as Record<string, unknown>,
    }));
  const page: ConversationHistoryPage = {
    conversationId,
    historyRevision,
    throughSequence,
    entries,
    nextCursor:
      (rows.results?.length ?? 0) > limit
        ? encodeSequenceCursor(entries.at(-1)!.sequence, throughSequence)
        : null,
  };
  return json(page);
}
