import { dataOf, queryOf, type Tx } from "../platform/data.js";
import {
  isDurableRealtimeEventType,
  parseRealtimeEvent,
  realtimeEventStream,
  type RealtimeStream,
  type RealtimeEventEnvelope,
  type RealtimeEventPayload,
} from "@syntila/protocol";

import { afterCommit, inOpenTransaction, rootEnv } from "../platform/tx-env.js";

export interface EventPublisherEnv {
  readonly SYNTILA_DB: D1Database;
  readonly SYNTILA_REALTIME_GATEWAY?: DurableObjectNamespace;
}

export interface DomainEventInput {
  readonly eventId?: string;
  readonly idempotencyKey?: string;
  readonly type: string;
  readonly workspaceId?: string;
  readonly stream?: RealtimeStream;
  readonly threadId?: string;
  /** Trusted route audience captured before a destructive mutation; never a wire field. */
  readonly recipientUserIds?: readonly string[];
  readonly additionalRecipientUserIds?: readonly string[];
  /** Optional domain writes committed in the same transaction as the signal. */
  /** Writes that commit in the same transaction as the event row. */
  readonly mutate?: (tx: Tx) => Promise<unknown>;
  readonly spaceId?: string;
  readonly runId?: string;
  readonly taskId?: string;
  readonly attemptId?: string;
  readonly assignmentId?: string;
  readonly workspaceRuntimeId?: string;
  readonly payload: RealtimeEventPayload;
  readonly durable?: boolean;
  readonly occurredAt?: string;
}

export interface PublishedEventResult {
  readonly event: RealtimeEventEnvelope;
  readonly persisted: boolean;
  readonly deliveredSubscribers: number;
}

export interface EventPublisher {
  publish(input: DomainEventInput): Promise<PublishedEventResult>;
}

function json(value: unknown): string {
  return JSON.stringify(value);
}

export function realtimeEventFromRow(
  row: Record<string, unknown>,
): RealtimeEventEnvelope {
  return parseRealtimeEvent({
    eventId: String(row.event_id),
    type: String(row.event_type),
    version:
      row.stream_kind && row.stream_kind !== "execution_workspace"
        ? "1.1"
        : "1.0",
    timestamp: String(row.occurred_at),
    ...(row.workspace_id ? { workspaceId: String(row.workspace_id) } : {}),
    ...(row.stream_kind && row.stream_kind !== "execution_workspace"
      ? {
          stream: { kind: row.stream_kind, id: row.stream_id },
        }
      : {}),
    ...(row.thread_id ? { threadId: String(row.thread_id) } : {}),
    ...(row.space_id ? { spaceId: String(row.space_id) } : {}),
    ...(row.run_id ? { runId: String(row.run_id) } : {}),
    ...(row.task_id ? { taskId: String(row.task_id) } : {}),
    ...(row.attempt_id ? { attemptId: String(row.attempt_id) } : {}),
    ...(row.assignment_id ? { assignmentId: String(row.assignment_id) } : {}),
    ...(row.workspace_runtime_id
      ? { workspaceRuntimeId: String(row.workspace_runtime_id) }
      : {}),
    sequence: Number(row.sequence),
    payload: JSON.parse(String(row.payload_json)) as RealtimeEventPayload,
  });
}

export class CloudEventPublisher implements EventPublisher {
  constructor(private readonly env: EventPublisherEnv) {}

  async publish(input: DomainEventInput): Promise<PublishedEventResult> {
    const durable = input.durable ?? isDurableRealtimeEventType(input.type);
    const eventId = input.eventId ?? `event-${crypto.randomUUID()}`;
    const idempotencyKey = input.idempotencyKey ?? eventId;
    const occurredAt = input.occurredAt ?? new Date().toISOString();

    let event: RealtimeEventEnvelope;
    let persisted = false;
    if (durable) {
      const result = await this.persistDurableEvent({
        ...input,
        eventId,
        idempotencyKey,
        occurredAt,
      });
      event = result.event;
      persisted = result.persisted;
    } else {
      event = parseRealtimeEvent({
        eventId,
        type: input.type,
        version:
          input.stream && input.stream.kind !== "execution_workspace"
            ? "1.1"
            : "1.0",
        timestamp: occurredAt,
        ...(input.workspaceId ? { workspaceId: input.workspaceId } : {}),
        ...(input.stream ? { stream: input.stream } : {}),
        ...(input.threadId ? { threadId: input.threadId } : {}),
        ...(input.spaceId ? { spaceId: input.spaceId } : {}),
        ...(input.runId ? { runId: input.runId } : {}),
        ...(input.taskId ? { taskId: input.taskId } : {}),
        ...(input.attemptId ? { attemptId: input.attemptId } : {}),
        ...(input.assignmentId ? { assignmentId: input.assignmentId } : {}),
        ...(input.workspaceRuntimeId
          ? { workspaceRuntimeId: input.workspaceRuntimeId }
          : {}),
        sequence: 0,
        payload: input.payload,
      });
    }

    // Inside a data-layer transaction the event row commits with the domain
    // writes; subscribers hear about it only after that commit.
    if (inOpenTransaction(this.env)) {
      const root = new CloudEventPublisher(rootEnv(this.env));
      afterCommit(this.env, () =>
        root.fanout(event, input.recipientUserIds, input.additionalRecipientUserIds));
      return { event, persisted, deliveredSubscribers: 0 };
    }
    const deliveredSubscribers = await this.fanout(
      event,
      input.recipientUserIds,
      input.additionalRecipientUserIds,
    );
    return { event, persisted, deliveredSubscribers };
  }

  private async persistDurableEvent(
    input: DomainEventInput & {
      eventId: string;
      idempotencyKey: string;
      occurredAt: string;
    },
  ): Promise<{ event: RealtimeEventEnvelope; persisted: boolean }> {
    const eventBase = {
      eventId: input.eventId,
      type: input.type,
      version:
        input.stream && input.stream.kind !== "execution_workspace"
          ? "1.1"
          : "1.0",
      timestamp: input.occurredAt,
      ...(input.workspaceId ? { workspaceId: input.workspaceId } : {}),
      ...(input.stream ? { stream: input.stream } : {}),
      ...(input.threadId ? { threadId: input.threadId } : {}),
      ...(input.spaceId ? { spaceId: input.spaceId } : {}),
      ...(input.runId ? { runId: input.runId } : {}),
      ...(input.taskId ? { taskId: input.taskId } : {}),
      ...(input.attemptId ? { attemptId: input.attemptId } : {}),
      ...(input.assignmentId ? { assignmentId: input.assignmentId } : {}),
      ...(input.workspaceRuntimeId
        ? { workspaceRuntimeId: input.workspaceRuntimeId }
        : {}),
      payload: input.payload,
    };
    // Validate the complete contract before a sequence can be consumed.
    const validated = parseRealtimeEvent({ ...eventBase, sequence: 0 });
    const stream = realtimeEventStream(validated);

    const db = this.env.SYNTILA_DB;
    // The caller's writes, the cursor bump and the event row commit together.
    // The stream's cursor row is locked first, then the caller's rows: every
    // writer of one stream takes locks in that order, so a Space deletion and
    // the posts racing it cannot deadlock on the cursor and the Space row.
    const inserted = await dataOf(this.env).tx("event.persist", async (tx) => {
      await tx.run`INSERT INTO realtime_event_cursors (stream_kind, stream_id, workspace_id, next_sequence)
           VALUES (${stream.kind}, ${stream.id}, ${input.workspaceId ?? null}, COALESCE(
             (SELECT MAX(sequence) + 1 FROM realtime_events
              WHERE stream_kind = ${stream.kind} AND COALESCE(stream_id, workspace_id) = ${stream.id}), 1))
           ON CONFLICT DO NOTHING`;
      await tx.run`UPDATE realtime_event_cursors SET next_sequence = next_sequence + 1
         WHERE stream_kind = ${stream.kind} AND COALESCE(stream_id, workspace_id) = ${stream.id}
           AND NOT EXISTS (SELECT 1 FROM realtime_events
             WHERE stream_kind = ${stream.kind} AND COALESCE(stream_id, workspace_id) = ${stream.id}
               AND (event_id = ${input.eventId} OR idempotency_key = ${input.idempotencyKey ?? null}))`;
      await input.mutate?.(tx);
      return tx.row<Record<string, unknown>>`INSERT INTO realtime_events
         (event_id, workspace_id, space_id, run_id, task_id, attempt_id,
          assignment_id, workspace_runtime_id, sequence, event_type, payload_json,
          idempotency_key, occurred_at, stream_kind, stream_id, thread_id)
         SELECT ${input.eventId}, ${input.workspaceId ?? null}, ${input.spaceId ?? null}, ${input.runId ?? null},
                ${input.taskId ?? null}, ${input.attemptId ?? null}, ${input.assignmentId ?? null},
                ${input.workspaceRuntimeId ?? null}, cursor.next_sequence - 1,
                ${input.type}, ${json(input.payload)}, ${input.idempotencyKey ?? null}, ${input.occurredAt}::timestamptz,
                ${stream.kind}, ${stream.id}, ${input.threadId ?? null}
         FROM realtime_event_cursors AS cursor
         WHERE cursor.stream_kind = ${stream.kind} AND COALESCE(cursor.stream_id, cursor.workspace_id) = ${stream.id}
           AND NOT EXISTS (SELECT 1 FROM realtime_events
             WHERE stream_kind = ${stream.kind} AND COALESCE(stream_id, workspace_id) = ${stream.id}
               AND (event_id = ${input.eventId} OR idempotency_key = ${input.idempotencyKey ?? null}))
         RETURNING *`;
    });
    if (inserted) {
      return { event: realtimeEventFromRow(inserted), persisted: true };
    }

    const duplicate = await queryOf(db).row<Record<string, unknown>>`SELECT * FROM realtime_events
         WHERE stream_kind = ${stream.kind} AND COALESCE(stream_id, workspace_id) = ${stream.id}
           AND (event_id = ${input.eventId} OR idempotency_key = ${input.idempotencyKey})
         LIMIT 1`;
    if (duplicate)
      return { event: realtimeEventFromRow(duplicate), persisted: false };
    throw new Error("Could not persist durable realtime event");
  }

  private async fanout(
    event: RealtimeEventEnvelope,
    recipientUserIds?: readonly string[],
    additionalRecipientUserIds: readonly string[] = [],
  ): Promise<number> {
    const gateway = this.env.SYNTILA_REALTIME_GATEWAY;
    if (!gateway) return 0;
    const stream = realtimeEventStream(event);
    const members = recipientUserIds
      ? recipientUserIds.map((user_id) => ({ user_id }))
      : stream.kind === "user"
        ? [{ user_id: stream.id }]
        : event.spaceId
          ? await dataOf(this.env).read.rows<{ user_id: string }>`SELECT user_id FROM space_memberships
           WHERE space_id = ${event.spaceId}`
          : await dataOf(this.env).read.rows<{ user_id: string }>`SELECT owner_user_id AS user_id FROM execution_workspaces
           WHERE id = ${event.workspaceId} AND status <> 'revoked'`;
    const results = await Promise.all(
      [
        ...new Set([
          ...members.map((row) => row.user_id),
          ...additionalRecipientUserIds,
        ]),
      ].map(async (userId) => {
        try {
          const response = await gateway.getByName(`user:${userId}`).fetch(
            new Request("https://realtime.internal/publish", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: json(event),
            }),
          );
          return response.ok;
        } catch {
          return false;
        }
      }),
    );
    return results.filter(Boolean).length;
  }
}

export function createEventPublisher(env: EventPublisherEnv): EventPublisher {
  return new CloudEventPublisher(env);
}
