import { dataOf, queryOf, type Query, type Db } from "../platform/data.js";
import { userAccount } from "./queries.js";
import {
  isReplayableRealtimeEvent,
  parseRealtimeEvent,
  realtimeEventStream,
  realtimeStreamKey,
  RealtimeStreamSchema,
  type RealtimeEventEnvelope,
  type RealtimeStream,
} from "@syntila/protocol";
import { realtimeEventFromRow } from "./event-publisher.js";
import {
  identityService,
  type AuthenticatedIdentity,
} from "./auth/index.js";
import {
  BoundedRealtimeQueue,
  type RealtimeQueueEnqueueResult,
} from "./realtime-queue.js";

import { buildEnvelope, eventContext, isMessagingFrame, type StreamRef } from "./messaging/envelope.js";
import { MAX_REPLAY_EVENTS as MAX_UNIFIED_REPLAY, MessagingSession } from "./messaging/session.js";
import { SubscriptionRegistry } from "./messaging/subscription-registry.js";

export interface RealtimeScope {
  kind?: "user" | "space" | "thread" | "run";
  spaceId?: string;
  threadId?: string;
  runId?: string;
}

export interface RealtimeGatewayEnv {
  readonly SYNTILA_DB: Db;
}

interface ConnectedClient {
  readonly socket: WebSocket;
  readonly identity: AuthenticatedIdentity;
  readonly subscriptions: Map<string, RealtimeScope>;
  /**
   * Per stream: the newest durable event handed to this connection's queue or
   * socket. Used only for duplicate suppression and gap detection on this
   * connection. It is not an acknowledgement, is never stored, and is reset
   * when the queue overflows. Subscription scopes only control delivery.
   */
  readonly lastEnqueuedSequences: Map<string, number>;
  /**
   * Per stream: the newest event the client reported as applied (its `hello`
   * cursors and later `ack` messages), or covered by an authoritative rebase.
   * Only a client acknowledgement moves it.
   */
  readonly appliedSequences: Map<string, number>;
  readonly queue: BoundedRealtimeQueue;
  flushScheduled: boolean;
  /** `syntila.messaging/1` session, created by the first unified frame. */
  unified?: MessagingSession;
  /** Mirror of the registry's streams for this connection, kept for storage. */
  unifiedStreams?: StreamRef[];
  /**
   * Set when the queue overflowed and the client was told to synchronize.
   * Until its next hello the connection takes no more frames, so a client that
   * stays slow costs a constant amount of memory and one control frame.
   */
  resyncPending?: boolean;
  /** Last subscriptions written to storage; skips equal writes. Cursors are never stored. */
  persisted?: string;
}

/** Travels with the hibernated socket; small and fixed for the connection. */
interface ConnectionAttachment {
  readonly connectionId: string;
  readonly identity: AuthenticatedIdentity;
}

/** Per-connection state that changes, kept in storage across hibernation. */
interface PersistedConnection {
  readonly subscriptions: RealtimeScope[];
  readonly unifiedStreams?: StreamRef[];
}

export interface RealtimeGatewayMetrics {
  activeAppSockets: number;
  publishedEvents: number;
  ephemeralDropped: number;
  ephemeralCoalesced: number;
  reconnects: number;
  durableResyncs: number;
  maxQueueDepth: number;
  maxQueueBytes: number;
  queueOverflows: number;
  eventToUiLatencyMs: number;
}

const MAX_SOCKET_BUFFERED_BYTES = 256 * 1024;
const MAX_REPLAY_EVENTS = 256;
/** Retry period for a blocked flush; the drain callback normally comes first. */
const DRAIN_FALLBACK_MS = 250;
const CONNECTION_STORAGE_PREFIX = "connection:";
// Answered by the runtime without waking the Durable Object, so an idle
// connection costs no duration. Must match the App's ping frame exactly.
const PING_FRAME = JSON.stringify({ type: "ping" });
const PONG_FRAME = JSON.stringify({ type: "realtime.pong" });

export function scopeKey(scope: RealtimeScope): string {
  if (scope.kind) {
    return `${scope.kind}=${scope.spaceId ?? scope.threadId ?? scope.runId ?? ""}`;
  }
  return ["spaceId", "runId"]
    .map((field) => `${field}=${scope[field as keyof RealtimeScope] ?? ""}`)
    .join("&");
}

export function reconnectDelayMs(
  attempt: number,
  random = Math.random(),
): number {
  const boundedAttempt = Math.max(0, Math.min(Math.floor(attempt), 8));
  const base = Math.min(30_000, 500 * 2 ** boundedAttempt);
  return Math.floor(base * (0.75 + Math.max(0, Math.min(1, random)) * 0.5));
}

export function realtimeAuthenticationError(
  identity: AuthenticatedIdentity | null,
  userStatus?: string | null,
): string | null {
  if (!identity) return "Authentication required";
  if (userStatus && userStatus !== "active") return "User account is suspended";
  return null;
}

export function eventMatchesScope(
  event: RealtimeEventEnvelope,
  scope: RealtimeScope,
): boolean {
  if (scope.kind === "user") return true;
  if (scope.kind === "space") return event.spaceId === scope.spaceId;
  if (scope.kind === "thread") return event.threadId === scope.threadId;
  if (scope.kind === "run") return event.runId === scope.runId;
  return false;
}

export function requiresRealtimeReconnect(
  lastDurableSequence: number | null,
  nextDurableSequence: number,
): boolean {
  return (
    lastDurableSequence !== null &&
    nextDurableSequence > lastDurableSequence + 1
  );
}

export async function authorizeRealtimeScope(
  db: Db,
  userId: string,
  scope: RealtimeScope,
): Promise<{ allowed: true } | { allowed: false; reason: string }> {
  if (scope.kind === "user") return { allowed: true };
  if (scope.kind === "space") {
    const member = await queryOf(db).row<{ member: number }>`SELECT 1 AS member FROM space_memberships WHERE space_id = ${scope.spaceId} AND user_id = ${userId}`;
    return member
      ? { allowed: true }
      : { allowed: false, reason: "space_access_denied" };
  }
  if (scope.kind === "thread") {
    const member = await queryOf(db).row<{ member: number }>`SELECT 1 AS member FROM threads w
       JOIN space_memberships pm ON pm.space_id = w.space_id
       WHERE w.id = ${scope.threadId} AND pm.user_id = ${userId}`;
    return member
      ? { allowed: true }
      : { allowed: false, reason: "thread_access_denied" };
  }
  if (scope.kind === "run") {
    const row = await queryOf(db).row<{ user_id: string }>`SELECT pm.user_id FROM space_memberships pm
       JOIN runs resource ON resource.space_id = pm.space_id
       WHERE resource.id = ${scope.runId} AND pm.user_id = ${userId}`;
    return row
      ? { allowed: true }
      : { allowed: false, reason: `${scope.kind}_access_denied` };
  }
  return { allowed: false, reason: "scope_access_denied" };
}

export async function isRealtimeIdentityAuthorized(
  db: Db,
  userId: string,
  scopes: readonly RealtimeScope[],
): Promise<boolean> {
  const user = await userAccount(queryOf(db), userId);
  if (!user || user.status !== "active") return false;
  for (const scope of scopes) {
    const result = await authorizeRealtimeScope(db, userId, scope);
    if (!result.allowed) return false;
  }
  return true;
}

function serializeConnection(connected: ConnectedClient): string {
  return JSON.stringify({
    subscriptions: [...connected.subscriptions.values()],
    unifiedStreams: connected.unified ? connected.unifiedStreams : [],
  } satisfies PersistedConnection);
}

export class RealtimeGateway implements DurableObject {
  private readonly clients = new Map<string, ConnectedClient>();
  private readonly registry = new SubscriptionRegistry();
  private restored: Promise<void> | null = null;
  private readonly metrics: RealtimeGatewayMetrics = {
    activeAppSockets: 0,
    publishedEvents: 0,
    ephemeralDropped: 0,
    ephemeralCoalesced: 0,
    reconnects: 0,
    durableResyncs: 0,
    maxQueueDepth: 0,
    maxQueueBytes: 0,
    queueOverflows: 0,
    eventToUiLatencyMs: 0,
  };

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: RealtimeGatewayEnv,
  ) {
    if (typeof WebSocketRequestResponsePair !== "undefined") {
      this.state.setWebSocketAutoResponse?.(
        new WebSocketRequestResponsePair(PING_FRAME, PONG_FRAME),
      );
    }
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    await this.restoreClients();
    if (request.method === "POST" && url.pathname === "/publish") {
      return this.publish(request);
    }
    if (request.method === "GET" && url.pathname === "/metrics") {
      return Response.json({
        ...this.metrics,
        activeAppSockets: this.clients.size,
        queueDepth: [...this.clients.values()].reduce(
          (total, client) => total + client.queue.depth,
          0,
        ),
        queuedBytes: [...this.clients.values()].reduce(
          (total, client) => total + client.queue.byteSize,
          0,
        ),
      });
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return Response.json(
        { error: "Expected WebSocket upgrade" },
        { status: 426 },
      );
    }

    const identity = await identityService.resolve(request, this.env);
    if (!identity) {
      return Response.json(
        { error: "Authentication required" },
        { status: 401 },
      );
    }
    const user = await userAccount(dataOf(this.env).read, identity.userId);
    const accountError = realtimeAuthenticationError(identity, user?.status);
    if (accountError) {
      return Response.json({ error: accountError }, { status: 403 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const connectionId = crypto.randomUUID();
    const connected: ConnectedClient = {
      socket: server,
      identity,
      subscriptions: new Map(),
      lastEnqueuedSequences: new Map(),
      appliedSequences: new Map(),
      queue: new BoundedRealtimeQueue(),
      flushScheduled: false,
    };
    this.bindDrain(connected);
    this.clients.set(connectionId, connected);
    this.metrics.activeAppSockets = this.clients.size;
    // Hibernatable: the Durable Object is evicted while the socket is idle and
    // restored from the attachment and storage when a message or event arrives.
    server.serializeAttachment({
      connectionId,
      identity,
    } satisfies ConnectionAttachment);
    this.state.acceptWebSocket(server);
    this.sendRaw(server, {
      type: "realtime.ready",
      connectionId,
      eventVersion: "1.1",
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(
    socket: WebSocket,
    data: string | ArrayBuffer,
  ): Promise<void> {
    const connectionId = this.connectionIdOf(socket);
    if (!connectionId) return;
    await this.restoreClients();
    await this.handleClientMessage(connectionId, data);
  }

  async webSocketClose(socket: WebSocket): Promise<void> {
    try {
      socket.close(1000, "Closing");
    } catch {
      // The runtime may already have completed the closing handshake.
    }
    await this.endSocket(socket);
  }

  async webSocketError(socket: WebSocket): Promise<void> {
    await this.endSocket(socket);
  }

  private async endSocket(socket: WebSocket): Promise<void> {
    const connectionId = this.connectionIdOf(socket);
    if (!connectionId) return;
    await this.removeClient(connectionId);
  }

  private connectionIdOf(socket: WebSocket): string | null {
    const attachment =
      socket.deserializeAttachment() as ConnectionAttachment | null;
    return attachment?.connectionId ?? null;
  }

  private get storage(): DurableObjectStorage | undefined {
    return (this.state as Partial<DurableObjectState>).storage;
  }

  /**
   * Rebuilds the connection map after hibernation, which discards memory but
   * keeps the sockets. Runs once per wake.
   */
  private restoreClients(): Promise<void> {
    return (this.restored ??= this.loadClients().catch((error: unknown) => {
      this.restored = null;
      throw error;
    }));
  }

  private async loadClients(): Promise<void> {
    const sockets = this.state.getWebSockets?.() ?? [];
    const stored =
      (await this.storage?.list<PersistedConnection>({
        prefix: CONNECTION_STORAGE_PREFIX,
      })) ?? new Map<string, PersistedConnection>();
    const live = new Set<string>();
    for (const socket of sockets) {
      const attachment =
        socket.deserializeAttachment() as ConnectionAttachment | null;
      if (!attachment?.connectionId) continue;
      live.add(attachment.connectionId);
      if (this.clients.has(attachment.connectionId)) continue;
      const persisted = stored.get(
        CONNECTION_STORAGE_PREFIX + attachment.connectionId,
      );
      const connected: ConnectedClient = {
        socket,
        identity: attachment.identity,
        subscriptions: new Map(
          (persisted?.subscriptions ?? []).map((scope) => [
            scopeKey(scope),
            scope,
          ]),
        ),
        // Cursors are not stored: after a restore the connection follows live
        // events, and the client's next hello or ack sets its applied position.
        lastEnqueuedSequences: new Map(),
        appliedSequences: new Map(),
        queue: new BoundedRealtimeQueue(),
        flushScheduled: false,
      };
      if (persisted?.unifiedStreams?.length) {
        connected.unified = this.newSession(attachment.connectionId, attachment.identity.userId);
        connected.unifiedStreams = [...persisted.unifiedStreams];
        for (const stream of persisted.unifiedStreams)
          this.registry.restore(attachment.connectionId, connected.unified.principal, stream);
      }
      this.bindDrain(connected);
      connected.persisted = serializeConnection(connected);
      this.clients.set(attachment.connectionId, connected);
    }
    // A close that never reached this object leaves its state behind.
    const orphaned = [...stored.keys()].filter(
      (key) => !live.has(key.slice(CONNECTION_STORAGE_PREFIX.length)),
    );
    if (orphaned.length > 0) await this.storage?.delete(orphaned);
    this.metrics.activeAppSockets = this.clients.size;
  }

  /** Writes subscriptions and cursors when they changed since the last write. */
  private async persistClient(
    connectionId: string,
    connected: ConnectedClient,
  ): Promise<void> {
    if (this.clients.get(connectionId) !== connected) return;
    const serialized = serializeConnection(connected);
    if (serialized === connected.persisted) return;
    connected.persisted = serialized;
    await this.storage?.put(
      CONNECTION_STORAGE_PREFIX + connectionId,
      JSON.parse(serialized) as PersistedConnection,
    );
  }

  private async removeClient(connectionId: string): Promise<void> {
    this.clients.delete(connectionId);
    this.registry.closeConnection(connectionId);
    this.metrics.activeAppSockets = this.clients.size;
    await this.storage?.delete(CONNECTION_STORAGE_PREFIX + connectionId);
  }

  private async handleClientMessage(
    connectionId: string,
    data: unknown,
  ): Promise<void> {
    const connected = this.clients.get(connectionId);
    if (!connected) return;
    try {
      const input = JSON.parse(
        typeof data === "string"
          ? data
          : new TextDecoder().decode(data as ArrayBuffer),
      );
      if (isMessagingFrame(input)) {
        await this.handleUnified(connectionId, connected, input);
        return;
      }
      this.sendRaw(connected.socket, {
        type: "subscription.denied",
        reason: "Unsupported realtime protocol; use syntila.messaging/1",
      });
    } catch (error) {
      this.sendRaw(connected.socket, {
        type: "subscription.denied",
        reason:
          error instanceof Error ? error.message : "Malformed realtime message",
      });
    } finally {
      await this.persistClient(connectionId, connected);
    }
  }

  private newSession(connectionId: string, userId: string): MessagingSession {
    return new MessagingSession(connectionId, { kind: "human", id: userId }, {
      registry: this.registry,
      // The unified protocol serves the streams that own a durable sequence.
      supports: (stream) => stream.kind === "user" || stream.kind === "space" || stream.kind === "thread",
      // A Thread has no sequence of its own: it is the Thread's slice of its
      // Space stream, numbered by the Space sequence.
      gapless: (stream) => stream.kind !== "thread",
      authorize: async (principal, stream) =>
        (
          await authorizeRealtimeScope(
            this.env.SYNTILA_DB,
            principal.id,
            stream.kind === "space"
              ? { kind: "space", spaceId: stream.id }
              : stream.kind === "thread"
                ? { kind: "thread", threadId: stream.id }
                : { kind: "user" },
          )
        ).allowed,
      head: async (stream) => {
        const space = await this.backingStream(stream);
        if (!space) return 0;
        const row = await dataOf(this.env).read.row<{ head: string | null }>`SELECT MAX(sequence)::text AS head FROM realtime_events
           WHERE stream_kind = ${space.kind} AND stream_id = ${space.id}`;
        return Number(row?.head ?? 0);
      },
      // Resume from a client's cursor: the kept durable events above it.
      replay: async (stream, afterSequence, throughSequence) => {
        const backing = await this.backingStream(stream);
        if (!backing) return null;
        const threadId = stream.kind === "thread" ? stream.id : null;
        const rows = await dataOf(this.env).read.rows<{ eventId: string; eventType: string; sequence: string; payloadJson: string; occurredAt: string | Date; runId: string | null; assignmentId: string | null; spaceId: string | null; threadId: string | null; taskId: string | null; attemptId: string | null }>`SELECT event_id AS "eventId", event_type AS "eventType", sequence::text AS sequence,
                  payload_json AS "payloadJson", occurred_at AS "occurredAt", run_id AS "runId", assignment_id AS "assignmentId",
                  space_id AS "spaceId", thread_id AS "threadId", task_id AS "taskId", attempt_id AS "attemptId"
             FROM realtime_events
            WHERE stream_kind = ${backing.kind} AND stream_id = ${backing.id}
              AND event_type <> 'assignment.activity'
              AND (${threadId}::text IS NULL OR thread_id = ${threadId}::text)
              AND sequence > ${afterSequence}::bigint AND sequence <= ${throughSequence}::bigint
            ORDER BY sequence ASC LIMIT ${MAX_UNIFIED_REPLAY + 1}`;
        if (rows.length > MAX_UNIFIED_REPLAY) return null;
        return rows.map((row) => {
          const occurredAt = row.occurredAt instanceof Date ? row.occurredAt.toISOString() : new Date(row.occurredAt).toISOString();
          return buildEnvelope({
            eventId: row.eventId, type: row.eventType, occurredAt, stream, sequence: Number(row.sequence),
            ...(row.runId || row.assignmentId ? { correlationId: row.assignmentId ?? row.runId ?? undefined } : {}),
            context: eventContext({ spaceId: row.spaceId, threadId: row.threadId, runId: row.runId, taskId: row.taskId, attemptId: row.attemptId, assignmentId: row.assignmentId }),
            payload: JSON.parse(row.payloadJson) as Record<string, unknown>,
          });
        });
      },
    });
  }

  /** The durable stream that numbers [stream]'s events: a Thread's is its Space's. */
  private async backingStream(stream: StreamRef): Promise<StreamRef | null> {
    if (stream.kind !== "thread") return stream;
    const row = await dataOf(this.env).read.row<{ spaceId: string }>`SELECT space_id AS "spaceId" FROM threads WHERE id = ${stream.id}`;
    return row ? { kind: "space", id: row.spaceId } : null;
  }

  private async handleUnified(connectionId: string, connected: ConnectedClient, input: unknown): Promise<void> {
    connected.unified ??= this.newSession(connectionId, connected.identity.userId);
    for (const envelope of await connected.unified.handle(input)) this.sendRaw(connected.socket, envelope);
    connected.unifiedStreams = this.registry.streamsOf(connectionId);
  }

  /** Delivers [event] to unified subscribers, then re-checks access when it can have changed. */
  private async publishUnified(event: RealtimeEventEnvelope, stream: RealtimeStream): Promise<void> {
    if (stream.kind !== "user" && stream.kind !== "space") return;
    const ref: StreamRef = { kind: stream.kind, id: stream.id };
    const envelope = buildEnvelope({
      eventId: event.eventId, type: event.type, occurredAt: event.timestamp, stream: ref,
      ...(isReplayableRealtimeEvent(event) ? { sequence: event.sequence } : {}),
      ...(event.runId || event.assignmentId ? { correlationId: event.assignmentId ?? event.runId } : {}),
      context: eventContext({
        spaceId: event.spaceId, threadId: event.threadId, runId: event.runId, taskId: event.taskId,
        attemptId: event.attemptId, assignmentId: event.assignmentId,
      }),
      payload: event.payload as Record<string, unknown>,
    });
    for (const delivery of this.registry.publish(envelope)) {
      const connected = this.clients.get(delivery.connectionId);
      if (connected) this.sendRaw(connected.socket, delivery.envelope);
    }
    // A Thread's subscribers receive the Space events that belong to the Thread.
    if (stream.kind === "space" && event.threadId) {
      const threadEnvelope = { ...envelope, stream: { kind: "thread", id: event.threadId } as StreamRef };
      for (const delivery of this.registry.publish(threadEnvelope)) {
        const connected = this.clients.get(delivery.connectionId);
        if (connected) this.sendRaw(connected.socket, delivery.envelope);
      }
    }
    // Losing the Space (or the Thread's Space membership) ends the Thread views too.
    if (stream.kind === "space" && (event.type === "space.deleted" || event.type === "space.updated" || event.type === "people.updated")) {
      for (const sub of this.registry.subscribersOfKind("thread")) {
        if ((await authorizeRealtimeScope(this.env.SYNTILA_DB, sub.principal.id, { kind: "thread", threadId: sub.stream.id })).allowed) continue;
        this.registry.unsubscribe(sub.connectionId, sub.stream);
        const connected = this.clients.get(sub.connectionId);
        if (!connected) continue;
        connected.unifiedStreams = this.registry.streamsOf(sub.connectionId);
        this.sendRaw(connected.socket, buildEnvelope({ type: "subscription.denied", stream: sub.stream, payload: { reason: "access_revoked", stream: sub.stream } }));
        await this.persistClient(sub.connectionId, connected);
      }
    }
    // Membership can change with these; ask only this stream's subscribers.
    if (stream.kind === "space" && (event.type === "space.deleted" || event.type === "space.updated")) {
      for (const sub of this.registry.subscribersOf(ref)) {
        const ok = event.type === "space.deleted"
          ? false
          : (await authorizeRealtimeScope(this.env.SYNTILA_DB, sub.principal.id, { kind: "space", spaceId: ref.id })).allowed;
        if (ok) continue;
        this.registry.unsubscribe(sub.connectionId, ref);
        const connected = this.clients.get(sub.connectionId);
        if (!connected) continue;
        connected.unifiedStreams = this.registry.streamsOf(sub.connectionId);
        this.sendRaw(connected.socket, buildEnvelope({ type: "subscription.denied", stream: ref, payload: { reason: "access_revoked", stream: ref } }));
        await this.persistClient(sub.connectionId, connected);
      }
    }
  }

  private async publish(request: Request): Promise<Response> {
    try {
      const event = parseRealtimeEvent(await request.json());
      this.metrics.publishedEvents += 1;
      const stream = realtimeEventStream(event);
      const streamKey = realtimeStreamKey(stream);
      for (const [connectionId, connected] of [...this.clients.entries()]) {
        await this.publishTo(connectionId, connected, event, stream, streamKey);
        await this.persistClient(connectionId, connected);
      }
      await this.publishUnified(event, stream);
      return Response.json({ delivered: true });
    } catch (error) {
      return Response.json(
        {
          error:
            error instanceof Error ? error.message : "Invalid realtime event",
        },
        { status: 400 },
      );
    }
  }

  private async publishTo(
    connectionId: string,
    connected: ConnectedClient,
    event: RealtimeEventEnvelope,
    stream: RealtimeStream,
    streamKey: string,
  ): Promise<void> {
    // Deletion removes memberships. Deliver its ID-only signal to the
    // captured audience without keeping now-invalid focused subscriptions.
    if (event.type === "space.deleted") {
      for (const [key, scope] of connected.subscriptions) {
        if (
          scope.spaceId === event.spaceId ||
          ((scope.kind === "thread" || scope.kind === "run") &&
            !(
              await authorizeRealtimeScope(
                this.env.SYNTILA_DB,
                connected.identity.userId,
                scope,
              )
            ).allowed)
        ) {
          connected.subscriptions.delete(key);
        }
      }
    }
    if (
      !(await isRealtimeIdentityAuthorized(
        this.env.SYNTILA_DB,
        connected.identity.userId,
        [...connected.subscriptions.values()],
      ))
    ) {
      connected.socket.close(1008, "Realtime authorization revoked");
      await this.removeClient(connectionId);
      return;
    }
    if (stream.kind === "user" && stream.id !== connected.identity.userId)
      return;
    if (stream.kind === "space" && event.type !== "space.deleted") {
      const member = await authorizeRealtimeScope(
        this.env.SYNTILA_DB,
        connected.identity.userId,
        { kind: "space", spaceId: stream.id },
      );
      if (!member.allowed) return;
    }
    const matchingScopes = [...connected.subscriptions.values()].filter(
      (scope) => eventMatchesScope(event, scope),
    );
    if (matchingScopes.length === 0) return;
    const replayable = isReplayableRealtimeEvent(event);
    const lastSequence = connected.lastEnqueuedSequences.get(streamKey);
    if (
      replayable &&
      lastSequence !== undefined &&
      event.sequence <= lastSequence
    ) {
      return;
    }
    const gapScope = replayable
      ? matchingScopes.find((_scope) =>
          requiresRealtimeReconnect(lastSequence ?? null, event.sequence),
        )
      : undefined;
    if (gapScope) {
      this.metrics.reconnects += 1;
      const recoveryScope =
        stream.kind === "space"
          ? { kind: "space" as const, spaceId: stream.id }
          : stream.kind === "user"
            ? { kind: "user" as const }
            : gapScope;
      await this.replayScope(connected, recoveryScope, event);
      if (
        connected.lastEnqueuedSequences.get(streamKey) ===
        event.sequence - 1
      ) {
        const result = this.enqueueEvent(connected, event);
        this.recordQueueResult(result);
        if (result !== "resync-required") {
          connected.lastEnqueuedSequences.set(streamKey, event.sequence);
        }
      }
      return;
    }
    const result = this.enqueueEvent(connected, event);
    this.recordQueueResult(result);
    // A refused durable frame was not enqueued: its position must not count.
    if (replayable && result !== "resync-required") {
      connected.lastEnqueuedSequences.set(
        streamKey,
        Math.max(
          connected.lastEnqueuedSequences.get(streamKey) ?? 0,
          event.sequence,
        ),
      );
    }
  }

  private enqueueEvent(
    connected: ConnectedClient,
    event: RealtimeEventEnvelope,
  ): RealtimeQueueEnqueueResult {
    const durable = isReplayableRealtimeEvent(event);
    const coalesceKey = durable
      ? undefined
      : `${event.type}:${realtimeStreamKey(realtimeEventStream(event))}:${event.spaceId ?? ""}:${event.runId ?? ""}:${event.assignmentId ?? ""}`;
    if (connected.resyncPending) return durable ? "resync-required" : "dropped";
    const frame = JSON.stringify({ type: "event", event });
    const hosted = connected.socket as WebSocket & {
      bufferedAmount?: number;
      backpressured?: boolean;
    };
    if (
      connected.queue.depth === 0 &&
      hosted.bufferedAmount !== undefined &&
      !hosted.backpressured &&
      Number(hosted.bufferedAmount) < MAX_SOCKET_BUFFERED_BYTES
    ) {
      this.sendSerialized(connected.socket, frame);
      this.recordLatency(event);
      return "queued";
    }
    const result = connected.queue.enqueue({ frame, durable, coalesceKey });
    this.metrics.maxQueueDepth = Math.max(
      this.metrics.maxQueueDepth,
      connected.queue.depth,
    );
    this.metrics.maxQueueBytes = Math.max(
      this.metrics.maxQueueBytes,
      connected.queue.byteSize,
    );
    if (result === "resync-required") {
      this.metrics.durableResyncs += 1;
      this.metrics.queueOverflows += 1;
      connected.queue.clear();
      connected.resyncPending = true;
      // The cleared frames were counted as enqueued but never sent. Forget the
      // enqueue positions: the client is told to synchronize, and its next
      // hello and acks set the real ones. Applied positions stay.
      connected.lastEnqueuedSequences.clear();
      this.sendRaw(connected.socket, {
        type: "sync.required",
        reason: "connection_queue_limit",
        ...(realtimeEventStream(event).kind === "space"
          ? {
              scope: {
                kind: "space",
                spaceId: realtimeEventStream(event).id,
              },
            }
          : {}),
        stream: realtimeEventStream(event),
        ...(connected.appliedSequences.has(
          realtimeStreamKey(realtimeEventStream(event)),
        )
          ? {
              appliedSequence: connected.appliedSequences.get(
                realtimeStreamKey(realtimeEventStream(event)),
              ),
            }
          : {}),
        nextSequence: event.sequence,
      });
      return result;
    }
    this.scheduleFlush(connected);
    return result;
  }

  /** Flushes soon; `delayMs` is long when the socket must drain first. */
  private scheduleFlush(connected: ConnectedClient, delayMs = 25): void {
    if (connected.flushScheduled || connected.queue.depth === 0) return;
    connected.flushScheduled = true;
    setTimeout(() => {
      connected.flushScheduled = false;
      this.flush(connected);
    }, delayMs);
  }

  /**
   * The runtime tells us when Bun's send buffer has drained (the websocket
   * `drain` handler): the queue is then flushed at once instead of by polling.
   */
  private bindDrain(connected: ConnectedClient): void {
    (connected.socket as { onDrain?: () => void }).onDrain = () =>
      this.flush(connected);
  }

  private flush(connected: ConnectedClient): void {
    if (connected.socket.readyState !== WebSocket.OPEN) return;
    const socket = connected.socket as WebSocket & {
      bufferedAmount?: number;
      backpressured?: boolean;
    };
    const blocked = () =>
      socket.backpressured === true ||
      Number(socket.bufferedAmount ?? 0) >= MAX_SOCKET_BUFFERED_BYTES;
    // Blocked: the drain callback resumes the flush; the slow timer only
    // covers a runtime that does not report drains.
    if (blocked()) {
      this.scheduleFlush(connected, DRAIN_FALLBACK_MS);
      return;
    }
    let item: ReturnType<BoundedRealtimeQueue["take"]>;
    while ((item = connected.queue.take())) {
      this.sendSerialized(connected.socket, item.frame);
      if (blocked()) break;
    }
    if (connected.queue.depth > 0) this.scheduleFlush(connected, DRAIN_FALLBACK_MS);
  }

  private recordQueueResult(result: RealtimeQueueEnqueueResult): void {
    if (result === "dropped") this.metrics.ephemeralDropped += 1;
    if (result === "coalesced") this.metrics.ephemeralCoalesced += 1;
  }

  private recordLatency(event: RealtimeEventEnvelope): void {
    const timestamp = Date.parse(event.timestamp);
    if (!Number.isNaN(timestamp)) {
      this.metrics.eventToUiLatencyMs = Math.max(0, Date.now() - timestamp);
    }
  }

  private sendRaw(socket: WebSocket, message: unknown): void {
    this.sendSerialized(socket, JSON.stringify(message));
  }

  private sendSerialized(socket: WebSocket, serialized: string): void {
    try {
      // Bun's send() answers -1 when it queued the frame under backpressure
      // (the drain handler resumes us) and 0 when it dropped the frame.
      const status = socket.send(serialized) as unknown;
      if (status === 0) socket.close(1011, "Realtime frame dropped");
    } catch {
      // Close handlers remove dead sockets; delivery is best effort.
    }
  }

  private async replayScope(
    connected: ConnectedClient,
    scope: RealtimeScope,
    until?: RealtimeEventEnvelope,
  ): Promise<void> {
    // A connection without a cursor for a stream has nothing to catch up on:
    // the client reads current state over HTTP and then follows live events.
    // Replaying the oldest retained events instead is bounded noise that ends
    // in a replay_limit or gap signal, and a full recovery on the client.
    if (!until) await this.seedMissingCursors(connected, scope);
    const rows = await this.loadReplayRows(
      connected.identity.userId,
      scope,
      connected.lastEnqueuedSequences,
    );
    const blockedStreams = new Set<string>();
    for (const row of rows) {
      let event: RealtimeEventEnvelope;
      try {
        event = realtimeEventFromRow(row);
      } catch {
        continue;
      }
      if (
        !isReplayableRealtimeEvent(event) ||
        !eventMatchesScope(event, scope)
      ) {
        continue;
      }
      const stream = realtimeEventStream(event);
      const streamKey = realtimeStreamKey(stream);
      if (blockedStreams.has(streamKey)) continue;
      const lastSequence = connected.lastEnqueuedSequences.get(streamKey);
      if (lastSequence !== undefined && event.sequence <= lastSequence) {
        continue;
      }
      if (
        lastSequence !== undefined &&
        requiresRealtimeReconnect(lastSequence, event.sequence)
      ) {
        this.metrics.reconnects += 1;
        this.sendReplayGap(connected, scope, event, lastSequence);
        blockedStreams.add(streamKey);
        continue;
      }
      if (
        until &&
        realtimeStreamKey(realtimeEventStream(until)) === streamKey &&
        event.sequence > until.sequence
      ) {
        continue;
      }
      if (
        (this.env as unknown as { REALTIME_DIAGNOSTICS?: string })
          .REALTIME_DIAGNOSTICS === "1"
      ) {
        console.log(
          JSON.stringify({
            diagnostic: "realtime_replay",
            scope,
            eventId: event.eventId,
            sequence: event.sequence,
            type: event.type,
          }),
        );
      }
      const result = this.enqueueEvent(connected, event);
      this.recordQueueResult(result);
      if (result === "resync-required") continue;
      connected.lastEnqueuedSequences.set(streamKey, event.sequence);
    }
    // A full page may omit other streams entirely. Recover the whole scope,
    // without inventing a stream cursor or advancing beyond delivered evidence.
    if (rows.length === MAX_REPLAY_EVENTS) {
      this.metrics.reconnects += 1;
      this.sendRaw(connected.socket, {
        type: "sync.required",
        reason: "replay_limit",
        scope,
      });
    }
    if (until) {
      const stream = realtimeEventStream(until);
      const streamKey = realtimeStreamKey(stream);
      const lastSequence = connected.lastEnqueuedSequences.get(streamKey);
      if (
        lastSequence !== undefined &&
        lastSequence < until.sequence - 1 &&
        !blockedStreams.has(streamKey)
      ) {
        this.sendReplayGap(connected, scope, until, lastSequence);
      }
    }
  }

  /** The streams a Scope covers for this user, as SQL over realtime_events e. */
  private replayAudience(
    q: Query,
    userId: string,
    scope: RealtimeScope,
  ): { join: unknown; where: unknown } | null {
    const none = q.raw("");
    if (scope.kind === "space" && scope.spaceId) {
      return { join: none, where: q.frag`e.stream_kind = 'space' AND e.stream_id = ${scope.spaceId}` };
    }
    if (scope.kind === "user") {
      return {
        join: none,
        where: q.frag`(e.stream_kind = 'user' AND e.stream_id = ${userId}) OR
         (e.stream_kind = 'space' AND EXISTS (
           SELECT 1 FROM space_memberships m
           WHERE m.space_id = e.stream_id AND m.user_id = ${userId}
         ))`,
      };
    }
    if (scope.kind === "run" && scope.runId) {
      return { join: none, where: q.frag`e.run_id = ${scope.runId}` };
    }
    if (scope.kind === "thread" && scope.threadId) {
      return { join: none, where: q.frag`e.thread_id = ${scope.threadId}` };
    }
    return null;
  }

  /**
   * Starts every stream the Scope covers, and the connection has no cursor
   * for, at its newest event.
   */
  private async seedMissingCursors(
    connected: ConnectedClient,
    scope: RealtimeScope,
  ): Promise<void> {
    const q = dataOf(this.env).read;
    const audience = this.replayAudience(q, connected.identity.userId, scope);
    if (!audience) return;
    const result = await q.rows<{ streamKind: string; streamId: string | null; head: number }>`SELECT s.stream_kind AS "streamKind", s.stream_id AS "streamId",
              (SELECT MAX(x.sequence) FROM realtime_events x
                WHERE x.stream_kind = s.stream_kind
                  AND x.stream_id = s.stream_id) AS head
       FROM (
         SELECT DISTINCT e.stream_kind AS stream_kind,
                e.stream_id AS stream_id
         FROM realtime_events e${audience.join}
         WHERE (${audience.where})
       ) s`;
    for (const row of result) {
      if (!row.streamId) continue;
      const key = realtimeStreamKey({
        kind: row.streamKind as RealtimeStream["kind"],
        id: row.streamId,
      });
      if (!connected.lastEnqueuedSequences.has(key)) {
        connected.lastEnqueuedSequences.set(key, Number(row.head));
      }
    }
  }

  private async loadReplayRows(
    userId: string,
    scope: RealtimeScope,
    cursors: ReadonlyMap<string, number>,
  ): Promise<Record<string, unknown>[]> {
    const q = dataOf(this.env).read;
    const audience = this.replayAudience(q, userId, scope);
    if (!audience) return [];
    // One JSON binding avoids a SQL parameter per cursor. Keep the audience
    // predicate grouped so user-scope OR branches cannot bypass cursor filtering.
    const cursorJson = JSON.stringify(Object.fromEntries(cursors));
    return q.rows<Record<string, unknown>>`SELECT e.*
      FROM realtime_events e${audience.join}
       WHERE (${audience.where}) AND NOT EXISTS (
      SELECT 1 FROM jsonb_each_text(${cursorJson}::text::jsonb) cursor(key, value)
      WHERE cursor.key::jsonb = jsonb_build_array(e.stream_kind, e.stream_id)
        AND e.sequence <= cursor.value::bigint
    )
       ORDER BY e.occurred_at ASC, e.sequence ASC, e.event_id ASC
       LIMIT ${q.raw(String(MAX_REPLAY_EVENTS))}`;
  }

  private sendReplayGap(
    connected: ConnectedClient,
    scope: RealtimeScope,
    event: RealtimeEventEnvelope,
    lastSequence: number,
  ): void {
    const streamKey = realtimeStreamKey(realtimeEventStream(event));
    if (
      (this.env as unknown as { REALTIME_DIAGNOSTICS?: string })
        .REALTIME_DIAGNOSTICS === "1"
    ) {
      console.log(
        JSON.stringify({
          diagnostic: "realtime_gap",
          scope,
          streamKey,
          lastSequence,
          nextSequence: event.sequence,
          eventType: event.type,
        }),
      );
    }
    connected.lastEnqueuedSequences.set(
      streamKey,
      Math.max(
        connected.lastEnqueuedSequences.get(streamKey) ?? 0,
        event.sequence,
      ),
    );
    this.sendRaw(connected.socket, {
      type: "sync.required",
      reason: "durable_event_gap",
      scope,
      stream: realtimeEventStream(event),
      lastDurableSequence: lastSequence,
      nextSequence: event.sequence,
    });
  }
}
