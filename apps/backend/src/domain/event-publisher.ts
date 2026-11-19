import { dataOf, queryOf, type Tx, type Db } from "../platform/data.js";
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
  readonly SYNTILA_DB: Db;
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

    // Durable events are delivered from their outbox row (written in the same
    // transaction as the event), ephemeral ones straight to the gateway.
    // Inside a data-layer transaction nothing is sent before the commit.
    const send = (publisher: CloudEventPublisher) =>
      durable
        ? publisher.deliverOutbox(event)
        : publisher
            .fanout(event, input.recipientUserIds, input.additionalRecipientUserIds)
            .then((result) => result.delivered);
    if (inOpenTransaction(this.env)) {
      const root = new CloudEventPublisher(rootEnv(this.env));
      afterCommit(this.env, () => send(root));
      return { event, persisted, deliveredSubscribers: 0 };
    }
    return { event, persisted, deliveredSubscribers: await send(this) };
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
      const row = await tx.row<Record<string, unknown>>`INSERT INTO realtime_events
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
      // The outbox row commits with the event: a crash after the commit can
      // no longer lose the notification, the dispatcher finds this row.
      if (row)
        await tx.run`INSERT INTO outbox (event_id, audience_json)
           VALUES (${input.eventId}, ${audienceJson(input)}::text::jsonb)
           ON CONFLICT (event_id) DO NOTHING`;
      return row;
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

  /**
   * Claims this event's outbox row and delivers it. Returns the number of
   * subscribers reached; 0 when the row is already delivered or claimed
   * elsewhere, or when no gateway is configured (the row then stays pending
   * for a dispatcher that has one).
   */
  async deliverOutbox(event: RealtimeEventEnvelope): Promise<number> {
    if (!this.env.SYNTILA_REALTIME_GATEWAY) return 0;
    const claimed = await claimOutbox(this.env, event.eventId);
    return claimed ? this.deliverClaimed(claimed, event) : 0;
  }

  /** Delivers up to `limit` due rows in order; used by the dispatcher. */
  async deliverDueOutbox(limit = 100): Promise<number> {
    if (!this.env.SYNTILA_REALTIME_GATEWAY) return 0;
    let handled = 0;
    for (; handled < limit; handled++) {
      const claimed = await claimOutbox(this.env);
      if (!claimed) break;
      await this.deliverClaimed(claimed);
    }
    return handled;
  }

  private async deliverClaimed(
    claimed: ClaimedOutbox,
    known?: RealtimeEventEnvelope,
  ): Promise<number> {
    const q = dataOf(this.env).read;
    let event = known;
    if (!event) {
      const row = await q.row<Record<string, unknown>>`SELECT * FROM realtime_events WHERE event_id = ${claimed.eventId}`;
      // Pruned with its event (the outbox row cascades): nothing to deliver.
      if (!row) return 0;
      event = realtimeEventFromRow(row);
    }
    let result: FanoutResult;
    try {
      result = await this.fanout(
        event,
        claimed.audience?.recipients ?? undefined,
        claimed.audience?.additional ?? [],
      );
    } catch (error) {
      result = { delivered: 0, failed: 1, error: String((error as Error)?.message ?? error) };
    }
    if (result.failed === 0) {
      await q.run`UPDATE outbox SET status = 'delivered', delivered_at = now(), last_error = NULL
         WHERE id = ${claimed.id}::bigint`;
    } else {
      // Retry later with backoff; after OUTBOX_MAX_ATTEMPTS the row is dead and
      // clients recover through replay or a sync.
      await q.run`UPDATE outbox
           SET last_error = ${(result.error ?? `${result.failed} subscriber deliveries failed`).slice(0, 2000)},
               next_attempt_at = now() + make_interval(secs => LEAST(300, 2 * power(2, LEAST(attempts, 10)))),
               status = CASE WHEN attempts >= ${OUTBOX_MAX_ATTEMPTS}::int THEN 'dead' ELSE status END
         WHERE id = ${claimed.id}::bigint`;
    }
    return result.delivered;
  }

  private async fanout(
    event: RealtimeEventEnvelope,
    recipientUserIds?: readonly string[],
    additionalRecipientUserIds: readonly string[] = [],
  ): Promise<FanoutResult> {
    const gateway = this.env.SYNTILA_REALTIME_GATEWAY;
    if (!gateway) return { delivered: 0, failed: 0 };
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
    const delivered = results.filter(Boolean).length;
    return { delivered, failed: results.length - delivered };
  }

  /**
   * Periodic safety net (every few minutes):
   *  - repairs durable events that have no outbox row (a writer that bypassed
   *    the publisher, or events from before the outbox existed);
   *  - reports sequence gaps inside a stream's recent window;
   *  - expires Worker commands past their deadline.
   */
  async sweepOutbox(windowMinutes = 15): Promise<OutboxSweepResult> {
    const q = dataOf(this.env).read;
    const repaired = await q.run`INSERT INTO outbox (event_id, next_attempt_at)
       SELECT e.event_id, now() FROM realtime_events e
        WHERE e.occurred_at > now() - make_interval(mins => ${windowMinutes}::int)
          AND NOT EXISTS (SELECT 1 FROM outbox o WHERE o.event_id = e.event_id)
        LIMIT 1000
       ON CONFLICT (event_id) DO NOTHING`;
    const gaps = await q.rows<{ kind: string; id: string; sequence: number; previous: number }>`SELECT s.kind, s.id, s.sequence, s.previous
       FROM (
         SELECT e.stream_kind AS kind, COALESCE(e.stream_id, e.workspace_id) AS id, e.sequence,
                lag(e.sequence) OVER (PARTITION BY e.stream_kind, COALESCE(e.stream_id, e.workspace_id) ORDER BY e.sequence) AS previous
           FROM realtime_events e
          WHERE e.occurred_at > now() - make_interval(mins => ${windowMinutes}::int)
       ) s
       WHERE s.previous IS NOT NULL AND s.sequence <> s.previous + 1
       LIMIT 100`;
    const expiredCommands = await q.run`UPDATE agent_commands SET status = 'expired', updated_at = now()
       WHERE status IN ('pending', 'sent') AND expires_at < now()`;
    return {
      repaired: Number(repaired),
      gaps: gaps.map((g) => ({ kind: g.kind, id: g.id, sequence: Number(g.sequence), previous: Number(g.previous) })),
      expiredCommands: Number(expiredCommands),
    };
  }
}

export const OUTBOX_MAX_ATTEMPTS = 12;

export interface OutboxSweepResult {
  readonly repaired: number;
  readonly gaps: readonly { kind: string; id: string; sequence: number; previous: number }[];
  readonly expiredCommands: number;
}

interface FanoutResult {
  readonly delivered: number;
  readonly failed: number;
  readonly error?: string;
}

interface ClaimedOutbox {
  readonly id: string;
  readonly eventId: string;
  readonly audience: { recipients: string[] | null; additional: string[] } | null;
}

/** Trusted audience captured with the event; null when it is resolved at delivery. */
function audienceJson(input: DomainEventInput): string | null {
  if (!input.recipientUserIds && !input.additionalRecipientUserIds?.length) return null;
  return JSON.stringify({
    recipients: input.recipientUserIds ?? null,
    additional: input.additionalRecipientUserIds ?? [],
  });
}

/**
 * Takes one pending outbox row with `FOR UPDATE SKIP LOCKED` and leases it for
 * 30 s (`next_attempt_at`), so two processes never deliver the same row at the
 * same time. With `eventId` it takes that event's row: a fresh row
 * (attempts = 0) or one whose lease or backoff has passed. Without, the oldest
 * row that is due, which is how a restarted process finds what the previous one
 * did not finish.
 */
async function claimOutbox(
  env: EventPublisherEnv,
  eventId?: string,
): Promise<ClaimedOutbox | null> {
  const q = dataOf(env).read;
  const row = eventId
    ? await q.row<{ id: string; eventId: string; audience: string | null }>`UPDATE outbox
         SET attempts = attempts + 1, next_attempt_at = now() + interval '30 seconds'
       WHERE id = (SELECT id FROM outbox
                    WHERE event_id = ${eventId} AND status = 'pending'
                      AND (attempts = 0 OR next_attempt_at <= now())
                    FOR UPDATE SKIP LOCKED)
       RETURNING id::text AS id, event_id AS "eventId", audience_json::text AS audience`
    : await q.row<{ id: string; eventId: string; audience: string | null }>`UPDATE outbox
         SET attempts = attempts + 1, next_attempt_at = now() + interval '30 seconds'
       WHERE id = (SELECT id FROM outbox
                    WHERE status = 'pending' AND next_attempt_at <= now()
                    ORDER BY id LIMIT 1
                    FOR UPDATE SKIP LOCKED)
       RETURNING id::text AS id, event_id AS "eventId", audience_json::text AS audience`;
  if (!row) return null;
  return {
    id: row.id,
    eventId: row.eventId,
    audience: row.audience ? (JSON.parse(row.audience) as ClaimedOutbox["audience"]) : null,
  };
}

export function createEventPublisher(env: EventPublisherEnv): EventPublisher {
  return new CloudEventPublisher(env);
}
