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
  type BetterAuthRuntimeEnv,
} from "./auth/index.js";
import {
  BoundedRealtimeQueue,
  type RealtimeQueueEnqueueResult,
} from "./realtime-queue.js";

export interface RealtimeScope {
  kind?: "user" | "space" | "thread" | "run" | "execution_workspace";
  executionWorkspaceId?: string;
  workspaceId?: string;
  spaceId?: string;
  threadId?: string;
  runId?: string;
}

export type RealtimeClientMessage =
  | {
      type: "realtime.hello";
      lastDurableSequences?: Record<string, number>;
      lastDurableStreamSequences?: Record<string, number>;
    }
  | { type: "subscribe"; scope: RealtimeScope }
  | { type: "unsubscribe"; scope: RealtimeScope }
  | { type: "ping" };

export interface RealtimeGatewayEnv extends BetterAuthRuntimeEnv {
  readonly SYNTILA_DB: D1Database;
}

interface ConnectedClient {
  readonly socket: WebSocket;
  readonly identity: AuthenticatedIdentity;
  readonly subscriptions: Map<string, RealtimeScope>;
  /** Durable cursors are per stream; subscription scopes only control rendering/delivery. */
  readonly lastDurableSequences: Map<string, number>;
  readonly queue: BoundedRealtimeQueue;
  flushScheduled: boolean;
  /** Last subscriptions and cursors written to storage; skips equal writes. */
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
  readonly cursors: Array<[string, number]>;
}

export interface RealtimeGatewayMetrics {
  activeAppSockets: number;
  publishedEvents: number;
  ephemeralDropped: number;
  ephemeralCoalesced: number;
  reconnects: number;
  durableResyncs: number;
  maxQueueDepth: number;
  eventToUiLatencyMs: number;
}

const MAX_SOCKET_BUFFERED_BYTES = 256 * 1024;
const MAX_REPLAY_EVENTS = 256;
const CONNECTION_STORAGE_PREFIX = "connection:";
// Answered by the runtime without waking the Durable Object, so an idle
// connection costs no duration. Must match the App's ping frame exactly.
const PING_FRAME = JSON.stringify({ type: "ping" });
const PONG_FRAME = JSON.stringify({ type: "realtime.pong" });

export function scopeKey(scope: RealtimeScope): string {
  if (scope.kind) {
    return `${scope.kind}=${scope.executionWorkspaceId ?? scope.spaceId ?? scope.threadId ?? scope.runId ?? ""}`;
  }
  return ["workspaceId", "spaceId", "runId"]
    .map((field) => `${field}=${scope[field as keyof RealtimeScope] ?? ""}`)
    .join("&");
}

export function parseRealtimeClientMessage(
  input: unknown,
): RealtimeClientMessage {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new Error("Realtime client message must be an object");
  }
  const value = input as Record<string, unknown>;
  if (typeof value.type !== "string") {
    throw new Error("Realtime client message type is required");
  }
  if (value.type === "realtime.hello" || value.type === "ping") {
    if (value.type === "ping") return { type: "ping" };
    const rawSequences = value.lastDurableSequences;
    if (
      rawSequences !== undefined &&
      (rawSequences === null ||
        typeof rawSequences !== "object" ||
        Array.isArray(rawSequences))
    ) {
      throw new Error("lastDurableSequences must be an object");
    }
    const sequences: Record<string, number> = {};
    for (const [workspaceId, sequence] of Object.entries(
      (rawSequences ?? {}) as Record<string, unknown>,
    )) {
      if (
        workspaceId.length === 0 ||
        typeof sequence !== "number" ||
        !Number.isInteger(sequence) ||
        sequence < 0
      ) {
        throw new Error(
          "lastDurableSequences must map Workspace IDs to non-negative integers",
        );
      }
      sequences[workspaceId] = sequence;
    }
    const streams: Record<string, number> = {};
    const rawStreams = value.lastDurableStreamSequences;
    if (
      rawStreams !== undefined &&
      (!rawStreams ||
        typeof rawStreams !== "object" ||
        Array.isArray(rawStreams))
    ) {
      throw new Error("lastDurableStreamSequences must be an object");
    }
    for (const [key, sequence] of Object.entries(
      (rawStreams ?? {}) as Record<string, unknown>,
    )) {
      const parts = JSON.parse(key) as unknown;
      if (!Array.isArray(parts) || parts.length !== 2)
        throw new Error("Invalid stream cursor key");
      const stream = RealtimeStreamSchema.parse({
        kind: parts[0],
        id: parts[1],
      });
      if (
        typeof sequence !== "number" ||
        !Number.isSafeInteger(sequence) ||
        sequence < 0
      )
        throw new Error("Invalid stream sequence");
      streams[realtimeStreamKey(stream)] = sequence;
    }
    return {
      type: "realtime.hello",
      ...(Object.keys(streams).length > 0
        ? { lastDurableStreamSequences: streams }
        : {}),
      ...(Object.keys(sequences).length > 0
        ? { lastDurableSequences: sequences }
        : {}),
    };
  }
  if (value.type !== "subscribe" && value.type !== "unsubscribe") {
    throw new Error(`Unsupported realtime client message: ${value.type}`);
  }
  const rawScope = value.scope;
  if (
    rawScope === null ||
    typeof rawScope !== "object" ||
    Array.isArray(rawScope)
  ) {
    throw new Error("Realtime subscription scope is required");
  }
  const scope = rawScope as Record<string, unknown>;
  if (scope.kind === "user")
    return { type: value.type, scope: { kind: "user" } };
  if (
    scope.kind === "space" ||
    scope.kind === "thread" ||
    scope.kind === "run"
  ) {
    const idField = `${scope.kind}Id`;
    if (
      typeof scope[idField] !== "string" ||
      (scope[idField] as string).length === 0
    ) {
      throw new Error(`Realtime ${scope.kind} scope id is required`);
    }
    return {
      type: value.type,
      scope: { kind: scope.kind, [idField]: scope[idField] },
    } as RealtimeClientMessage;
  }
  if (scope.kind === "execution_workspace") {
    if (
      typeof scope.executionWorkspaceId !== "string" ||
      scope.executionWorkspaceId.length === 0
    ) {
      throw new Error("Realtime execution Workspace scope id is required");
    }
    return {
      type: value.type,
      scope: {
        kind: "execution_workspace",
        executionWorkspaceId: scope.executionWorkspaceId,
      },
    };
  }
  const scopeFields = ["workspaceId", "spaceId", "runId"] as const;
  if (typeof scope.workspaceId !== "string" || scope.workspaceId.length === 0) {
    throw new Error("Realtime subscription workspaceId is required");
  }
  for (const field of scopeFields.slice(1)) {
    if (scope[field] !== undefined && typeof scope[field] !== "string") {
      throw new Error(`Realtime subscription ${field} must be a string`);
    }
  }
  return {
    type: value.type,
    scope: {
      workspaceId: scope.workspaceId,
      ...(typeof scope.spaceId === "string" ? { spaceId: scope.spaceId } : {}),
      ...(typeof scope.runId === "string" ? { runId: scope.runId } : {}),
    },
  };
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
  if (scope.kind === "execution_workspace") {
    return event.workspaceId === scope.executionWorkspaceId;
  }
  return (
    !!event.workspaceId &&
    event.workspaceId === scope.workspaceId &&
    (!scope.spaceId || event.spaceId === scope.spaceId) &&
    (!scope.runId || event.runId === scope.runId)
  );
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
  db: Pick<D1Database, "prepare">,
  userId: string,
  scope: RealtimeScope,
): Promise<{ allowed: true } | { allowed: false; reason: string }> {
  if (scope.kind === "user") return { allowed: true };
  if (scope.kind === "space") {
    const member = await db
      .prepare(
        "SELECT 1 AS member FROM space_memberships WHERE space_id = ?1 AND user_id = ?2",
      )
      .bind(scope.spaceId, userId)
      .first<{ member: number }>();
    return member
      ? { allowed: true }
      : { allowed: false, reason: "space_access_denied" };
  }
  if (scope.kind === "thread") {
    const member = await db
      .prepare(
        `SELECT 1 AS member FROM threads w
       JOIN space_memberships pm ON pm.space_id = w.space_id
       WHERE w.id = ?1 AND pm.user_id = ?2`,
      )
      .bind(scope.threadId, userId)
      .first<{ member: number }>();
    return member
      ? { allowed: true }
      : { allowed: false, reason: "thread_access_denied" };
  }
  if (scope.kind === "execution_workspace") {
    const owner = await db
      .prepare(
        "SELECT 1 AS owner FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2 AND status <> 'revoked'",
      )
      .bind(scope.executionWorkspaceId, userId)
      .first<{ owner: number }>();
    return owner
      ? { allowed: true }
      : { allowed: false, reason: "execution_workspace_access_denied" };
  }
  if (scope.kind === "run") {
    const row = await db
      .prepare(
        `SELECT pm.user_id FROM space_memberships pm
       JOIN runs resource ON resource.space_id = pm.space_id
       WHERE resource.id = ?1 AND pm.user_id = ?2`,
      )
      .bind(scope.runId, userId)
      .first<{ user_id: string }>();
    return row
      ? { allowed: true }
      : { allowed: false, reason: `${scope.kind}_access_denied` };
  }
  const owner = await db
    .prepare(
      "SELECT 1 AS owner FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2 AND status <> 'revoked'",
    )
    .bind(scope.workspaceId, userId)
    .first<{ owner: number }>();
  if (!owner)
    return { allowed: false, reason: "execution_workspace_access_denied" };

  if (scope.spaceId) {
    const space = await db
      .prepare(
        `SELECT 1 AS granted FROM workspace_space_grants
                  WHERE space_id = ?1 AND workspace_id = ?2 AND status = 'active'`,
      )
      .bind(scope.spaceId, scope.workspaceId)
      .first<{ granted: number }>();
    if (!space) {
      return { allowed: false, reason: "space_access_denied" };
    }
  }
  if (scope.runId) {
    const run = await db
      .prepare(
        `SELECT 1 AS granted FROM runs r
                  JOIN workspace_space_grants g ON g.space_id = r.space_id
                  WHERE r.id = ?1 AND g.workspace_id = ?2 AND g.status = 'active'`,
      )
      .bind(scope.runId, scope.workspaceId)
      .first<{ granted: number }>();
    if (!run) {
      return { allowed: false, reason: "run_access_denied" };
    }
  }
  return { allowed: true };
}

export async function isRealtimeIdentityAuthorized(
  db: Pick<D1Database, "prepare">,
  userId: string,
  scopes: readonly RealtimeScope[],
): Promise<boolean> {
  const user = await db
    .prepare("SELECT status FROM users WHERE id = ?1")
    .bind(userId)
    .first<{ status: string }>();
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
    cursors: [...connected.lastDurableSequences],
  } satisfies PersistedConnection);
}

export class RealtimeGateway implements DurableObject {
  private readonly clients = new Map<string, ConnectedClient>();
  private restored: Promise<void> | null = null;
  private readonly metrics: RealtimeGatewayMetrics = {
    activeAppSockets: 0,
    publishedEvents: 0,
    ephemeralDropped: 0,
    ephemeralCoalesced: 0,
    reconnects: 0,
    durableResyncs: 0,
    maxQueueDepth: 0,
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
    const user = await this.env.SYNTILA_DB.prepare(
      "SELECT status FROM users WHERE id = ?1",
    )
      .bind(identity.userId)
      .first<{ status?: string | null }>();
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
      lastDurableSequences: new Map(),
      queue: new BoundedRealtimeQueue(),
      flushScheduled: false,
    };
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
        lastDurableSequences: new Map(persisted?.cursors ?? []),
        queue: new BoundedRealtimeQueue(),
        flushScheduled: false,
      };
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
      const input = JSON.parse(
        typeof data === "string"
          ? data
          : new TextDecoder().decode(data as ArrayBuffer),
      );
      const message = parseRealtimeClientMessage(input);
      if (message.type === "ping") {
        this.sendRaw(connected.socket, { type: "realtime.pong" });
        return;
      }
      if (message.type === "realtime.hello") {
        connected.lastDurableSequences.clear();
        for (const [key, value] of Object.entries(
          message.lastDurableSequences ?? {},
        )) {
          connected.lastDurableSequences.set(
            realtimeStreamKey({ kind: "execution_workspace", id: key }),
            value,
          );
        }
        for (const [key, value] of Object.entries(
          message.lastDurableStreamSequences ?? {},
        )) {
          connected.lastDurableSequences.set(key, value);
        }
        this.sendRaw(connected.socket, {
          type: "realtime.ready",
          connectionId,
          eventVersion: "1.1",
        });
        return;
      }
      const result = await authorizeRealtimeScope(
        this.env.SYNTILA_DB,
        connected.identity.userId,
        message.scope,
      );
      if (!result.allowed) {
        this.sendRaw(connected.socket, {
          type: "subscription.denied",
          scope: message.scope,
          reason: result.reason,
        });
        return;
      }
      const key = scopeKey(message.scope);
      if (message.type === "subscribe") {
        connected.subscriptions.set(key, message.scope);
        this.sendRaw(connected.socket, {
          type: "subscription.confirmed",
          scope: message.scope,
        });
        await this.replayScope(connected, message.scope);
      } else {
        connected.subscriptions.delete(key);
        this.sendRaw(connected.socket, {
          type: "subscription.confirmed",
          scope: message.scope,
          subscribed: false,
        });
      }
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
      if (!member.allowed) {
        const owner =
          event.type === "workspace_space_grant.updated"
            ? await this.env.SYNTILA_DB.prepare(
                "SELECT 1 AS owner FROM workspace_space_grants WHERE id = ?1 AND space_id = ?2 AND granted_by_user_id = ?3",
              )
                .bind(
                  event.payload.entityId,
                  stream.id,
                  connected.identity.userId,
                )
                .first()
            : null;
        if (!owner) return;
      }
    }
    const matchingScopes = [...connected.subscriptions.values()].filter(
      (scope) => eventMatchesScope(event, scope),
    );
    if (matchingScopes.length === 0) return;
    const replayable = isReplayableRealtimeEvent(event);
    const lastSequence = connected.lastDurableSequences.get(streamKey);
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
        connected.lastDurableSequences.get(streamKey) ===
        event.sequence - 1
      ) {
        const result = this.enqueueEvent(connected, event);
        this.recordQueueResult(result);
        if (result !== "resync-required") {
          connected.lastDurableSequences.set(streamKey, event.sequence);
        }
      }
      return;
    }
    const result = this.enqueueEvent(connected, event);
    this.recordQueueResult(result);
    if (replayable) {
      connected.lastDurableSequences.set(
        streamKey,
        Math.max(
          connected.lastDurableSequences.get(streamKey) ?? 0,
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
    const frame = JSON.stringify({ type: "event", event });
    if (
      connected.queue.depth === 0 &&
      (connected.socket as WebSocket & { bufferedAmount?: number })
        .bufferedAmount !== undefined &&
      Number(
        (connected.socket as WebSocket & { bufferedAmount?: number })
          .bufferedAmount,
      ) < MAX_SOCKET_BUFFERED_BYTES
    ) {
      this.sendRaw(connected.socket, { type: "event", event });
      this.recordLatency(event);
      return "queued";
    }
    const result = connected.queue.enqueue({ frame, durable, coalesceKey });
    this.metrics.maxQueueDepth = Math.max(
      this.metrics.maxQueueDepth,
      connected.queue.depth,
    );
    if (result === "resync-required") {
      this.metrics.durableResyncs += 1;
      connected.queue.clear();
      this.sendRaw(connected.socket, {
        type: "reconnect.required",
        reason: "connection_queue_limit",
        ...(realtimeEventStream(event).kind === "space"
          ? {
              scope: {
                kind: "space",
                spaceId: realtimeEventStream(event).id,
              },
            }
          : {}),
        ...(event.workspaceId ? { workspaceId: event.workspaceId } : {}),
        stream: realtimeEventStream(event),
        nextSequence: event.sequence,
      });
      return result;
    }
    this.scheduleFlush(connected);
    return result;
  }

  private scheduleFlush(connected: ConnectedClient): void {
    if (connected.flushScheduled || connected.queue.depth === 0) return;
    connected.flushScheduled = true;
    setTimeout(() => {
      connected.flushScheduled = false;
      this.flush(connected);
    }, 25);
  }

  private flush(connected: ConnectedClient): void {
    if (connected.socket.readyState !== WebSocket.OPEN) return;
    const socket = connected.socket as WebSocket & { bufferedAmount?: number };
    if (Number(socket.bufferedAmount ?? 0) >= MAX_SOCKET_BUFFERED_BYTES) {
      this.scheduleFlush(connected);
      return;
    }
    let item: ReturnType<BoundedRealtimeQueue["take"]>;
    while ((item = connected.queue.take())) {
      this.sendSerialized(connected.socket, item.frame);
      if (Number(socket.bufferedAmount ?? 0) >= MAX_SOCKET_BUFFERED_BYTES) {
        break;
      }
    }
    if (connected.queue.depth > 0) this.scheduleFlush(connected);
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
      socket.send(serialized);
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
      connected.lastDurableSequences,
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
      const lastSequence = connected.lastDurableSequences.get(streamKey);
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
      connected.lastDurableSequences.set(streamKey, event.sequence);
    }
    // A full page may omit other streams entirely. Recover the whole scope,
    // without inventing a stream cursor or advancing beyond delivered evidence.
    if (rows.length === MAX_REPLAY_EVENTS) {
      this.metrics.reconnects += 1;
      this.sendRaw(connected.socket, {
        type: "reconnect.required",
        reason: "replay_limit",
        scope,
      });
    }
    if (until) {
      const stream = realtimeEventStream(until);
      const streamKey = realtimeStreamKey(stream);
      const lastSequence = connected.lastDurableSequences.get(streamKey);
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
    userId: string,
    scope: RealtimeScope,
  ): { join: string; where: string; bindings: string[] } | null {
    if (scope.kind === "execution_workspace" && scope.executionWorkspaceId) {
      return {
        join: "",
        where:
          "e.stream_kind = 'execution_workspace' AND COALESCE(e.stream_id, e.workspace_id) = ?",
        bindings: [scope.executionWorkspaceId],
      };
    }
    if (scope.kind === "space" && scope.spaceId) {
      return {
        join: "",
        where: "e.stream_kind = 'space' AND e.stream_id = ?",
        bindings: [scope.spaceId],
      };
    }
    if (scope.kind === "user") {
      return {
        join: " LEFT JOIN execution_workspaces w ON w.id = e.workspace_id",
        where: `(e.stream_kind = 'user' AND e.stream_id = ?) OR
         (e.stream_kind = 'execution_workspace' AND w.owner_user_id = ?) OR
         (e.stream_kind = 'space' AND EXISTS (
           SELECT 1 FROM space_memberships m
           WHERE m.space_id = e.stream_id AND m.user_id = ?
         ))`,
        bindings: [userId, userId, userId],
      };
    }
    if (scope.kind === "run" && scope.runId) {
      return { join: "", where: "e.run_id = ?", bindings: [scope.runId] };
    }
    if (scope.kind === "thread" && scope.threadId) {
      return {
        join: "",
        where: "e.thread_id = ?",
        bindings: [scope.threadId],
      };
    }
    if (scope.workspaceId) {
      return {
        join: "",
        where:
          "e.stream_kind = 'execution_workspace' AND COALESCE(e.stream_id, e.workspace_id) = ?",
        bindings: [scope.workspaceId],
      };
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
    const audience = this.replayAudience(connected.identity.userId, scope);
    if (!audience) return;
    const result = await this.env.SYNTILA_DB.prepare(
      `SELECT s.stream_kind AS streamKind, s.stream_id AS streamId,
              (SELECT MAX(x.sequence) FROM realtime_events x
                WHERE x.stream_kind = s.stream_kind
                  AND COALESCE(x.stream_id, x.workspace_id) = s.stream_id) AS head
       FROM (
         SELECT DISTINCT e.stream_kind AS stream_kind,
                COALESCE(e.stream_id, e.workspace_id) AS stream_id
         FROM realtime_events e${audience.join}
         WHERE (${audience.where})
       ) s`,
    )
      .bind(...audience.bindings)
      .all<{ streamKind: string; streamId: string | null; head: number }>();
    for (const row of result.results ?? []) {
      if (!row.streamId) continue;
      const key = realtimeStreamKey({
        kind: row.streamKind as RealtimeStream["kind"],
        id: row.streamId,
      });
      if (!connected.lastDurableSequences.has(key)) {
        connected.lastDurableSequences.set(key, Number(row.head));
      }
    }
  }

  private async loadReplayRows(
    userId: string,
    scope: RealtimeScope,
    cursors: ReadonlyMap<string, number>,
  ): Promise<Record<string, unknown>[]> {
    const audience = this.replayAudience(userId, scope);
    if (!audience) return [];
    const query = `
      SELECT e.*
      FROM realtime_events e${audience.join}`;
    const bindings = [...audience.bindings];
    // One JSON binding avoids a SQL parameter per cursor. Keep the audience
    // predicate grouped so user-scope OR branches cannot bypass cursor filtering.
    const conditions = [
      `(${audience.where})`,
      `NOT EXISTS (
      SELECT 1 FROM jsonb_each_text(?::jsonb) cursor(key, value)
      WHERE cursor.key::jsonb = jsonb_build_array(e.stream_kind, COALESCE(e.stream_id, e.workspace_id))
        AND e.sequence <= cursor.value::bigint
    )`,
    ];
    bindings.push(JSON.stringify(Object.fromEntries(cursors)));
    const result = await this.env.SYNTILA_DB.prepare(
      `${query}
       WHERE ${conditions.join(" AND ")}
       ORDER BY e.occurred_at ASC, e.sequence ASC, e.event_id ASC
       LIMIT ${MAX_REPLAY_EVENTS}`,
    )
      .bind(...bindings)
      .all<Record<string, unknown>>();
    return result.results ?? [];
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
    connected.lastDurableSequences.set(
      streamKey,
      Math.max(
        connected.lastDurableSequences.get(streamKey) ?? 0,
        event.sequence,
      ),
    );
    this.sendRaw(connected.socket, {
      type: "reconnect.required",
      reason: "durable_event_gap",
      scope,
      ...(event.workspaceId ? { workspaceId: event.workspaceId } : {}),
      stream: realtimeEventStream(event),
      lastDurableSequence: lastSequence,
      nextSequence: event.sequence,
    });
  }
}
