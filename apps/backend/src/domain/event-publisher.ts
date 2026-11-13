import {
  isDurableRealtimeEventType,
  parseRealtimeEvent,
  realtimeEventStream,
  type RealtimeStream,
  type RealtimeEventEnvelope,
  type RealtimeEventPayload,
} from "@syntila/protocol";

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
  readonly mutations?: readonly D1PreparedStatement[];
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
    const results = await db.batch([
      ...(input.mutations ?? []),
      db
        .prepare(
          `INSERT INTO realtime_event_cursors (stream_kind, stream_id, workspace_id, next_sequence)
           VALUES (?1, ?2, ?3, COALESCE(
             (SELECT MAX(sequence) + 1 FROM realtime_events
              WHERE stream_kind = ?1 AND COALESCE(stream_id, workspace_id) = ?2), 1))
           ON CONFLICT DO NOTHING`,
        )
        .bind(stream.kind, stream.id, input.workspaceId ?? null),
      db
        .prepare(
          `UPDATE realtime_event_cursors SET next_sequence = next_sequence + 1
         WHERE stream_kind = ?1 AND COALESCE(stream_id, workspace_id) = ?2
           AND NOT EXISTS (SELECT 1 FROM realtime_events
             WHERE stream_kind = ?1 AND COALESCE(stream_id, workspace_id) = ?2
               AND (event_id = ?3 OR idempotency_key = ?4))
         RETURNING next_sequence - 1 AS sequence`,
        )
        .bind(
          stream.kind,
          stream.id,
          input.eventId,
          input.idempotencyKey ?? null,
        ),
      db
        .prepare(
          `INSERT INTO realtime_events
         (event_id, workspace_id, space_id, run_id, task_id, attempt_id,
          assignment_id, workspace_runtime_id, sequence, event_type, payload_json,
          idempotency_key, occurred_at, stream_kind, stream_id, thread_id)
         SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, cursor.next_sequence - 1,
                ?9, ?10, ?11, ?12, ?13, ?14, ?15
         FROM realtime_event_cursors AS cursor
         WHERE cursor.stream_kind = ?13 AND COALESCE(cursor.stream_id, cursor.workspace_id) = ?14
           AND NOT EXISTS (SELECT 1 FROM realtime_events
             WHERE stream_kind = ?13 AND COALESCE(stream_id, workspace_id) = ?14
               AND (event_id = ?1 OR idempotency_key = ?11))
         RETURNING *`,
        )
        .bind(
          input.eventId,
          input.workspaceId ?? null,
          input.spaceId ?? null,
          input.runId ?? null,
          input.taskId ?? null,
          input.attemptId ?? null,
          input.assignmentId ?? null,
          input.workspaceRuntimeId ?? null,
          input.type,
          json(input.payload),
          input.idempotencyKey ?? null,
          input.occurredAt,
          stream.kind,
          stream.id,
          input.threadId ?? null,
        ),
    ]);

    const inserted = results[results.length - 1]?.results?.[0] as
      Record<string, unknown> | undefined;
    if (inserted) {
      return { event: realtimeEventFromRow(inserted), persisted: true };
    }

    const duplicate = await db
      .prepare(
        `SELECT * FROM realtime_events
         WHERE stream_kind = ?1 AND COALESCE(stream_id, workspace_id) = ?2
           AND (event_id = ?3 OR idempotency_key = ?4)
         LIMIT 1`,
      )
      .bind(stream.kind, stream.id, input.eventId, input.idempotencyKey)
      .first<Record<string, unknown>>();
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
      ? { results: recipientUserIds.map((user_id) => ({ user_id })) }
      : stream.kind === "user"
        ? { results: [{ user_id: stream.id }] }
        : event.spaceId
          ? await this.env.SYNTILA_DB.prepare(
              `SELECT user_id FROM space_memberships
           WHERE space_id = ?1`,
            )
              .bind(event.spaceId)
              .all<{ user_id: string }>()
          : await this.env.SYNTILA_DB.prepare(
              `SELECT owner_user_id AS user_id FROM execution_workspaces
           WHERE id = ?1 AND status <> 'revoked'`,
            )
              .bind(event.workspaceId)
              .all<{ user_id: string }>();
    const results = await Promise.all(
      [
        ...new Set([
          ...(members.results ?? []).map((row) => row.user_id),
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
