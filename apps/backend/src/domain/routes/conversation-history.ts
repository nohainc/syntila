import type {
  ConversationHistoryEntry,
  ConversationHistoryPage,
} from "@syntila/core";
import { dataOf } from "../../platform/data.js";
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
  const db = dataOf(env).read;
  const scope = await db.row`
    SELECT id FROM conversations WHERE id = ${conversationId} AND thread_id = ${threadId}
  `;
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
  const revision = await db.row<{ revision: number }>`
    SELECT COALESCE(MAX(sequence),0) AS revision FROM conversation_history_entries WHERE conversation_id = ${conversationId}
  `;
  const historyRevision = revision?.revision ?? 0;
  const throughSequence = position?.through ?? historyRevision;
  if (throughSequence > historyRevision)
    throw new HttpError(
      400,
      "History cursor is outside this Conversation history",
    );
  const rows = await db.rows<
    Omit<ConversationHistoryEntry, "metadata"> & { metadataJson: string }
  >`
    SELECT id, conversation_id AS "conversationId", sequence,
     schema_version AS "schemaVersion", kind, event_type AS "eventType", actor_type AS "actorType",
     actor_id AS "actorId", work_request_id AS "workRequestId", turn_id AS "turnId", artifact_id AS "artifactId",
     source_id AS "sourceId", text, metadata_json AS "metadataJson", occurred_at AS "occurredAt", recorded_at AS "recordedAt"
    FROM conversation_history_entries WHERE conversation_id = ${conversationId} AND sequence > ${afterSequence} AND sequence <= ${throughSequence} ORDER BY sequence LIMIT ${limit + 1}
  `;
  const entries = rows
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
