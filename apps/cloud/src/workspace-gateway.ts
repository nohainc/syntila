import {
  applyEngineLivenessReport,
  failLostEngineAssignments,
  parseEngineLivenessReport,
} from "./assignment-liveness.js";
import {
  claimMcpToolDispatch,
  loadMcpToolCall,
  recordMcpToolOutcome,
  type McpToolCallRecord,
  type McpToolState,
} from "./mcp-tool-dispatch-claim.js";
import { signalAssignmentTerminal } from "./assignment-workflow-signal.js";
import {
  parseWorkspaceRuntimeMessage,
  serializeWorkspaceRuntimeMessage,
  McpToolCallRequestSchema,
  McpToolCallResultSchema,
  McpInventorySchema,
  type McpInventory,
  McpToolCallStatusRequestSchema,
  McpToolCallStatusResultSchema,
  SERVICE_MCP_TOOL_CALL_STATUS_CAPABILITY,
  SERVICE_MCP_ACTION_CAPABILITY,
  McpActionRequestSchema,
  McpActionResultSchema,
  type McpActionResult,
  WORKSPACE_RUNTIME_PROTOCOL_NAME,
  WORKSPACE_RUNTIME_PROTOCOL_VERSION,
  ALLOWED_FOLDERS_CAPABILITY,
  WORKER_PLUGINS_CAPABILITY,
  ASSIGNMENT_STARTUP_CAPABILITY,
  SERVICE_MCP_TOOL_CALL_CAPABILITY,
  SERVICE_READINESS_CAPABILITY,
  assignmentStartupPayload,
  serviceReadinessPayload,
  type AssignmentCancelPayload,
  type WorkspaceRuntimeMessage,
} from "@syntila/workspace-runtime-protocol";
import {
  applyServiceReadiness,
  authenticatedReadiness,
  disconnectedReadiness,
  effectiveReadiness,
  inferLegacyReadiness,
  inventoryReceivedReadiness,
  syncAnsweredReadiness,
  synchronizingReadiness,
  type ServiceReadiness,
  type ServiceReadinessReport,
} from "./service-readiness.js";
import {
  RealtimeEventPayloadSchema,
  normalizeActivityPayload,
} from "@syntila/protocol";
import { recordAssignmentStartup } from "./assignment-startup.js";
import { publishAssignmentPhase } from "./assignment-phase-events.js";
import { createEventPublisher } from "./event-publisher.js";
import {
  ASSIGNMENT_REVOCATION_CONFIRMATION_MS,
  DEFAULT_WORKSPACE_PARALLEL_SLOTS,
  assignmentCommandDisposition,
  recordCloudQueueReason,
  recordCloudQueueNotReady,
} from "./assignment-delivery.js";
import { grantStartPermit } from "./assignment-start-permit.js";
import {
  escalateUnconfirmedRevocations,
  finalizeAssignmentRevocation,
  finalizeRevocationsOfRevokedRuntimes,
} from "./assignment-revocation.js";
import {
  ACTIVE_ASSIGNMENT_STATUS_SQL,
  transitionAssignment,
  type AssignmentTransitionResult,
} from "./assignment-transitions.js";
import {
  ASSIGNMENT_ACTIVE_STATUSES,
  assignmentStatusForEvidence,
} from "@syntila/core";
import { shouldPersistWorkerActivity } from "./worker-activity-history.js";
import {
  recordAssignmentCancelled,
  recordAssignmentError,
  recordAssignmentResult,
} from "./assignment-dispatcher.js";
import { extractBearerToken } from "../../../packages/security/src/index.js";
import {
  tryLogDiagnosticEvent,
  tryLogTraceEvent,
  logStructured,
  requestIdFor,
} from "./observability.js";
import { recordWorkspaceWorkerInventory } from "./workspace-gateway/inventory.js";
import { WorkspaceRuntimeAuthenticator } from "./workspace-gateway/runtime-authenticator.js";
import { WorkspaceRuntimeSessionStore } from "./workspace-gateway/session-store.js";

import {
  isCurrentWorkspaceSocket,
  runtimeFacts,
  START_PERMIT_CAPABILITY,
  workspaceAssignmentContextMatches,
  workspaceAssignmentIsActive,
  type WorkspaceAssignmentCorrelation,
  type WorkspaceGatewayEnv,
} from "./workspace-gateway/contracts.js";

/**
 * Bound the fallback transport's pending server-to-Workspace messages. The
 * queue is persisted, so a dropped poll response can still be replayed, but
 * accepting unbounded commands would turn a disconnected runtime into a D1 /
 * Durable Object memory sink. Reaching this limit applies backpressure to
 * the caller; it never silently drops a command or acknowledgement.
 */
export const MAX_WORKSPACE_HTTP_EVENTS = 256;
export {
  isCurrentWorkspaceSocket,
  isWorkspaceRuntimeAuthorized,
  normalizeWorkspaceWorkerInstallationStatus,
  workspaceAssignmentContextMatches,
  workspaceAssignmentIsActive,
  type WorkspaceAssignmentCorrelation,
  type WorkspaceGatewayEnv,
} from "./workspace-gateway/contracts.js";

/** Marks an `assignment.start` payload as requiring a start permit. */
/**
 * Stamps the Workspace's current slot total into the assignment snapshot at
 * delivery time. Cloud has already admitted the assignment against that
 * total, so the Service uses it as its local limit and never queues by count.
 */
function withSlotLimit(payload: unknown, slots: number): unknown {
  if (!payload || typeof payload !== "object") return payload;
  const value = payload as { snapshot?: unknown };
  if (!value.snapshot || typeof value.snapshot !== "object") return payload;
  return {
    ...value,
    snapshot: { ...value.snapshot, maxConcurrentAssignments: slots },
  };
}

function withStartPermitRequirement(payload: unknown): unknown {
  if (!payload || typeof payload !== "object") return payload;
  const value = payload as { snapshot?: unknown };
  if (!value.snapshot || typeof value.snapshot !== "object") return payload;
  return {
    ...value,
    snapshot: { ...value.snapshot, startPermit: { required: true } },
  };
}

/** Work Request ID carried in an assignment payload, for trace correlation. */
function workRequestIdOf(payload: unknown): string | undefined {
  if (!payload || typeof payload !== "object") return undefined;
  const snapshot = (payload as { snapshot?: unknown }).snapshot;
  const value =
    snapshot && typeof snapshot === "object"
      ? (snapshot as { workRequestId?: unknown }).workRequestId
      : undefined;
  return typeof value === "string" && /^[A-Za-z0-9._:-]{1,128}$/.test(value)
    ? value
    : undefined;
}

const MCP_INVENTORY_KEY = "mcp-inventory";

/** What the gateway keeps per Workspace: the last sanitized inventory. */
interface StoredMcpInventory {
  inventory: McpInventory;
  receivedAt: string;
  workspaceRuntimeId: string | null;
}

export class WorkspaceGateway implements DurableObject {
  private readonly runtimeAuthenticator: WorkspaceRuntimeAuthenticator;
  private readonly sessionStore: WorkspaceRuntimeSessionStore;
  private readonly pendingProbes = new Map<
    string,
    {
      resolve: (payload: Record<string, unknown>) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  private readonly pendingUsageRequests = new Map<
    string,
    {
      resolve: (payload: Record<string, unknown>) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  private readonly pendingMcpToolCalls = new Map<
    string,
    {
      resolve: (payload: Record<string, unknown>) => void;
      // Only the runtime the call was sent to may answer it.
      workspaceRuntimeId: string | null;
    }
  >();
  // Read-only status lookups, keyed by task. One in flight per task.
  private readonly pendingMcpToolCallStatus = new Map<
    string,
    {
      resolve: (payload: Record<string, unknown>) => void;
      workspaceRuntimeId: string | null;
    }
  >();
  private readonly pendingMcpActions = new Map<
    string,
    {
      resolve: (payload: McpActionResult) => void;
      workspaceRuntimeId: string | null;
    }
  >();
  private static readonly MCP_ACTION_TIMEOUT_MS = 30_000;
  // Margin on top of the call's own timeout for Engine start-up and transport.
  private static readonly MCP_TOOL_CALL_MARGIN_MS = 60_000;
  private static readonly MCP_STATUS_TIMEOUT_MS = 15_000;
  // The Service may run a provider CLI, so allow longer than a delivery probe.
  private static readonly USAGE_TIMEOUT_MS = 70_000;
  private static readonly MAX_PENDING_USAGE_REQUESTS = 4;
  private static readonly PROBE_TIMEOUT_MS = 5_000;
  private static readonly MAX_PENDING_PROBES = 4;
  private readonly pendingCancelAcks = new Map<
    string,
    {
      resolve: (payload: Record<string, unknown>) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  /**
   * Wall-clock time each assignment.start was handed to the transport, used
   * only to report command round-trip time. Bounded and best-effort: a
   * hibernated Durable Object simply loses the entry.
   */
  private readonly commandQueuedAt = new Map<string, number>();
  private static readonly MAX_TRACKED_COMMANDS = 256;
  private socket: WebSocket | null = null;
  private socketConnectedAt: string | null = null;
  private executionWorkspaceId: string | null = null;
  private workspaceRuntimeId: string | null = null;
  private sessionId: string | null = null;
  private correlationId: string | null = null;
  private projectionWriteChain: Promise<void> = Promise.resolve();
  private httpEvents: Array<{
    cursor: number;
    envelope: Record<string, unknown>;
  }> = [];
  private httpCursor = 0;
  private httpWaiter: (() => void) | null = null;
  private httpEventIds = new Set<string>();
  private httpPersistChain: Promise<void> = Promise.resolve();
  private httpLastActivityAt: string | null = null;
  /** Service-level readiness of the current session; restored from storage. */
  private readiness: ServiceReadiness | null = null;
  private readinessLoaded = false;
  private readinessChain: Promise<unknown> = Promise.resolve();
  /** Whether the connected Service publishes `workspace.readiness`. */
  private readinessCapable: boolean | null = null;
  /** Assignments being delivered right now; stops a flush double-sending. */
  private readonly deliveringAssignments = new Set<string>();
  private flushingQueue = false;
  /** A slot freed while a flush was running; the flush runs one more pass. */
  private flushRequested = false;
  /**
   * Serializes "is a slot free?" with the `created -> dispatched` claim, so
   * two deliveries racing inside this Workspace's Gateway cannot both take
   * the last slot. Cloud is the only place that counts slots.
   */
  private slotChain: Promise<unknown> = Promise.resolve();
  private static readonly READINESS_STORAGE_KEY = "service-readiness";

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: WorkspaceGatewayEnv,
  ) {
    this.runtimeAuthenticator = new WorkspaceRuntimeAuthenticator(
      env.SYNTILA_DB,
    );
    this.sessionStore = new WorkspaceRuntimeSessionStore(env.SYNTILA_DB);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    this.restoreAcceptedSocket();
    await this.restoreHttpRuntime();
    if (request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      return this.connectSocket(request, url);
    }
    if (request.method === "GET" && url.pathname === "/status") {
      const lastActivityAt = await this.lastRuntimeActivityAt();
      const live = this.isActivityRecent(lastActivityAt);
      await this.loadReadiness();
      const readiness = effectiveReadiness(this.readiness, live);
      return Response.json({
        online: live,
        // Connection liveness says the socket is alive; readiness says the
        // Service will handle an assignment immediately. Scheduling uses this.
        readyForAssignments: readiness.ready,
        serviceState: readiness.state,
        syncGeneration: this.readiness?.syncGeneration ?? 0,
        readinessSource: this.readiness?.source ?? null,
        readinessUpdatedAt: this.readiness?.updatedAt ?? null,
        activeTransport: live
          ? this.socket
            ? "websocket"
            : "http_long_poll"
          : null,
        executionWorkspaceId: this.executionWorkspaceId,
        workspaceRuntimeId: this.workspaceRuntimeId,
        sessionId: this.sessionId,
        lastActivityAt,
      });
    }
    if (request.method === "POST" && url.pathname === "/disconnect-runtime") {
      return this.disconnectRuntime(request);
    }
    if (request.method === "POST" && url.pathname === "/diagnostic-probe") {
      return this.diagnosticProbe();
    }
    if (request.method === "POST" && url.pathname === "/worker-usage") {
      return this.requestWorkerUsage(request);
    }
    if (request.method === "GET" && url.pathname === "/mcp-inventory") {
      return Response.json(
        (await this.state.storage.get<StoredMcpInventory>(MCP_INVENTORY_KEY)) ??
          null,
      );
    }
    if (request.method === "POST" && url.pathname === "/mcp-tool-call-status") {
      return this.requestMcpToolCallStatus(request);
    }
    if (request.method === "POST" && url.pathname === "/mcp-tool-call") {
      return this.requestMcpToolCall(request);
    }
    if (request.method === "POST" && url.pathname === "/mcp-action") {
      return this.requestMcpAction(request);
    }
    if (request.method === "POST" && url.pathname === "/inputs-available") {
      return this.announceInputsAvailable();
    }
    if (request.method === "POST" && url.pathname === "/dispatch-assignment") {
      return this.dispatchAssignment(request);
    }
    if (request.method === "POST" && url.pathname === "/cancel-assignment") {
      return this.cancelAssignment(request);
    }
    if (request.method === "POST" && url.pathname === "/flush-queued") {
      await this.loadReadiness();
      const flushed = await this.flushQueuedAssignments();
      return Response.json({
        flushed,
        readyForAssignments: this.readiness?.readyForAssignments === true,
      });
    }
    if (request.method === "POST" && url.pathname.startsWith("/runtime/")) {
      return this.handleHttpRuntimeRequest(request, url.pathname);
    }
    return Response.json({ error: "Not found" }, { status: 404 });
  }

  private async handleHttpRuntimeRequest(
    request: Request,
    path: string,
  ): Promise<Response> {
    this.correlationId = requestIdFor(request);
    const body = (await request.json().catch(() => null)) as Record<
      string,
      unknown
    > | null;
    if (!body || typeof body !== "object")
      return Response.json({ error: "Invalid request body" }, { status: 400 });
    const token = extractBearerToken(request.headers);
    const runtimeId =
      path === "/runtime/sessions"
        ? body.workspaceRuntimeId
        : this.workspaceRuntimeId;
    const sessionId =
      typeof body.sessionId === "string" ? body.sessionId : null;
    if (!token || typeof runtimeId !== "string")
      return Response.json(
        { error: "Runtime credential required" },
        { status: 401 },
      );
    const identity = await this.runtimeAuthenticator.authenticateRuntime(
      runtimeId,
      token,
    );
    if (!identity || identity.executionWorkspaceId !== this.state.id.name) {
      return Response.json(
        { error: "Invalid or revoked Workspace runtime credential" },
        { status: 401 },
      );
    }
    if (
      path !== "/runtime/sessions" &&
      (!sessionId ||
        sessionId !== this.sessionId ||
        runtimeId !== this.workspaceRuntimeId)
    ) {
      return Response.json(
        { error: "Runtime session not found" },
        { status: 404 },
      );
    }
    if (path === "/runtime/sessions") {
      if (body.contractVersion !== "1.0")
        return Response.json(
          { error: "Unsupported contract version" },
          { status: 400 },
        );
      if (this.socket) {
        try {
          this.socket.close(1000, "Superseded by HTTP long-poll");
        } catch {
          // A disconnected socket can already be closed by the peer.
        }
      }
      this.socket = null;
      this.socketConnectedAt = null;
      this.executionWorkspaceId = identity.executionWorkspaceId;
      this.workspaceRuntimeId = runtimeId;
      this.sessionId = `session-${crypto.randomUUID()}`;
      this.httpEvents = [];
      this.httpCursor = 0;
      this.httpLastActivityAt = new Date().toISOString();
      const now = new Date().toISOString();
      await this.sessionStore.closeForRuntime(runtimeId, now);
      await this.sessionStore.open({
        sessionId: this.sessionId,
        workspaceId: this.executionWorkspaceId,
        runtimeIdentityId: runtimeId,
        clientVersion: "unknown",
        protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        connectedAt: now,
      });
      await this.env.SYNTILA_DB.prepare(
        "UPDATE execution_workspaces SET status = 'online', updated_at = ?1 WHERE id = ?2",
      )
        .bind(now, this.executionWorkspaceId)
        .run();
      await this.persistHttpRuntime();
      await this.startReadinessSession(this.sessionId, runtimeId);
      return Response.json({
        sessionId: this.sessionId,
        serverTime: now,
        pollTimeoutMs: 25000,
        heartbeatIntervalMs: 15000,
        cursor: "0",
      });
    }
    if (path === "/runtime/events") {
      if (
        !Array.isArray(body.events) ||
        body.events.length < 1 ||
        body.events.length > 100
      )
        return Response.json(
          { error: "events must contain 1 to 100 items" },
          { status: 400 },
        );
      const acceptedEventIds: string[] = [];
      const rejected: Array<{ eventId: string; code: string }> = [];
      for (const raw of body.events) {
        if (!raw || typeof raw !== "object") continue;
        const envelope = raw as Record<string, unknown>;
        if (
          envelope.contract !== "syntila.desktop-auth-transport" ||
          envelope.version !== "1.0" ||
          typeof envelope.eventId !== "string" ||
          !envelope.message
        ) {
          if (typeof envelope.eventId === "string")
            rejected.push({
              eventId: envelope.eventId,
              code: "invalid_event_envelope",
            });
          continue;
        }
        if (this.httpEventIds.has(envelope.eventId)) {
          acceptedEventIds.push(envelope.eventId);
          continue;
        }
        try {
          const message = parseWorkspaceRuntimeMessage(envelope.message);
          await this.handleMessage(JSON.stringify(message), sessionId!);
          this.httpEventIds.add(envelope.eventId);
          acceptedEventIds.push(envelope.eventId);
        } catch {
          rejected.push({
            eventId: envelope.eventId,
            code: "invalid_or_unprocessed_message",
          });
        }
      }
      this.httpLastActivityAt = new Date().toISOString();
      await this.persistHttpRuntime();
      return Response.json({
        acceptedEventIds,
        rejected,
        cursor: String(this.httpCursor),
      });
    }
    if (path === "/runtime/poll") {
      const cursor = Number(body.cursor);
      if (
        !Number.isSafeInteger(cursor) ||
        cursor < 0 ||
        cursor > this.httpCursor ||
        !Number.isInteger(body.waitMs) ||
        (body.waitMs as number) < 0 ||
        (body.waitMs as number) > 60000
      )
        return Response.json(
          { error: "Invalid cursor or waitMs" },
          { status: 400 },
        );
      // The request cursor acknowledges events from the previous successful
      // response. Keep newly returned events queued until that acknowledgement
      // arrives so a dropped poll response can be retried without data loss.
      this.httpEvents = this.httpEvents.filter(
        (entry) => entry.cursor > cursor,
      );
      let events = this.httpEvents
        .filter((entry) => entry.cursor > cursor)
        .slice(0, 100);
      if (!events.length && body.waitMs) {
        // A newer poll supersedes an older one (for example after a client
        // retry or transport hiccup). The older waiter is released and returns
        // an empty, timed-out page; it must never block command delivery.
        const previousWaiter = this.httpWaiter;
        this.httpWaiter = null;
        previousWaiter?.();
        await new Promise<void>((resolve) => {
          const timer = setTimeout(() => {
            if (this.httpWaiter === wake) this.httpWaiter = null;
            resolve();
          }, body.waitMs as number);
          const wake = () => {
            clearTimeout(timer);
            resolve();
          };
          this.httpWaiter = wake;
        });
        events = this.httpEvents
          .filter((entry) => entry.cursor > cursor)
          .slice(0, 100);
      }
      const nextCursor = events.length
        ? events[events.length - 1]!.cursor
        : cursor;
      this.httpLastActivityAt = new Date().toISOString();
      await this.persistHttpRuntime();
      return Response.json({
        cursor: String(nextCursor),
        events: events.map((entry) => entry.envelope),
        serverTime: new Date().toISOString(),
        timedOut: events.length === 0,
      });
    }
    if (
      path === `/runtime/sessions/${encodeURIComponent(sessionId!)}/close` ||
      path === "/runtime/close"
    ) {
      const now = new Date().toISOString();
      this.queueProjectionWrite(
        () => this.sessionStore.close(sessionId!, now),
        "session_disconnect_update_failed",
        {
          workspaceId: this.executionWorkspaceId ?? undefined,
          runtimeId,
          requestId: this.correlationId ?? undefined,
        },
      );
      if (this.executionWorkspaceId)
        this.queueProjectionWrite(
          () =>
            this.env.SYNTILA_DB.prepare(
              "UPDATE execution_workspaces SET status = 'offline', updated_at = ?1 WHERE id = ?2",
            )
              .bind(now, this.executionWorkspaceId)
              .run(),
          "workspace_offline_projection_failed",
          { workspaceId: this.executionWorkspaceId, runtimeId },
        );
      await this.mutateReadiness((current) =>
        current && current.sessionId === sessionId
          ? disconnectedReadiness(current, now)
          : current,
      );
      this.sessionId = null;
      this.httpLastActivityAt = null;
      await this.state.storage.delete("http-runtime");
      return Response.json({ closed: true, closedAt: now });
    }
    return Response.json({ error: "Not found" }, { status: 404 });
  }

  private async restoreHttpRuntime(): Promise<void> {
    if (this.sessionId || this.socket) return;
    const active = await this.state.storage.get<{
      sessionId: string;
      executionWorkspaceId: string;
      workspaceRuntimeId: string;
      cursor: number;
      events: Array<{ cursor: number; envelope: Record<string, unknown> }>;
      eventIds: string[];
      lastActivityAt?: string;
    }>("http-runtime");
    if (!active) return;
    this.sessionId = active.sessionId;
    this.executionWorkspaceId = active.executionWorkspaceId;
    this.workspaceRuntimeId = active.workspaceRuntimeId;
    this.httpCursor = active.cursor;
    this.httpEvents = active.events;
    this.httpEventIds = new Set(active.eventIds ?? []);
    this.httpLastActivityAt = active.lastActivityAt ?? null;
  }

  private isActivityRecent(lastActivityAt: string | null): boolean {
    const activity = lastActivityAt ? Date.parse(lastActivityAt) : Number.NaN;
    return Number.isFinite(activity) && Date.now() - activity <= 60000;
  }

  private async lastRuntimeActivityAt(): Promise<string | null> {
    if (this.socket && this.sessionId) {
      return (
        (await this.sessionStore.lastHeartbeat(this.sessionId)) ??
        this.socketConnectedAt
      );
    }
    return this.sessionId ? this.httpLastActivityAt : null;
  }

  private async isRuntimeLive(): Promise<boolean> {
    return (
      (this.socket !== null || this.sessionId !== null) &&
      this.isActivityRecent(await this.lastRuntimeActivityAt())
    );
  }

  private persistHttpRuntime(): Promise<void> {
    if (
      !this.sessionId ||
      !this.executionWorkspaceId ||
      !this.workspaceRuntimeId
    )
      return Promise.resolve();
    const snapshot = {
      sessionId: this.sessionId,
      executionWorkspaceId: this.executionWorkspaceId,
      workspaceRuntimeId: this.workspaceRuntimeId,
      cursor: this.httpCursor,
      events: this.httpEvents,
      eventIds: [...this.httpEventIds],
      lastActivityAt: this.httpLastActivityAt,
    };
    this.httpPersistChain = this.httpPersistChain.then(() =>
      this.state.storage.put("http-runtime", snapshot),
    );
    return this.httpPersistChain;
  }

  private restoreAcceptedSocket(): void {
    if (this.socket) return;
    for (const socket of this.state.getWebSockets?.() ?? []) {
      const attachment = socket.deserializeAttachment() as {
        sessionId?: string;
        executionWorkspaceId?: string;
        workspaceRuntimeId?: string;
        correlationId?: string;
        connectedAt?: string;
      } | null;
      if (
        !attachment?.sessionId ||
        !attachment.executionWorkspaceId ||
        !attachment.workspaceRuntimeId ||
        socket.readyState !== WebSocket.OPEN
      ) {
        continue;
      }
      this.socket = socket;
      this.sessionId = attachment.sessionId;
      this.executionWorkspaceId = attachment.executionWorkspaceId;
      this.workspaceRuntimeId = attachment.workspaceRuntimeId;
      this.correlationId = attachment.correlationId ?? null;
      this.socketConnectedAt = attachment.connectedAt ?? null;
      return;
    }
  }

  private async disconnectRuntime(request: Request): Promise<Response> {
    const body = (await request.json()) as Record<string, unknown>;
    const runtimeId =
      typeof body.runtimeId === "string" ? body.runtimeId : null;
    if (!runtimeId) {
      return Response.json({ error: "runtimeId is required" }, { status: 400 });
    }
    if (
      this.workspaceRuntimeId !== runtimeId ||
      (!this.socket && !this.sessionId)
    ) {
      return Response.json({ disconnected: false });
    }
    if (this.socket) {
      try {
        this.socket.close(1000, "Workspace runtime disconnected");
      } catch {
        // The runtime credential is already revoked; a failed close cannot
        // restore authorization or permit future reconnects.
      }
    } else if (this.sessionId) {
      const now = new Date().toISOString();
      await this.sessionStore.close(this.sessionId, now);
      if (this.executionWorkspaceId) {
        await this.env.SYNTILA_DB.prepare(
          "UPDATE execution_workspaces SET status = 'offline', updated_at = ?1 WHERE id = ?2",
        )
          .bind(now, this.executionWorkspaceId)
          .run();
      }
      this.sessionId = null;
      this.httpLastActivityAt = null;
      await this.state.storage.delete("http-runtime");
      this.httpWaiter?.();
      this.httpWaiter = null;
    }
    return Response.json({ disconnected: true });
  }

  private async connectSocket(request: Request, url: URL): Promise<Response> {
    const correlationId = requestIdFor(request);
    const workspaceRuntimeId = url.searchParams.get("workspaceRuntimeId");
    const token = extractBearerToken(request.headers);
    let runtimeLookupFailed = false;
    let runtimeIdentity: Awaited<
      ReturnType<WorkspaceRuntimeAuthenticator["authenticateRuntime"]>
    > = null;
    if (workspaceRuntimeId) {
      try {
        runtimeIdentity = token
          ? await this.runtimeAuthenticator.authenticateRuntime(
              workspaceRuntimeId,
              token,
            )
          : null;
      } catch {
        runtimeLookupFailed = true;
        runtimeIdentity = null;
      }
    }
    const expectedWorkspaceId = this.state.id.name;
    const runtimeIdMatches = Boolean(
      runtimeIdentity &&
      (!expectedWorkspaceId ||
        runtimeIdentity.executionWorkspaceId === expectedWorkspaceId),
    );
    logStructured(
      "info",
      "GW-05 durable_object_request_received",
      { requestId: correlationId, runtimeId: workspaceRuntimeId ?? undefined },
      {
        upgradeHeaderPresent:
          request.headers.get("Upgrade")?.toLowerCase() === "websocket",
        runtimeIdMatches,
        runtimeLookupFailed,
      },
    );

    if (
      !workspaceRuntimeId ||
      !token ||
      !runtimeIdentity ||
      !runtimeIdMatches
    ) {
      logStructured(
        "warn",
        "GW-06 durable_object_runtime_authentication_failed",
        {
          requestId: correlationId,
          runtimeId: workspaceRuntimeId ?? undefined,
        },
        {
          reason: runtimeLookupFailed
            ? "runtime_identity_lookup_failed"
            : "runtime_identity_mismatch_or_missing_credential",
        },
      );
      return Response.json(
        { error: "workspaceRuntimeId and runtime credential are required" },
        { status: 401 },
      );
    }

    const now = new Date().toISOString();
    logStructured("info", "GW-06 durable_object_runtime_authenticated", {
      requestId: correlationId,
      runtimeId: workspaceRuntimeId,
      workspaceId: runtimeIdentity.executionWorkspaceId,
    });

    if (this.socket) {
      try {
        this.socket.close(1000, "Superseded by new connection");
      } catch {
        // The stale socket is fenced by session id below.
      }
    }
    if (this.sessionId) {
      await this.sessionStore.close(this.sessionId, now);
    }
    await this.state.storage.delete("http-runtime");
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const sessionId = `session-${crypto.randomUUID()}`;
    server.serializeAttachment({
      sessionId,
      executionWorkspaceId: runtimeIdentity.executionWorkspaceId,
      workspaceRuntimeId,
      correlationId,
      connectedAt: now,
    });
    logStructured("info", "GW-07 websocket_accepting", {
      requestId: correlationId,
      runtimeId: workspaceRuntimeId,
      workspaceId: runtimeIdentity.executionWorkspaceId,
    });
    this.state.acceptWebSocket(server);
    logStructured("info", "GW-08 websocket_accepted", {
      requestId: correlationId,
      runtimeId: workspaceRuntimeId,
      workspaceId: runtimeIdentity.executionWorkspaceId,
    });
    this.socket = server;
    this.socketConnectedAt = now;
    this.executionWorkspaceId = runtimeIdentity.executionWorkspaceId;
    this.workspaceRuntimeId = workspaceRuntimeId;
    this.sessionId = sessionId;
    this.correlationId = correlationId;
    void this.startReadinessSession(sessionId, workspaceRuntimeId).catch(
      (error: unknown) =>
        logStructured(
          "error",
          "workspace_readiness_session_failed",
          { workspaceId: runtimeIdentity.executionWorkspaceId },
          { error: error instanceof Error ? error.message : String(error) },
        ),
    );

    this.queueProjectionWrite(
      () =>
        this.env.SYNTILA_DB.prepare(
          "UPDATE execution_workspaces SET status = 'online', updated_at = ?1 WHERE id = ?2",
        )
          .bind(now, runtimeIdentity.executionWorkspaceId)
          .run(),
      "workspace_online_projection_failed",
      {
        requestId: correlationId,
        runtimeId: workspaceRuntimeId,
        workspaceId: runtimeIdentity.executionWorkspaceId,
      },
    );
    this.queueProjectionWrite(
      () =>
        this.sessionStore.open({
          sessionId,
          workspaceId: runtimeIdentity.executionWorkspaceId,
          runtimeIdentityId: workspaceRuntimeId,
          clientVersion: "0.1.0",
          protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
          ipAddress: request.headers.get("CF-Connecting-IP") ?? "127.0.0.1",
          connectedAt: now,
        }),
      "session_insert_failed",
      { requestId: correlationId, runtimeId: workspaceRuntimeId },
    );

    logStructured("info", "GW-09 returning_http_101", {
      requestId: correlationId,
      runtimeId: workspaceRuntimeId,
      workspaceId: runtimeIdentity.executionWorkspaceId,
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(socket: WebSocket, data: string | ArrayBuffer): void {
    const attachment = socket.deserializeAttachment() as {
      sessionId: string;
      executionWorkspaceId: string;
      workspaceRuntimeId: string;
      correlationId?: string;
    } | null;
    if (!attachment) return;
    this.socket = socket;
    this.sessionId = attachment.sessionId;
    this.executionWorkspaceId = attachment.executionWorkspaceId;
    this.workspaceRuntimeId = attachment.workspaceRuntimeId;
    this.correlationId = attachment.correlationId ?? this.correlationId;
    void this.handleMessage(data, attachment.sessionId);
  }

  webSocketClose(socket: WebSocket): void {
    this.handleSocketEnd(socket);
  }

  webSocketError(socket: WebSocket): void {
    this.handleSocketEnd(socket);
  }

  /**
   * After hibernation the in-memory socket identity is gone and the closing
   * socket is no longer OPEN, so restoreAcceptedSocket() cannot find it. Adopt
   * its attachment first so close() recognises it as the current socket and
   * marks the workspace offline / readiness disconnected.
   */
  private handleSocketEnd(socket: WebSocket): void {
    const attachment = socket.deserializeAttachment() as {
      sessionId?: string;
      executionWorkspaceId?: string;
      workspaceRuntimeId?: string;
      correlationId?: string;
      connectedAt?: string;
    } | null;
    if (!attachment?.sessionId) return;
    this.restoreAcceptedSocket();
    if (
      !this.socket &&
      this.sessionId === null &&
      attachment.executionWorkspaceId &&
      attachment.workspaceRuntimeId
    ) {
      this.socket = socket;
      this.sessionId = attachment.sessionId;
      this.executionWorkspaceId = attachment.executionWorkspaceId;
      this.workspaceRuntimeId = attachment.workspaceRuntimeId;
      this.correlationId = attachment.correlationId ?? null;
      this.socketConnectedAt = attachment.connectedAt ?? null;
    }
    void this.close(socket, attachment.sessionId);
  }

  private async close(socket: WebSocket, sessionId: string): Promise<void> {
    if (
      !isCurrentWorkspaceSocket(this.socket, this.sessionId, socket, sessionId)
    ) {
      return;
    }
    this.socket = null;
    this.socketConnectedAt = null;
    const now = new Date().toISOString();
    await this.mutateReadiness((current) =>
      current && current.sessionId === sessionId
        ? disconnectedReadiness(current, now)
        : current,
    ).catch(() => undefined);
    if (this.executionWorkspaceId) {
      this.queueProjectionWrite(
        () =>
          this.env.SYNTILA_DB.prepare(
            "UPDATE execution_workspaces SET status = 'offline', updated_at = ?1 WHERE id = ?2",
          )
            .bind(now, this.executionWorkspaceId)
            .run(),
        "workspace_offline_projection_failed",
        {
          requestId: this.correlationId ?? undefined,
          runtimeId: this.workspaceRuntimeId ?? undefined,
          workspaceId: this.executionWorkspaceId,
        },
      );
    }
    this.queueProjectionWrite(
      () => this.sessionStore.close(sessionId, now),
      "session_disconnect_update_failed",
      {
        requestId: this.correlationId ?? undefined,
        runtimeId: this.workspaceRuntimeId ?? undefined,
        workspaceId: this.executionWorkspaceId ?? undefined,
      },
    );
    // This event carries no Worker configuration. AX rereads the owner-scoped
    // inventory endpoint after each complete snapshot.
    if (this.executionWorkspaceId) {
      await createEventPublisher(this.env).publish({
        type: "worker.inventory.updated",
        workspaceId: this.executionWorkspaceId,
        payload: { status: "updated" },
        durable: false,
      });
    }
  }

  private queueProjectionWrite(
    write: () => Promise<unknown>,
    failure: string,
    correlation: {
      requestId?: string;
      runtimeId?: string;
      workspaceId?: string;
    },
  ): void {
    this.projectionWriteChain = this.projectionWriteChain
      .then(() => write())
      .then(() => undefined)
      .catch(() => {
        // Database errors can contain bound values. Emit only a safe category
        // and correlation metadata, never the raw error or credentials.
        logStructured(
          "error",
          "GW-PROJECTION write_failed",
          {
            ...correlation,
          },
          { failure },
        );
      });
  }

  private async handleMessage(data: unknown, sessionId: string): Promise<void> {
    let message: WorkspaceRuntimeMessage;
    try {
      const raw = typeof data === "string" ? JSON.parse(data) : data;
      message = parseWorkspaceRuntimeMessage(raw);
    } catch (error) {
      this.sendError(
        error instanceof Error
          ? error.message
          : "Invalid Workspace protocol message",
      );
      return;
    }
    if (
      message.workspaceRuntimeId &&
      message.workspaceRuntimeId !== this.workspaceRuntimeId
    ) {
      this.socket?.close(1008, "Workspace runtime identity mismatch");
      return;
    }
    if (
      message.executionWorkspaceId &&
      message.executionWorkspaceId !== this.executionWorkspaceId
    ) {
      this.socket?.close(1008, "Execution Workspace mismatch");
      return;
    }
    const now = new Date().toISOString();
    switch (message.type) {
      case "workspace.hello":
        {
          const correlation = {
            requestId: this.correlationId ?? undefined,
            runtimeId: this.workspaceRuntimeId ?? undefined,
            workspaceId: this.executionWorkspaceId ?? undefined,
          };
          logStructured("info", "GW-10 workspace_hello_received", correlation, {
            protocolMessageId: message.messageId,
          });
          const facts = runtimeFacts(message.payload);
          // Safety capabilities belong to this authenticated session, not to
          // the last installation that happened to publish Workspace facts.
          await this.state.storage.put("execution-capabilities", {
            sessionId,
            // The authenticated runtime identity is authoritative. The hello
            // envelope's own `workspaceRuntimeId` is optional (the long-poll
            // transport omits it) and was previously stored as null, which
            // made every assignment look like the Service lacked the
            // start-permit capability.
            runtimeId: this.workspaceRuntimeId ?? message.workspaceRuntimeId,
            capabilities: facts.capabilities,
          });
          await this.env.SYNTILA_DB.prepare(
            `INSERT INTO workspace_runtime_facts
             (workspace_id, platform, architecture, hostname, app_version,
              runtime_capabilities_json, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(workspace_id) DO UPDATE SET
               platform = excluded.platform,
               architecture = excluded.architecture,
               hostname = excluded.hostname,
               app_version = excluded.app_version,
               runtime_capabilities_json = excluded.runtime_capabilities_json,
               updated_at = excluded.updated_at`,
          )
            .bind(
              this.executionWorkspaceId,
              facts.platform,
              facts.architecture,
              facts.hostname,
              facts.appVersion,
              JSON.stringify(facts.capabilities),
              now,
            )
            .run();
        }
        await this.send({
          protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
          protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
          messageId: `message-${crypto.randomUUID()}`,
          correlationId: message.messageId,
          timestamp: now,
          type: "workspace.hello.ack",
          executionWorkspaceId: this.executionWorkspaceId ?? undefined,
          workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
          payload: {
            sessionId,
            heartbeatIntervalMs: 15000,
            serverTime: now,
            // Lets a Service know it may publish `workspace.readiness` and
            // `assignment.startup`.
            cloudCapabilities: [
              SERVICE_READINESS_CAPABILITY,
              ASSIGNMENT_STARTUP_CAPABILITY,
              ALLOWED_FOLDERS_CAPABILITY,
              WORKER_PLUGINS_CAPABILITY,
            ],
          },
        });
        logStructured(
          "info",
          "GW-11 workspace_hello_ack_sent",
          {
            requestId: this.correlationId ?? undefined,
            runtimeId: this.workspaceRuntimeId ?? undefined,
            workspaceId: this.executionWorkspaceId ?? undefined,
          },
          { protocolCorrelationId: message.messageId },
        );
        return;
      case "workspace.heartbeat":
        if (message.payload && typeof message.payload === "object") {
          // The heartbeat repeats the Service's readiness so a lost or
          // reordered `workspace.readiness`, or a Durable Object that lost its
          // state, heals within one heartbeat interval.
          const heartbeatReadiness = serviceReadinessPayload.safeParse(
            (message.payload as Record<string, unknown>).readiness,
          );
          if (heartbeatReadiness.success) {
            await this.applyReadinessReport(
              heartbeatReadiness.data,
              sessionId,
              now,
            );
          }
          await this.applyEngineLiveness(message.payload, now);
          this.queueProjectionWrite(
            () => this.sessionStore.touch(sessionId, now),
            "session_heartbeat_update_failed",
            {
              requestId: this.correlationId ?? undefined,
              runtimeId: this.workspaceRuntimeId ?? undefined,
              workspaceId: this.executionWorkspaceId ?? undefined,
            },
          );
        }
        await this.send({
          protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
          protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
          messageId: `message-${crypto.randomUUID()}`,
          correlationId: message.messageId,
          timestamp: now,
          type: "workspace.heartbeat.ack",
          executionWorkspaceId: this.executionWorkspaceId ?? undefined,
          workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
          payload: { acknowledged: true, serverTime: now },
        });
        return;
      case "workspace.sync.request":
        await this.mutateReadiness((current) =>
          current ? synchronizingReadiness(current, now) : null,
        );
        // Mark the sync answered BEFORE the result is sent: the Service may
        // publish readiness the instant it receives the result, and that
        // report must find the sync already recorded.
        await this.mutateReadiness(
          (current) => (current ? syncAnsweredReadiness(current, now) : null),
          { publish: false },
        );
        await this.syncWorkspace(message.messageId);
        // The Service now has its authoritative state; tell it which
        // assignments Cloud has revoked so a replayed or restarted Service
        // cannot launch them.
        await this.resendPendingRevocations().catch(() => undefined);
        logStructured(
          "info",
          "GW-12 workspace_sync_completed",
          {
            requestId: this.correlationId ?? undefined,
            runtimeId: this.workspaceRuntimeId ?? undefined,
            workspaceId: this.executionWorkspaceId ?? undefined,
          },
          { protocolCorrelationId: message.messageId },
        );
        await this.inferReadinessIfLegacy();
        return;
      case "workspace.readiness": {
        const report = serviceReadinessPayload.safeParse(message.payload);
        if (!report.success) return;
        await this.applyReadinessReport(report.data, sessionId, now);
        return;
      }
      case "worker.inventory":
        await this.recordWorkerInventory(message.payload);
        await this.mutateReadiness(
          (current) =>
            current ? inventoryReceivedReadiness(current, now) : null,
          { publish: false },
        );
        await this.inferReadinessIfLegacy();
        return;
      case "assignment.ack": {
        const payload = message.payload as Record<string, unknown>;
        // Terminal acknowledgements are emitted by Cloud for Workspace
        // delivery confirmation. They must never be interpreted as a fresh
        // admission acknowledgement or move a terminal row back to running.
        if (payload.terminal === true) return;
        if (!(await this.assignmentContextMatches(message))) return;
        const accepted = payload.accepted ?? payload.status === "accepted";
        tryLogDiagnosticEvent({
          assignmentId: message.assignmentId,
          workspaceId: message.executionWorkspaceId,
          workspaceRuntimeId: message.workspaceRuntimeId,
          workerId: message.workerId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          component: "cloud",
          operation: "assignment",
          stage: "admission",
          severity: accepted ? "info" : "warning",
          errorCode: accepted ? undefined : "worker_not_ready",
          retryable: !accepted,
          context: {
            status: accepted ? "accepted" : "rejected",
          },
        });
        this.traceCommandAcknowledged(message, payload, accepted === true);
        if (accepted === true) {
          // Admission evidence only moves created/dispatched forward. If the
          // provider-start acknowledgement or a terminal outcome got here
          // first, this late acknowledgement is recorded and ignored; it
          // must never refresh updated_at or downgrade the assignment.
          const transition = await transitionAssignment(this.env.SYNTILA_DB, {
            to: assignmentStatusForEvidence("admission"),
            now,
            fence: {
              assignmentId: message.assignmentId!,
              attemptId: message.attemptId,
              executionWorkspaceId: this.executionWorkspaceId ?? undefined,
              runtimeIdentityId: this.workspaceRuntimeId ?? undefined,
            },
          });
          this.traceTransitionOutcome(message, "admission", transition);
          if (transition.applied && message.assignmentId)
            await publishAssignmentPhase(this.env, message.assignmentId);
        } else if (
          message.assignmentId &&
          (await this.terminalAssignmentMatches(message))
        ) {
          await recordAssignmentError(
            this.env.SYNTILA_DB,
            message.assignmentId,
            {
              error: {
                code: "worker_not_ready",
                message:
                  "The Workspace Worker was not ready to accept the assignment.",
                retryable: true,
              },
              failedAt: now,
            },
            message.attemptId,
            // A rejection is only meaningful before admission. A stale or
            // replayed one must not fail an accepted or running assignment.
            { onlyFrom: ["created", "dispatched"] },
          );
        }
        return;
      }
      case "diagnostic.probe.ack": {
        const payload = message.payload as Record<string, unknown>;
        const probeId =
          typeof payload.probeId === "string" ? payload.probeId : "";
        const pending = this.pendingProbes.get(probeId);
        if (!pending) return;
        clearTimeout(pending.timer);
        this.pendingProbes.delete(probeId);
        pending.resolve(payload);
        return;
      }
      case "diagnostic.probe":
        // Cloud originates probes; a Service never sends one.
        return;
      case "worker.usage.result": {
        const payload = message.payload as Record<string, unknown>;
        const requestId =
          typeof payload.requestId === "string" ? payload.requestId : "";
        const pending = this.pendingUsageRequests.get(requestId);
        if (!pending) return;
        clearTimeout(pending.timer);
        this.pendingUsageRequests.delete(requestId);
        pending.resolve(payload);
        return;
      }
      case "mcp.tool_call.result": {
        // Malformed or oversized results never get here: the protocol layer
        // rejects them, the call stays unresolved and ends as unknown on
        // timeout (never a success, never a replay).
        const parsed = McpToolCallResultSchema.safeParse(message.payload);
        if (!parsed.success) return;
        const pending = this.pendingMcpToolCalls.get(parsed.data.taskId);
        if (!pending) return;
        // The Service envelope carries no runtime id, so correlate on the
        // authenticated attachment: a result is accepted only while the same
        // runtime the call was dispatched to is attached.
        if (
          !pending.workspaceRuntimeId ||
          this.workspaceRuntimeId !== pending.workspaceRuntimeId
        )
          return;
        this.pendingMcpToolCalls.delete(parsed.data.taskId);
        pending.resolve(parsed.data);
        return;
      }
      case "mcp.inventory": {
        const parsed = McpInventorySchema.safeParse(message.payload);
        if (!parsed.success) return;
        // Sanitized information only, never authority. A snapshot older than
        // the stored one is ignored; an equal revision (a new session
        // republishing) just refreshes the receipt time.
        const stored =
          await this.state.storage.get<StoredMcpInventory>(MCP_INVENTORY_KEY);
        if (stored && parsed.data.revision < stored.inventory.revision) return;
        await this.state.storage.put(MCP_INVENTORY_KEY, {
          inventory: parsed.data,
          receivedAt: now,
          workspaceRuntimeId: this.workspaceRuntimeId,
        } satisfies StoredMcpInventory);
        return;
      }
      case "mcp.tool_call.status.result": {
        const parsed = McpToolCallStatusResultSchema.safeParse(message.payload);
        if (!parsed.success) return;
        const pending = this.pendingMcpToolCallStatus.get(parsed.data.taskId);
        if (!pending) return;
        // Same rule as results: only the runtime the question went to answers.
        if (
          !pending.workspaceRuntimeId ||
          this.workspaceRuntimeId !== pending.workspaceRuntimeId
        )
          return;
        this.pendingMcpToolCallStatus.delete(parsed.data.taskId);
        pending.resolve(parsed.data);
        return;
      }
      case "mcp.action.result": {
        const parsed = McpActionResultSchema.safeParse(message.payload);
        if (!parsed.success) return;
        const pending = this.pendingMcpActions.get(parsed.data.actionId);
        if (!pending) return;
        if (
          !pending.workspaceRuntimeId ||
          this.workspaceRuntimeId !== pending.workspaceRuntimeId
        )
          return;
        this.pendingMcpActions.delete(parsed.data.actionId);
        pending.resolve(parsed.data);
        return;
      }
      case "mcp.action.request":
        // Cloud originates actions; a Service never sends one.
        return;
      case "mcp.tool_call.status.request":
        // Cloud originates status requests; a Service never sends one.
        return;
      case "mcp.tool_call.request":
        // Cloud originates tool calls; a Service never sends one.
        return;
      case "worker.usage.request":
        // Cloud originates usage requests; a Service never sends one.
        return;
      case "input.available":
        // Cloud originates input wake-ups; a Service never sends one.
        return;
      case "assignment.start.ack": {
        // Provider-start evidence implies admission, so it is honoured from
        // created, dispatched or acknowledged. That keeps the evidence when
        // it overtakes the acceptance acknowledgement (HTTP fallback, replay).
        if (!(await this.assignmentContextMatches(message))) return;
        const transition = await transitionAssignment(this.env.SYNTILA_DB, {
          to: assignmentStatusForEvidence("provider_start"),
          now,
          startTaskId: message.taskId,
          fence: {
            assignmentId: message.assignmentId!,
            attemptId: message.attemptId,
            executionWorkspaceId: this.executionWorkspaceId ?? undefined,
            runtimeIdentityId: this.workspaceRuntimeId ?? undefined,
          },
        });
        this.traceTransitionOutcome(message, "provider_start", transition);
        if (!transition.applied) return;
        if (message.assignmentId)
          await publishAssignmentPhase(this.env, message.assignmentId);
        tryLogDiagnosticEvent({
          assignmentId: message.assignmentId,
          workspaceId: message.executionWorkspaceId,
          workspaceRuntimeId: message.workspaceRuntimeId,
          workerId: message.workerId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          component: "cloud",
          operation: "assignment",
          stage: "provider_execution",
          severity: "info",
          retryable: false,
          context: { status: "running" },
        });
        return;
      }
      case "assignment.start.permit.request": {
        // Fencing: the Service asks to launch the provider. Granted only while
        // Cloud has not revoked the assignment (see assignment-start-permit).
        if (!(await this.assignmentContextMatches(message))) return;
        const decision = await grantStartPermit(this.env.SYNTILA_DB, {
          assignmentId: message.assignmentId!,
          attemptId: message.attemptId!,
          executionWorkspaceId: this.executionWorkspaceId ?? undefined,
          runtimeIdentityId: this.workspaceRuntimeId ?? undefined,
        });
        tryLogDiagnosticEvent({
          assignmentId: message.assignmentId,
          workspaceId: message.executionWorkspaceId,
          workspaceRuntimeId: message.workspaceRuntimeId,
          workerId: message.workerId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          component: "cloud",
          operation: "assignment",
          stage: "start_permit",
          severity: decision.granted ? "info" : "warning",
          retryable: false,
          context: {
            status: decision.granted ? "granted" : `denied_${decision.reason}`,
          },
        });
        await this.send({
          protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
          protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
          messageId: `message-${crypto.randomUUID()}`,
          correlationId: message.messageId,
          timestamp: new Date().toISOString(),
          type: "assignment.start.permit.grant",
          executionWorkspaceId: message.executionWorkspaceId,
          workspaceRuntimeId: message.workspaceRuntimeId,
          workerId: message.workerId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          assignmentId: message.assignmentId,
          idempotencyKey: message.idempotencyKey,
          payload: decision.granted
            ? {
                granted: true,
                permitId: decision.permitId,
                expiresAt: decision.expiresAt,
              }
            : { granted: false, reason: decision.reason },
        });
        if (decision.granted && message.assignmentId)
          await publishAssignmentPhase(this.env, message.assignmentId);
        return;
      }
      case "assignment.start.permit.grant":
        // Cloud originates grants; a Service never sends one.
        return;
      case "assignment.startup": {
        // Observability only: the furthest local startup stage, never a
        // status or deadline change.
        if (!(await this.assignmentContextMatches(message))) return;
        const report = assignmentStartupPayload.safeParse(message.payload);
        if (!report.success) return;
        const outcome = await recordAssignmentStartup(this.env.SYNTILA_DB, {
          assignmentId: message.assignmentId!,
          attemptId: message.attemptId!,
          payload: report.data,
          now,
        });
        if (!outcome.applied) return;
        await publishAssignmentPhase(this.env, message.assignmentId!);
        tryLogDiagnosticEvent({
          assignmentId: message.assignmentId,
          workspaceId: message.executionWorkspaceId,
          workspaceRuntimeId: message.workspaceRuntimeId,
          workerId: message.workerId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          component: "cloud",
          operation: "assignment",
          stage: "startup_progress",
          severity: "info",
          retryable: false,
          context: { status: report.data.stage },
        });
        return;
      }
      case "assignment.activity": {
        const payload = message.payload as Record<string, unknown>;
        const workspaceId =
          this.executionWorkspaceId ?? message.executionWorkspaceId;
        if (!workspaceId) {
          tryLogDiagnosticEvent({
            assignmentId: message.assignmentId,
            workspaceRuntimeId: message.workspaceRuntimeId,
            workerId: message.workerId,
            runId: message.runId,
            taskId: message.taskId,
            attemptId: message.attemptId,
            component: "cloud",
            operation: "assignment.activity",
            stage: "correlation",
            severity: "warning",
            errorCode: "activity_workspace_missing",
            retryable: true,
          });
          return;
        }
        const assignment = await this.env.SYNTILA_DB.prepare(
          `SELECT id, execution_workspace_id, runtime_identity_id,
                  worker_type_id, workspace_worker_id, run_id, task_id,
                  -- Work Request assignments are not stamped with a thread.
                  -- Without one the realtime event carries no threadId and the
                  -- AX app drops every live activity as "another Thread".
                  COALESCE(
                    worker_assignments.thread_id,
                    (SELECT wr.thread_id
                       FROM workflow_tasks wt
                       JOIN work_requests wr ON wr.id = wt.work_request_id
                      WHERE wt.id = worker_assignments.task_id),
                    (SELECT wr.thread_id
                       FROM conversation_turns ct
                       JOIN work_requests wr ON wr.id = ct.work_request_id
                      WHERE ct.assignment_id = worker_assignments.id
                      LIMIT 1)
                  ) AS thread_id,
                  work_request_id, attempt_id, idempotency_key, status,
                  (
                    -- Assignments are inserted without worker_assignments
                    -- .work_request_id; the owning Work Request is derived from
                    -- the task or the conversation turn. The column is only a
                    -- cross-check when it is set (a NULL never equals anything,
                    -- which rejected every live activity event).
                    EXISTS (
                      SELECT 1 FROM workflow_tasks wt
                       WHERE wt.id = worker_assignments.task_id
                         AND wt.work_request_id IS NOT NULL
                         AND (worker_assignments.work_request_id IS NULL
                              OR wt.work_request_id = worker_assignments.work_request_id)
                    ) OR EXISTS (
                      SELECT 1 FROM conversation_turns ct
                       WHERE ct.assignment_id = worker_assignments.id
                         AND ct.work_request_id IS NOT NULL
                         AND (worker_assignments.work_request_id IS NULL
                              OR ct.work_request_id = worker_assignments.work_request_id)
                    )
                  ) AS work_request_binding_valid
           FROM worker_assignments
           WHERE id = ?1`,
        )
          .bind(message.assignmentId)
          .first<Record<string, unknown>>();
        const correlation: WorkspaceAssignmentCorrelation = {
          executionWorkspaceId: message.executionWorkspaceId!,
          workspaceRuntimeId: message.workspaceRuntimeId!,
          workerId: message.workerId!,
          runId: message.runId!,
          taskId: message.taskId!,
          attemptId: message.attemptId!,
          assignmentId: message.assignmentId!,
          idempotencyKey: message.idempotencyKey!,
        };
        if (
          !assignment ||
          !workspaceAssignmentContextMatches(correlation, assignment) ||
          !workspaceAssignmentIsActive(assignment) ||
          Number(assignment.work_request_binding_valid) !== 1 ||
          payload.assignmentId !== message.assignmentId ||
          payload.workerId !== String(assignment.worker_type_id)
        ) {
          tryLogDiagnosticEvent({
            assignmentId: message.assignmentId,
            workspaceId,
            workspaceRuntimeId:
              this.workspaceRuntimeId ?? message.workspaceRuntimeId,
            workerId: message.workerId,
            runId: message.runId,
            taskId: message.taskId,
            attemptId: message.attemptId,
            component: "cloud",
            operation: "assignment.activity",
            stage: "validation",
            severity: "warning",
            errorCode:
              Number(assignment?.work_request_binding_valid) === 1
                ? "activity_correlation_mismatch"
                : "activity_assignment_not_in_work_request",
            retryable: false,
          });
          return;
        }
        const normalized = normalizeActivityPayload({
          title: payload.title,
          status: payload.status,
          activityId: payload.activityId,
          percentage: payload.percentage,
          durationMs: payload.durationMs,
          toolId: payload.toolId,
          toolName: payload.toolName,
          details: payload.details,
        });
        const activityPayload = RealtimeEventPayloadSchema.safeParse({
          entityId: message.assignmentId,
          workerId: payload.workerId,
          sourceEventId: payload.eventId,
          executionId: payload.executionId,
          activityId: payload.activityId,
          activitySequence: payload.sequence,
          activityType: payload.eventType,
          activityStatus: normalized?.status,
          title: normalized?.title,
          percentage: normalized?.percentage,
          durationMs: normalized?.durationMs,
          toolId: normalized?.toolId,
          toolName: normalized?.toolName,
          details: normalized?.details,
        });
        if (!normalized || !activityPayload.success) {
          tryLogDiagnosticEvent({
            assignmentId: message.assignmentId,
            workspaceId,
            workspaceRuntimeId:
              this.workspaceRuntimeId ?? message.workspaceRuntimeId,
            workerId: message.workerId,
            runId: message.runId,
            taskId: message.taskId,
            attemptId: message.attemptId,
            component: "cloud",
            operation: "assignment.activity",
            stage: "validation",
            severity: "warning",
            errorCode: "activity_payload_invalid",
            retryable: false,
          });
          return;
        }
        const replayable = shouldPersistWorkerActivity(activityPayload.data);
        if (replayable) {
          const conflict = await this.env.SYNTILA_DB.prepare(
            `SELECT source_event_id, provider_sequence
             FROM worker_activity_history
             WHERE assignment_id = ?1 AND attempt_id = ?2
               AND (source_event_id = ?3 OR provider_sequence = ?4)
             LIMIT 1`,
          )
            .bind(
              message.assignmentId,
              message.attemptId,
              activityPayload.data.sourceEventId,
              activityPayload.data.activitySequence,
            )
            .first<{ source_event_id: string; provider_sequence: number }>();
          if (
            conflict &&
            conflict.source_event_id !== activityPayload.data.sourceEventId
          ) {
            tryLogDiagnosticEvent({
              assignmentId: message.assignmentId,
              workspaceId,
              workspaceRuntimeId:
                this.workspaceRuntimeId ?? message.workspaceRuntimeId,
              workerId: message.workerId,
              runId: message.runId,
              taskId: message.taskId,
              attemptId: message.attemptId,
              component: "cloud",
              operation: "assignment.activity",
              stage: "validation",
              severity: "warning",
              errorCode: "activity_sequence_conflict",
              retryable: false,
            });
            return;
          }
        }
        const eventId = `assignment-activity:${message.assignmentId}:${message.attemptId}:${activityPayload.data.sourceEventId}`;
        const historyMutation = replayable
          ? this.env.SYNTILA_DB.prepare(
              `INSERT OR IGNORE INTO worker_activity_history
               (history_id, assignment_id, workspace_id, attempt_id,
                execution_id, worker_id, source_event_id, provider_sequence,
               event_type, status, activity_id, title, details_json,
                duration_ms, tool_id, tool_name, occurred_at)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                       ?13, ?14, ?15, ?16, ?17)`,
            ).bind(
              eventId,
              message.assignmentId,
              workspaceId,
              message.attemptId,
              activityPayload.data.executionId,
              activityPayload.data.workerId,
              activityPayload.data.sourceEventId,
              activityPayload.data.activitySequence,
              activityPayload.data.activityType,
              activityPayload.data.activityStatus,
              activityPayload.data.activityId ?? null,
              activityPayload.data.title,
              JSON.stringify(activityPayload.data.details ?? {}),
              activityPayload.data.durationMs ?? null,
              activityPayload.data.toolId ?? null,
              activityPayload.data.toolName ?? null,
              new Date().toISOString(),
            )
          : undefined;
        try {
          await createEventPublisher(this.env).publish({
            type: "assignment.activity",
            eventId,
            idempotencyKey: eventId,
            durable: replayable,
            ...(historyMutation ? { mutations: [historyMutation] } : {}),
            workspaceId,
            workspaceRuntimeId:
              this.workspaceRuntimeId ?? message.workspaceRuntimeId,
            runId: message.runId,
            taskId: message.taskId,
            threadId:
              typeof assignment.thread_id === "string"
                ? assignment.thread_id
                : undefined,
            attemptId: message.attemptId,
            assignmentId: message.assignmentId,
            payload: activityPayload.data,
          });
          if (replayable) {
            tryLogDiagnosticEvent({
              assignmentId: message.assignmentId,
              workspaceId,
              workspaceRuntimeId:
                this.workspaceRuntimeId ?? message.workspaceRuntimeId,
              workerId: message.workerId,
              runId: message.runId,
              taskId: message.taskId,
              attemptId: message.attemptId,
              component: "cloud",
              operation: "assignment.activity",
              stage: "activity_forwarding",
              severity: "info",
              retryable: false,
              context: { status: "accepted" },
            });
          }
        } catch {
          tryLogDiagnosticEvent({
            assignmentId: message.assignmentId,
            workspaceId,
            workspaceRuntimeId:
              this.workspaceRuntimeId ?? message.workspaceRuntimeId,
            workerId: message.workerId,
            runId: message.runId,
            taskId: message.taskId,
            attemptId: message.attemptId,
            component: "cloud",
            operation: "assignment.activity",
            stage: "realtime_forwarding",
            severity: "error",
            errorCode: "activity_realtime_publish_failed",
            retryable: true,
          });
        }
        return;
      }
      case "thread.status":
        // Runtime readiness is logical-only. Never persist or relay a local
        // absolute path or repository clone path.
        return;
      case "assignment.result": {
        if (!(await this.terminalAssignmentMatches(message))) return;
        tryLogDiagnosticEvent({
          assignmentId: message.assignmentId,
          workspaceId: message.executionWorkspaceId,
          workspaceRuntimeId: message.workspaceRuntimeId,
          workerId: message.workerId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          component: "cloud",
          operation: "assignment",
          stage: "terminal_recorded",
          severity: "info",
          retryable: false,
          context: { status: "completed" },
        });
        const completed = await recordAssignmentResult(
          this.env.SYNTILA_DB,
          message.assignmentId!,
          message.payload as never,
          message.attemptId,
        );
        if (completed) this.traceTerminalPersisted(message, "completed");
        await this.sendTerminalAcknowledgement(message, "completed");
        await this.slotFreed();
        return;
      }
      case "assignment.error": {
        {
          if (!(await this.terminalAssignmentMatches(message))) return;
          const payload = message.payload as Record<string, unknown>;
          const error =
            payload.error && typeof payload.error === "object"
              ? (payload.error as Record<string, unknown>)
              : {};
          tryLogDiagnosticEvent({
            assignmentId: message.assignmentId,
            workspaceId: message.executionWorkspaceId,
            workspaceRuntimeId: message.workspaceRuntimeId,
            workerId: message.workerId,
            runId: message.runId,
            taskId: message.taskId,
            attemptId: message.attemptId,
            component: "cloud",
            operation: "assignment",
            stage: "terminal_recorded",
            severity: "error",
            errorCode:
              typeof error.code === "string" ? error.code : "execution_failed",
            retryable: error.retryable === true,
            context: { status: "failed" },
          });
        }
        const failed = await recordAssignmentError(
          this.env.SYNTILA_DB,
          message.assignmentId!,
          message.payload as never,
          message.attemptId,
        );
        if (failed) this.traceTerminalPersisted(message, "failed");
        await this.sendTerminalAcknowledgement(message, "failed");
        await this.slotFreed();
        return;
      }
      case "assignment.cancelled": {
        if (!(await this.terminalAssignmentMatches(message))) return;
        const cancelled = await this.recordCancellationEvidence(
          message,
          message.payload as never,
        );
        if (cancelled) this.traceTerminalPersisted(message, "cancelled");
        tryLogDiagnosticEvent({
          assignmentId: message.assignmentId,
          workspaceId: message.executionWorkspaceId,
          workspaceRuntimeId: message.workspaceRuntimeId,
          workerId: message.workerId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          component: "cloud",
          operation: "assignment",
          stage: "terminal_recorded",
          severity: "info",
          retryable: false,
          context: { status: "cancelled" },
        });
        await this.sendTerminalAcknowledgement(message, "cancelled");
        await this.slotFreed();
        return;
      }
      case "assignment.cancel.ack": {
        const payload = message.payload as Record<string, unknown>;
        if (payload.cancelled === true) {
          const recorded = await this.recordCancellationEvidence(message, {
            status: "cancelled",
            reason:
              typeof payload.reason === "string"
                ? payload.reason
                : "Cancelled by Workspace runtime",
          });
          if (recorded) {
            await signalAssignmentTerminal(this.env, message.assignmentId!);
            await this.slotFreed();
          }
        }
        const pending = this.pendingCancelAcks.get(message.assignmentId!);
        if (pending) {
          clearTimeout(pending.timer);
          pending.resolve(payload);
          this.pendingCancelAcks.delete(message.assignmentId!);
        }
        return;
      }
      default:
        return;
    }
  }

  /**
   * Service evidence that an assignment will not run. If Cloud was revoking
   * the assignment, the outcome Cloud intended (timed_out, failed, cancelled)
   * is written; otherwise this is an ordinary cancellation.
   */
  private async recordCancellationEvidence(
    message: WorkspaceRuntimeMessage,
    cancellation: { status: "cancelled"; reason: string },
  ): Promise<boolean> {
    const finalized = await finalizeAssignmentRevocation(
      this.env.SYNTILA_DB,
      message.assignmentId!,
      message.attemptId,
    );
    if (finalized === "finalized") return true;
    if (finalized !== "not_revoking") return false;
    return recordAssignmentCancelled(
      this.env.SYNTILA_DB,
      message.assignmentId!,
      cancellation,
      message.attemptId,
    );
  }

  /**
   * Re-sends `assignment.cancel` for every unconfirmed revocation of this
   * Workspace. A Service that was offline, restarted or replayed the original
   * command learns here that the assignment must not run. Unconfirmed
   * revocations older than the grace period are shown as `reconciling`.
   */
  /**
   * Fails running assignments whose Engine process the Service has stopped
   * reporting for several heartbeats. Never throws: liveness is best effort.
   */
  private async applyEngineLiveness(
    payload: unknown,
    now: string | number | Date,
  ): Promise<void> {
    const workspaceId = this.executionWorkspaceId;
    const report = parseEngineLivenessReport(payload);
    if (!workspaceId || !report) return;
    try {
      const at = new Date(now).toISOString();
      const lost = await applyEngineLivenessReport(
        this.env.SYNTILA_DB,
        workspaceId,
        report,
        at,
      );
      if (lost.length === 0) return;
      await failLostEngineAssignments(this.env.SYNTILA_DB, lost, at);
      await this.resendPendingRevocations();
    } catch {
      // Best effort: the execution deadline still bounds the assignment.
    }
  }

  private async resendPendingRevocations(): Promise<void> {
    const workspaceId = this.executionWorkspaceId;
    if (!workspaceId) return;
    await finalizeRevocationsOfRevokedRuntimes(
      this.env.SYNTILA_DB,
      workspaceId,
    );
    await escalateUnconfirmedRevocations(
      this.env.SYNTILA_DB,
      ASSIGNMENT_REVOCATION_CONFIRMATION_MS,
    );
    const { results } = await this.env.SYNTILA_DB.prepare(
      `SELECT id, execution_workspace_id, runtime_identity_id,
              workspace_worker_id, run_id, task_id, attempt_id,
              idempotency_key, error_json
         FROM worker_assignments
        WHERE execution_workspace_id = ?1
          AND status IN ('revocation_pending', 'reconciling')
        LIMIT 100`,
    )
      .bind(workspaceId)
      .all<Record<string, unknown>>();
    for (const row of results ?? []) {
      let reason = "Cloud revoked the assignment";
      let commandId = `revoke:${String(row.id)}:${String(row.attempt_id)}`;
      try {
        const stored = JSON.parse(String(row.error_json ?? "{}")) as {
          revocation?: { reason?: unknown; commandId?: unknown };
        };
        if (typeof stored.revocation?.reason === "string")
          reason = stored.revocation.reason;
        if (typeof stored.revocation?.commandId === "string")
          commandId = stored.revocation.commandId;
      } catch {
        // Keep the defaults; the command is still safe to re-send.
      }
      try {
        await this.send({
          protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
          protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
          messageId: `message-${crypto.randomUUID()}`,
          timestamp: new Date().toISOString(),
          type: "assignment.cancel",
          executionWorkspaceId: String(row.execution_workspace_id),
          workspaceRuntimeId: String(row.runtime_identity_id),
          workerId: String(row.workspace_worker_id),
          runId: String(row.run_id),
          taskId: String(row.task_id),
          attemptId: String(row.attempt_id),
          assignmentId: String(row.id),
          idempotencyKey: String(row.idempotency_key),
          payload: {
            assignmentId: String(row.id),
            reason,
            commandId,
            deadlineMs: Date.now() + 10_000,
          } satisfies AssignmentCancelPayload,
        });
      } catch {
        // Transport gone again; the next sync re-sends.
      }
    }
  }

  private async syncWorkspace(correlationId: string): Promise<void> {
    const workspaceId = this.executionWorkspaceId;
    if (!workspaceId) return;
    const terminalSince = new Date(
      Date.now() - 24 * 60 * 60 * 1000,
    ).toISOString();
    const assignments = await this.env.SYNTILA_DB.prepare(
      `SELECT id AS assignment_id, status
       FROM worker_assignments
       WHERE execution_workspace_id = ?1
         AND (
           status IN (${ACTIVE_ASSIGNMENT_STATUS_SQL})
           OR (status IN ('completed', 'failed', 'cancelled', 'timed_out') AND updated_at >= ?2)
         )
       ORDER BY updated_at DESC
       LIMIT 500`,
    )
      .bind(workspaceId, terminalSince)
      .all<Record<string, unknown>>();
    const activeStatuses = new Set<string>(ASSIGNMENT_ACTIVE_STATUSES);
    const assignmentRows = assignments.results ?? [];
    // Spaces that still exist for this Workspace. The Service uses it only to
    // forget local bookkeeping for removed Spaces; it never deletes folders.
    // Omitted on a query failure so the Service keeps everything.
    let knownSpaceIds: string[] | undefined;
    try {
      const spaces = await this.env.SYNTILA_DB.prepare(
        `SELECT DISTINCT g.space_id AS space_id
         FROM workspace_space_grants g
         JOIN spaces s ON s.id = g.space_id
         WHERE g.workspace_id = ?1
         LIMIT 5000`,
      )
        .bind(workspaceId)
        .all<{ space_id: string }>();
      knownSpaceIds = (spaces.results ?? []).map((row) => String(row.space_id));
    } catch {
      knownSpaceIds = undefined;
    }
    await this.send({
      protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
      protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
      messageId: `message-${crypto.randomUUID()}`,
      correlationId,
      timestamp: new Date().toISOString(),
      type: "workspace.sync.result",
      executionWorkspaceId: workspaceId,
      workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
      payload: {
        activeAssignmentIds: assignmentRows
          .filter((row) => activeStatuses.has(String(row.status)))
          .map((row) => String(row.assignment_id)),
        assignmentStates: assignmentRows.map((row) => ({
          assignmentId: String(row.assignment_id),
          status: String(row.status),
        })),
        ...(knownSpaceIds ? { knownSpaceIds } : {}),
      },
    });
  }

  private rememberCommandQueued(assignmentId: string | undefined): void {
    if (!assignmentId) return;
    if (this.commandQueuedAt.size >= WorkspaceGateway.MAX_TRACKED_COMMANDS) {
      const oldest = this.commandQueuedAt.keys().next().value;
      if (oldest !== undefined) this.commandQueuedAt.delete(oldest);
    }
    this.commandQueuedAt.set(assignmentId, Date.now());
  }

  /**
   * Traces receipt of `assignment.ack`. The Service may attach `serviceTrace`
   * (wall-clock receipt/acceptance times plus its clock-offset estimate); only
   * bounded numbers are forwarded. Never throws.
   */
  private traceCommandAcknowledged(
    message: WorkspaceRuntimeMessage,
    payload: Record<string, unknown>,
    accepted: boolean,
  ): void {
    try {
      const queuedAt = message.assignmentId
        ? this.commandQueuedAt.get(message.assignmentId)
        : undefined;
      if (message.assignmentId)
        this.commandQueuedAt.delete(message.assignmentId);
      const serviceTrace =
        payload.serviceTrace && typeof payload.serviceTrace === "object"
          ? (payload.serviceTrace as Record<string, unknown>)
          : {};
      const integer = (value: unknown): number | undefined =>
        typeof value === "number" && Number.isInteger(value)
          ? value
          : undefined;
      const offset = integer(serviceTrace.clockOffsetMs);
      const rtt = integer(serviceTrace.clockRttMs);
      const queue = integer(serviceTrace.localQueueLength);
      const active = integer(serviceTrace.activeAssignments);
      const syncState =
        typeof serviceTrace.syncState === "string" &&
        /^[A-Za-z0-9._:-]{1,128}$/.test(serviceTrace.syncState)
          ? serviceTrace.syncState
          : undefined;
      tryLogTraceEvent({
        traceStage: "cloud_ack_received",
        assignmentId: message.assignmentId,
        workspaceId: message.executionWorkspaceId,
        workspaceRuntimeId: message.workspaceRuntimeId,
        workerId: message.workerId,
        runId: message.runId,
        taskId: message.taskId,
        attemptId: message.attemptId,
        ...(queuedAt !== undefined
          ? { durationMs: Math.max(0, Date.now() - queuedAt) }
          : {}),
        context: {
          status: accepted ? "accepted" : "rejected",
          transport: this.socket ? "websocket" : "http_long_poll",
          ...(offset !== undefined &&
          offset >= -86_400_000 &&
          offset <= 86_400_000
            ? { clockOffsetMs: offset }
            : {}),
          ...(rtt !== undefined && rtt >= 0 && rtt <= 600_000
            ? { clockRttMs: rtt }
            : {}),
          ...(queue !== undefined && queue >= 0 && queue <= 100_000
            ? { localQueueLength: queue }
            : {}),
          ...(active !== undefined && active >= 0 && active <= 100_000
            ? { activeAssignments: active }
            : {}),
          ...(syncState ? { syncState } : {}),
        },
      });
    } catch {
      // Telemetry boundary.
    }
  }

  /**
   * Records what an acknowledgement did. Ignored outcomes (`duplicate`,
   * `superseded`, `terminal`, `stale`) are the evidence of reordering and
   * replay, so they are logged instead of silently dropped. Never throws.
   */
  private traceTransitionOutcome(
    message: WorkspaceRuntimeMessage,
    evidence: "admission" | "provider_start",
    transition: AssignmentTransitionResult,
  ): void {
    if (transition.applied) return;
    tryLogDiagnosticEvent({
      assignmentId: message.assignmentId,
      workspaceId: message.executionWorkspaceId,
      workspaceRuntimeId: message.workspaceRuntimeId,
      workerId: message.workerId,
      runId: message.runId,
      taskId: message.taskId,
      attemptId: message.attemptId,
      component: "cloud",
      operation: "assignment",
      stage: "transition_ignored",
      severity: transition.outcome === "stale" ? "warning" : "info",
      retryable: false,
      context: {
        status: `${evidence}_${transition.outcome}`,
      },
    });
  }

  /** T11: emitted after the terminal outcome is durably written to D1. */
  private traceTerminalPersisted(
    message: WorkspaceRuntimeMessage,
    status: "completed" | "failed" | "cancelled",
  ): void {
    tryLogTraceEvent({
      traceStage: "terminal_persisted",
      assignmentId: message.assignmentId,
      workspaceId: message.executionWorkspaceId,
      workspaceRuntimeId: message.workspaceRuntimeId,
      workerId: message.workerId,
      runId: message.runId,
      taskId: message.taskId,
      attemptId: message.attemptId,
      context: { status },
    });
  }

  private async sendTerminalAcknowledgement(
    message: WorkspaceRuntimeMessage,
    status: "completed" | "failed" | "cancelled",
  ): Promise<void> {
    const diagnostic = (stage: string) => {
      if (
        (this.env as unknown as { REALTIME_DIAGNOSTICS?: string })
          .REALTIME_DIAGNOSTICS === "1"
      ) {
        console.log(
          JSON.stringify({
            diagnostic: "terminal_ack",
            stage,
            assignmentId: message.assignmentId,
            at: new Date().toISOString(),
          }),
        );
      }
    };
    diagnostic("read_start");
    const row = message.assignmentId
      ? await this.env.SYNTILA_DB.prepare(
          "SELECT status FROM worker_assignments WHERE id = ?1",
        )
          .bind(message.assignmentId)
          .first<{ status: string }>()
      : null;
    diagnostic("read_done");
    // Local Worker Protocol 4.x acknowledges timeout as a failed terminal
    // delivery; Cloud retains the more precise timed_out assignment outcome.
    const authoritativeStatus =
      row?.status === "completed" ||
      row?.status === "failed" ||
      row?.status === "cancelled"
        ? row.status
        : row?.status === "timed_out"
          ? "failed"
          : status;
    tryLogDiagnosticEvent({
      assignmentId: message.assignmentId,
      workspaceId: message.executionWorkspaceId,
      workspaceRuntimeId: message.workspaceRuntimeId,
      workerId: message.workerId,
      runId: message.runId,
      taskId: message.taskId,
      attemptId: message.attemptId,
      component: "cloud",
      operation: "assignment",
      stage: "terminal_acknowledgement",
      severity: "info",
      retryable: false,
      context: { status: authoritativeStatus },
    });
    diagnostic("ack_send_start");
    await this.send({
      protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
      protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
      messageId: `message-${crypto.randomUUID()}`,
      correlationId: message.messageId,
      timestamp: new Date().toISOString(),
      type: "assignment.ack",
      executionWorkspaceId: message.executionWorkspaceId,
      workspaceRuntimeId: message.workspaceRuntimeId,
      workerId: message.workerId,
      runId: message.runId,
      taskId: message.taskId,
      attemptId: message.attemptId,
      assignmentId: message.assignmentId,
      idempotencyKey: message.idempotencyKey,
      payload: {
        accepted: true,
        terminal: true,
        status: authoritativeStatus,
      },
    });
    diagnostic("ack_send_done");
    // Notify the Workflow only after the result is durable and acknowledged.
    // A failed signal is recovered by the outbox sweep and the waiter's own
    // reconciliation; it must never delay or fail the acknowledgement above.
    if (message.assignmentId) {
      diagnostic("signal_start");
      await signalAssignmentTerminal(this.env, message.assignmentId);
      diagnostic("signal_done");
    }
  }

  private async terminalAssignmentMatches(
    message: WorkspaceRuntimeMessage,
  ): Promise<boolean> {
    if (
      !message.assignmentId ||
      !message.executionWorkspaceId ||
      !message.workspaceRuntimeId
    ) {
      return false;
    }
    const assignment = await this.env.SYNTILA_DB.prepare(
      `SELECT id, execution_workspace_id, runtime_identity_id,
              worker_type_id, workspace_worker_id, run_id, task_id,
              attempt_id, idempotency_key
         FROM worker_assignments WHERE id = ?1`,
    )
      .bind(message.assignmentId)
      .first<Record<string, unknown>>();
    return (
      assignment != null &&
      workspaceAssignmentContextMatches(
        message as unknown as WorkspaceAssignmentCorrelation,
        assignment,
      ) &&
      message.executionWorkspaceId === this.executionWorkspaceId &&
      message.workspaceRuntimeId === this.workspaceRuntimeId
    );
  }

  private async assignmentContextMatches(
    message: WorkspaceRuntimeMessage,
  ): Promise<boolean> {
    if (
      !message.assignmentId ||
      !message.executionWorkspaceId ||
      !message.workspaceRuntimeId
    ) {
      return false;
    }
    const assignment = await this.env.SYNTILA_DB.prepare(
      `SELECT id, execution_workspace_id, runtime_identity_id,
              worker_type_id, workspace_worker_id, run_id, task_id,
              attempt_id, idempotency_key
         FROM worker_assignments WHERE id = ?1`,
    )
      .bind(message.assignmentId)
      .first<Record<string, unknown>>();
    return (
      assignment != null &&
      workspaceAssignmentContextMatches(
        message as unknown as WorkspaceAssignmentCorrelation,
        assignment,
      ) &&
      message.executionWorkspaceId === this.executionWorkspaceId &&
      message.workspaceRuntimeId === this.workspaceRuntimeId
    );
  }

  private async activeAssignmentMatches(
    message: WorkspaceRuntimeMessage,
  ): Promise<boolean> {
    if (!(await this.assignmentContextMatches(message))) return false;
    const assignment = await this.env.SYNTILA_DB.prepare(
      "SELECT status FROM worker_assignments WHERE id = ?1",
    )
      .bind(message.assignmentId)
      .first<{ status: string }>();
    return assignment != null && workspaceAssignmentIsActive(assignment);
  }

  private async recordWorkerInventory(payload: unknown): Promise<void> {
    await recordWorkspaceWorkerInventory(
      this.env,
      this.executionWorkspaceId,
      payload,
    );
  }

  /** Whether the connected Service advertised [capability] in its hello. */
  private async serviceHasCapability(capability: string): Promise<boolean> {
    const workspaceId = this.executionWorkspaceId;
    if (!workspaceId) return false;
    const facts = await this.env.SYNTILA_DB.prepare(
      "SELECT runtime_capabilities_json FROM workspace_runtime_facts WHERE workspace_id = ?1",
    )
      .bind(workspaceId)
      .first<{ runtime_capabilities_json: string | null }>();
    try {
      const capabilities: unknown = JSON.parse(
        facts?.runtime_capabilities_json ?? "[]",
      );
      return Array.isArray(capabilities) && capabilities.includes(capability);
    } catch {
      return false;
    }
  }

  /** Whether the connected Service advertised the start-permit capability. */
  private async serviceSupportsStartPermit(): Promise<boolean> {
    const advertised = await this.state.storage.get<{
      sessionId: string;
      runtimeId: string;
      capabilities: string[];
    }>("execution-capabilities");
    return (
      advertised?.sessionId === this.sessionId &&
      advertised?.runtimeId === this.workspaceRuntimeId &&
      advertised?.capabilities.includes(START_PERMIT_CAPABILITY) === true
    );
  }

  /**
   * Loads the persisted readiness once per Durable Object instance. A record
   * that belongs to a different session or runtime identity (a replaced
   * connection) is never trusted: the session restarts as authenticated and
   * not ready. This is what makes readiness survive hibernation: the session
   * identity comes from the WebSocket attachment, the state from storage.
   */
  private async loadReadiness(): Promise<void> {
    if (this.readinessLoaded) return;
    const stored = await this.state.storage.get<ServiceReadiness>(
      WorkspaceGateway.READINESS_STORAGE_KEY,
    );
    if (!this.sessionId || !this.workspaceRuntimeId) {
      // No session to attach the record to yet. Do not mark as loaded.
      this.readiness = null;
      return;
    }
    this.readinessLoaded = true;
    this.readiness =
      stored &&
      stored.sessionId === this.sessionId &&
      stored.workspaceRuntimeId === this.workspaceRuntimeId
        ? stored
        : authenticatedReadiness({
            sessionId: this.sessionId,
            workspaceRuntimeId: this.workspaceRuntimeId,
            ...(stored ? { previousGeneration: stored.syncGeneration } : {}),
            now: new Date().toISOString(),
          });
  }

  /**
   * Serialized readiness mutation. WebSocket messages are handled
   * concurrently, so every change goes through one chain: it is persisted,
   * published and, when the Service becomes ready, followed by a flush of the
   * durable queue.
   */
  private async mutateReadiness(
    change: (current: ServiceReadiness | null) => ServiceReadiness | null,
    options: { readonly publish?: boolean } = {},
  ): Promise<ServiceReadiness | null> {
    const run = this.readinessChain.then(async () => {
      await this.loadReadiness();
      const previous = this.readiness;
      const next = change(previous);
      if (!next || next === previous) {
        return { readiness: previous, becameReady: false };
      }
      this.readiness = next;
      this.readinessLoaded = true;
      await this.state.storage.put(
        WorkspaceGateway.READINESS_STORAGE_KEY,
        next,
      );
      const changed =
        !previous ||
        previous.sessionId !== next.sessionId ||
        previous.state !== next.state ||
        previous.readyForAssignments !== next.readyForAssignments ||
        previous.syncGeneration !== next.syncGeneration;
      if (changed && options.publish !== false) {
        await this.publishReadiness(next);
      }
      const becameReady =
        next.readyForAssignments &&
        !(
          previous?.readyForAssignments && previous.sessionId === next.sessionId
        );
      return { readiness: next, becameReady };
    });
    this.readinessChain = run.catch(() => undefined);
    const result = await run;
    if (result.becameReady) {
      await this.flushQueuedAssignments().catch((error: unknown) =>
        logStructured(
          "error",
          "workspace_queue_flush_failed",
          { workspaceId: this.executionWorkspaceId ?? undefined },
          { error: error instanceof Error ? error.message : String(error) },
        ),
      );
    }
    return result.readiness;
  }

  /** Publishes a readiness change to D1 and realtime subscribers at once. */
  private async publishReadiness(readiness: ServiceReadiness): Promise<void> {
    const workspaceId = this.executionWorkspaceId;
    if (!workspaceId) return;
    try {
      await this.env.SYNTILA_DB.prepare(
        `INSERT INTO workspace_service_readiness
           (workspace_id, runtime_identity_id, session_id, sync_generation,
            state, ready_for_assignments, source, reason, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT(workspace_id) DO UPDATE SET
           runtime_identity_id = excluded.runtime_identity_id,
           session_id = excluded.session_id,
           sync_generation = excluded.sync_generation,
           state = excluded.state,
           ready_for_assignments = excluded.ready_for_assignments,
           source = excluded.source,
           reason = excluded.reason,
           updated_at = excluded.updated_at`,
      )
        .bind(
          workspaceId,
          readiness.workspaceRuntimeId,
          readiness.sessionId,
          readiness.syncGeneration,
          readiness.state,
          readiness.readyForAssignments ? 1 : 0,
          readiness.source,
          readiness.reason ?? null,
          readiness.updatedAt,
        )
        .run();
    } catch (error) {
      logStructured(
        "warn",
        "workspace_readiness_projection_failed",
        { workspaceId },
        { error: error instanceof Error ? error.message : String(error) },
      );
    }
    await createEventPublisher(this.env)
      .publish({
        type: "workspace.readiness.updated",
        workspaceId,
        payload: {
          status: readiness.readyForAssignments ? "ready" : readiness.state,
        },
        durable: false,
      })
      .catch(() => undefined);
  }

  /** Applies a readiness report received on [sessionId]. */
  private async applyReadinessReport(
    report: ServiceReadinessReport,
    sessionId: string,
    now: string,
  ): Promise<void> {
    this.readinessCapable = true;
    let outcome = "applied";
    await this.mutateReadiness((current) => {
      const decision = applyServiceReadiness(
        current,
        report,
        { sessionId, workspaceRuntimeId: this.workspaceRuntimeId ?? "" },
        now,
      );
      outcome = decision.outcome;
      return decision.outcome === "applied" ? decision.readiness : null;
    });
    // A command can be queued while the Service is ready if readiness was
    // observed as not-ready for an instant at dispatch time; the ready
    // transition that normally flushes the queue has then already passed.
    // Every readiness report from a ready Service re-checks the durable queue
    // so such an assignment is delivered instead of timing out.
    if (this.readiness?.readyForAssignments === true) {
      await this.flushQueuedAssignments().catch((error: unknown) =>
        logStructured(
          "error",
          "workspace_queue_flush_failed",
          { workspaceId: this.executionWorkspaceId ?? undefined },
          { error: error instanceof Error ? error.message : String(error) },
        ),
      );
    }
    if (outcome !== "applied" && outcome !== "unchanged") {
      logStructured(
        "warn",
        "workspace_readiness_ignored",
        {
          requestId: this.correlationId ?? undefined,
          runtimeId: this.workspaceRuntimeId ?? undefined,
          workspaceId: this.executionWorkspaceId ?? undefined,
        },
        { outcome, state: report.state },
      );
    }
  }

  /**
   * Explains why an assignment stayed in the durable queue. Without this the
   * only signal is a generic "waiting for service ready" with no cause.
   */
  private async logNotReadyDelivery(
    reason: string,
    body: { readonly assignmentId: string },
  ): Promise<void> {
    try {
      await this.loadReadiness();
      const advertised = await this.state.storage.get<{
        sessionId: string;
        runtimeId: string;
        capabilities: string[];
      }>("execution-capabilities");
      const lastActivityAt = await this.lastRuntimeActivityAt();
      logStructured(
        "warn",
        "assignment_delivery_deferred",
        {
          workspaceId: this.executionWorkspaceId ?? undefined,
          runtimeId: this.workspaceRuntimeId ?? undefined,
        },
        {
          reason,
          assignmentId: body.assignmentId,
          sessionId: this.sessionId,
          hasSocket: this.socket !== null,
          lastActivityAt,
          activityRecent: this.isActivityRecent(lastActivityAt),
          readinessState: this.readiness?.state ?? null,
          readinessSessionId: this.readiness?.sessionId ?? null,
          readyForAssignments: this.readiness?.readyForAssignments ?? null,
          advertisedSessionId: advertised?.sessionId ?? null,
          advertisedRuntimeId: advertised?.runtimeId ?? null,
          advertisedHasStartPermit:
            advertised?.capabilities.includes(START_PERMIT_CAPABILITY) ?? null,
          runtimeIdMatches: advertised?.runtimeId === this.workspaceRuntimeId,
        },
      );
    } catch {
      // Diagnostics must never change delivery behavior.
    }
  }

  /** Whether the Service can be handed a command right now. */
  private async serviceIsReady(): Promise<boolean> {
    await this.loadReadiness();
    return effectiveReadiness(this.readiness, await this.isRuntimeLive()).ready;
  }

  /**
   * A new authenticated session replaces whatever the previous one published.
   * The in-memory state is cleared synchronously, so no dispatch can observe
   * the replaced session's readiness while the new state is being persisted.
   */
  private startReadinessSession(
    sessionId: string,
    runtimeId: string,
  ): Promise<ServiceReadiness | null> {
    this.readinessCapable = null;
    this.readinessLoaded = true;
    this.readiness = null;
    return this.mutateReadiness(() =>
      authenticatedReadiness({
        sessionId,
        workspaceRuntimeId: runtimeId,
        now: new Date().toISOString(),
      }),
    );
  }

  /** A Service that does not publish readiness is inferred ready after sync. */
  private async inferReadinessIfLegacy(): Promise<void> {
    if (this.readinessCapable === null) {
      this.readinessCapable = await this.serviceHasCapability(
        SERVICE_READINESS_CAPABILITY,
      );
    }
    if (this.readinessCapable) return;
    await this.mutateReadiness((current) =>
      current ? inferLegacyReadiness(current, new Date().toISOString()) : null,
    );
  }

  private async dispatchAssignment(request: Request): Promise<Response> {
    const body = (await request.json()) as WorkspaceAssignmentCorrelation & {
      payload: unknown;
    };
    return this.deliverAssignment(body);
  }

  /**
   * Hands every `created` assignment waiting for this Service to the
   * transport, oldest first. Called when the Service becomes ready, when the
   * Workflow nudges a waiting assignment, and after a connection replacement.
   * Each assignment is claimed with a conditional `created -> dispatched`
   * write, so a flush racing a direct dispatch can never send a command twice.
   */
  private async flushQueuedAssignments(): Promise<number> {
    const workspaceId = this.executionWorkspaceId;
    const runtimeId = this.workspaceRuntimeId;
    if (!workspaceId || !runtimeId) return 0;
    if (this.flushingQueue) {
      this.flushRequested = true;
      return 0;
    }
    if (!(await this.serviceIsReady())) {
      await recordCloudQueueNotReady(
        this.env.SYNTILA_DB,
        workspaceId,
        runtimeId,
      );
      return 0;
    }
    this.flushingQueue = true;
    this.flushRequested = false;
    let flushed = 0;
    try {
      for (let pass = 0; pass < 8; pass += 1) {
        const rows = await this.env.SYNTILA_DB.prepare(
          `SELECT id, run_id, task_id, attempt_id, idempotency_key,
                  workspace_worker_id, command_payload_json
             FROM worker_assignments
            WHERE execution_workspace_id = ?1 AND runtime_identity_id = ?2
              AND status = 'created' AND command_payload_json IS NOT NULL
              AND task_id NOT IN (
                SELECT wt.id FROM workflow_tasks wt
                  JOIN work_requests wr ON wr.id = wt.work_request_id
                 WHERE wr.status IN ('cancelled', 'failed', 'completed'))
            ORDER BY created_at, id
            LIMIT 25`,
        )
          .bind(workspaceId, runtimeId)
          .all<{
            id: string;
            run_id: string;
            task_id: string;
            attempt_id: string;
            idempotency_key: string;
            workspace_worker_id: string;
            command_payload_json: string;
          }>();
        const queued = rows.results ?? [];
        if (queued.length === 0) break;
        let progressed = 0;
        for (const row of queued) {
          if (!(await this.serviceIsReady())) return flushed;
          let payload: unknown;
          try {
            payload = JSON.parse(row.command_payload_json);
          } catch {
            continue;
          }
          const response = await this.deliverAssignment(
            {
              executionWorkspaceId: workspaceId,
              workspaceRuntimeId: runtimeId,
              workerId: row.workspace_worker_id,
              runId: row.run_id,
              taskId: row.task_id,
              attemptId: row.attempt_id,
              assignmentId: row.id,
              idempotencyKey: row.idempotency_key,
              payload,
            } as WorkspaceAssignmentCorrelation & { payload: unknown },
            { claimCreated: true },
          );
          const result = (await response.json().catch(() => ({}))) as {
            delivered?: boolean;
            deliveryState?: string;
          };
          if (result.delivered === true) {
            flushed += 1;
            progressed += 1;
          }
          // Every slot is taken; the next finished assignment flushes again.
          if (result.deliveryState === "waiting_for_slot") break;
        }
        // Rows that could not be claimed or delivered stay queued for the
        // next trigger; stop rather than spin on them.
        if (progressed === 0 && !this.flushRequested) break;
        this.flushRequested = false;
      }
    } finally {
      this.flushingQueue = false;
    }
    return flushed;
  }

  private withSlotLock<T>(run: () => Promise<T>): Promise<T> {
    const next = this.slotChain.then(run, run);
    this.slotChain = next.catch(() => undefined);
    return next;
  }

  /** The owner's slot total from Workspace settings (the web Workspaces page). */
  private async workspaceSlotLimit(): Promise<number> {
    const row = await this.env.SYNTILA_DB.prepare(
      "SELECT parallel_slots AS slots FROM execution_workspaces WHERE id = ?1",
    )
      .bind(this.executionWorkspaceId)
      .first<{ slots: number | null }>();
    return row?.slots ?? DEFAULT_WORKSPACE_PARALLEL_SLOTS;
  }

  /**
   * Every non-terminal assignment that left the queue holds a slot, including
   * ones being revoked: their process may still be running.
   */
  private async slotIsFree(): Promise<boolean> {
    const row = await this.env.SYNTILA_DB.prepare(
      `SELECT COUNT(*) AS active FROM worker_assignments
        WHERE execution_workspace_id = ?1
          AND status IN (${ACTIVE_ASSIGNMENT_STATUS_SQL}) AND status <> 'created'`,
    )
      .bind(this.executionWorkspaceId)
      .first<{ active: number }>();
    return Number(row?.active ?? 0) < (await this.workspaceSlotLimit());
  }

  /** A slot was freed: hand the next queued assignment to the Service. */
  private async slotFreed(): Promise<void> {
    await this.flushQueuedAssignments().catch((error: unknown) =>
      logStructured(
        "error",
        "workspace_queue_flush_failed",
        { workspaceId: this.executionWorkspaceId ?? undefined },
        { error: error instanceof Error ? error.message : String(error) },
      ),
    );
  }

  private async deliverAssignment(
    body: WorkspaceAssignmentCorrelation & { payload: unknown },
    options: { readonly claimCreated?: boolean } = {},
  ): Promise<Response> {
    if (this.deliveringAssignments.has(body.assignmentId)) {
      return Response.json({
        delivered: false,
        duplicate: true,
        deliveryState: "in_progress",
      });
    }
    this.deliveringAssignments.add(body.assignmentId);
    try {
      return await this.deliverAssignmentOnce(body, options);
    } finally {
      this.deliveringAssignments.delete(body.assignmentId);
    }
  }

  private async deliverAssignmentOnce(
    body: WorkspaceAssignmentCorrelation & { payload: unknown },
    options: { readonly claimCreated?: boolean },
  ): Promise<Response> {
    const row = await this.env.SYNTILA_DB.prepare(
      `SELECT wa.id, wa.execution_workspace_id, wa.runtime_identity_id,
              wa.worker_type_id, wa.workspace_worker_id,
              wa.run_id, wa.task_id, wa.attempt_id,
              wa.idempotency_key, wa.status, wa.start_permit_required
       FROM worker_assignments wa
       JOIN workspace_space_grants g
         ON g.id = wa.workspace_space_grant_id
        AND g.space_id = wa.space_id
        AND g.workspace_id = wa.execution_workspace_id
        AND g.status = 'active'
        AND (g.expires_at IS NULL OR g.expires_at > ?2)
       WHERE wa.id = ?1`,
    )
      .bind(body.assignmentId, new Date().toISOString())
      .first<Record<string, unknown>>();
    if (
      !row ||
      !workspaceAssignmentContextMatches(body, row) ||
      !workspaceAssignmentIsActive(row)
    ) {
      return Response.json(
        { error: "Assignment is not valid for this Workspace runtime" },
        { status: 409 },
      );
    }
    const currentStatus = String(row.status);
    const disposition = assignmentCommandDisposition(currentStatus);
    if (!disposition.shouldSend && disposition.duplicate) {
      return Response.json({
        delivered: false,
        ...disposition,
        status: currentStatus,
      });
    }
    if (!disposition.shouldSend) {
      return Response.json({
        delivered: false,
        ...disposition,
        status: currentStatus,
      });
    }
    let assignmentMessage: WorkspaceRuntimeMessage;
    try {
      assignmentMessage = parseWorkspaceRuntimeMessage({
        protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
        protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        messageId: `message-${crypto.randomUUID()}`,
        timestamp: new Date().toISOString(),
        type: "assignment.start",
        ...body,
        payload: withStartPermitRequirement(
          withSlotLimit(body.payload, await this.workspaceSlotLimit()),
        ),
      });
    } catch {
      return Response.json(
        { error: "Assignment must identify a product Worker Type" },
        { status: 400 },
      );
    }
    if (options.claimCreated && currentStatus !== "created") {
      return Response.json({
        delivered: false,
        duplicate: true,
        status: currentStatus,
      });
    }
    const deliverySessionId = this.sessionId;
    if (!(await this.serviceSupportsStartPermit())) {
      await this.logNotReadyDelivery("start_permit_capability_missing", body);
      return Response.json(
        {
          delivered: false,
          queued: true,
          deliveryState: "service_upgrade_required",
          acceptance: "none",
          requiredCapability: START_PERMIT_CAPABILITY,
          status: currentStatus,
        },
        { status: 202 },
      );
    }
    // A command is written only to a Service that is ready to handle it
    // immediately. Otherwise the assignment stays `created` with its payload
    // persisted: that is a durable Cloud-side queue, never a delivery. It is
    // flushed when the Service reports ready.
    if (!(await this.serviceIsReady())) {
      await recordCloudQueueReason(
        this.env.SYNTILA_DB,
        body.assignmentId,
        body.attemptId,
        "service_not_ready",
      );
      await this.logNotReadyDelivery("service_not_ready", body);
      return Response.json(
        {
          delivered: false,
          queued: true,
          deliveryState: "waiting_for_service_ready",
          acceptance: "none",
          serviceState: effectiveReadiness(
            this.readiness,
            await this.isRuntimeLive(),
          ).state,
          status: currentStatus,
        },
        { status: 202 },
      );
    }
    // Persist "possibly delivered" BEFORE the command can exist. From this
    // point Cloud must treat the Service as possibly holding the command, so
    // every later stop goes through revocation instead of a bare terminal
    // write. If revocation won the race, the command is never written.
    // A `created` assignment takes a slot only if one is free; otherwise it
    // stays in the durable Cloud queue until an assignment finishes.
    const claim = await this.withSlotLock(async () => {
      if (currentStatus === "created" && !(await this.slotIsFree()))
        return null;
      return transitionAssignment(this.env.SYNTILA_DB, {
        fence: {
          assignmentId: body.assignmentId,
          attemptId: body.attemptId,
          executionWorkspaceId: body.executionWorkspaceId,
          runtimeIdentityId: body.workspaceRuntimeId,
        },
        to: "dispatched",
        ...(options.claimCreated ? { onlyFrom: ["created"] as const } : {}),
      });
    });
    if (!claim) {
      await recordCloudQueueReason(
        this.env.SYNTILA_DB,
        body.assignmentId,
        body.attemptId,
        "workspace_capacity",
      );
      await publishAssignmentPhase(this.env, body.assignmentId);
      return Response.json(
        {
          delivered: false,
          queued: true,
          deliveryState: "waiting_for_slot",
          acceptance: "none",
          status: currentStatus,
        },
        { status: 202 },
      );
    }
    const persisted = claim;
    if (options.claimCreated && !persisted.applied) {
      // Another delivery claimed it first; that one sends the command.
      return Response.json({
        delivered: false,
        duplicate: true,
        status: persisted.currentStatus ?? currentStatus,
      });
    }
    if (persisted.applied) {
      await this.env.SYNTILA_DB.prepare(
        `UPDATE worker_assignments SET start_permit_required = 1
          WHERE id = ?1 AND start_permit_required = 0 AND status = 'dispatched'`,
      )
        .bind(body.assignmentId)
        .run();
    }
    if (!persisted.applied && persisted.outcome !== "duplicate") {
      return Response.json(
        {
          delivered: false,
          error: "Assignment is no longer deliverable",
          status: persisted.currentStatus ?? currentStatus,
        },
        { status: 409 },
      );
    }
    const queueStartedAt = performance.now();
    if (this.sessionId !== deliverySessionId) {
      // Delivery persistence raced a connection replacement. Keep the durable
      // assignment for reconciliation; the new session must prove capability.
      return Response.json(
        {
          delivered: false,
          queued: true,
          deliveryState: "waiting_for_service_ready",
          acceptance: "none",
        },
        { status: 202 },
      );
    }
    try {
      await this.send({ ...assignmentMessage });
      // T4: the command is written to the WebSocket, or appended to the
      // durable long-poll queue (whose persistence cost is included).
      this.rememberCommandQueued(body.assignmentId);
      tryLogTraceEvent({
        traceStage: "gateway_queued",
        requestId: workRequestIdOf(body.payload),
        assignmentId: body.assignmentId,
        workspaceId: body.executionWorkspaceId,
        workspaceRuntimeId: body.workspaceRuntimeId,
        workerId: body.workerId,
        runId: body.runId,
        taskId: body.taskId,
        attemptId: body.attemptId,
        durationMs: performance.now() - queueStartedAt,
        context: { transport: this.socket ? "websocket" : "http_long_poll" },
      });
    } catch (error) {
      // The write to the transport itself failed, so the Gateway knows no
      // command exists. That is first-hand evidence (not a guess) and lets
      // the assignment fail without revocation. Only the `dispatched` status
      // this call set (or found) may be failed.
      await recordAssignmentError(
        this.env.SYNTILA_DB,
        body.assignmentId,
        {
          error: {
            code: "provider_unavailable",
            message: "Workspace command could not be queued",
            retryable: true,
          },
          failedAt: new Date().toISOString(),
        },
        body.attemptId,
        { onlyFrom: ["dispatched"] },
      );
      return Response.json(
        {
          error:
            error instanceof Error
              ? error.message
              : "Workspace command could not be queued",
          retryable: true,
          deliveryState: "blocked",
          acceptance: "pending",
        },
        { status: 503 },
      );
    }
    return Response.json({
      delivered: true,
      ...disposition,
      commandId: assignmentMessage.messageId,
      deliveryState: "queued",
      acceptance: "pending",
    });
  }

  /**
   * Sends a Cloud-to-Service probe over the live Workspace transport and waits
   * for its acknowledgement. No assignment, Worker or provider process is
   * involved, so the result isolates transport and Service message-loop
   * latency. A Service that predates probes simply never answers; the probe
   * then reports `timeout` rather than failing the Workspace.
   */
  private async diagnosticProbe(): Promise<Response> {
    if (!(await this.isRuntimeLive()))
      return Response.json({ error: "Workspace is offline" }, { status: 503 });
    if (this.pendingProbes.size >= WorkspaceGateway.MAX_PENDING_PROBES)
      return Response.json(
        { error: "Too many delivery probes are in progress" },
        { status: 429 },
      );
    const probeId = `probe-${crypto.randomUUID()}`;
    const transport = this.socket ? "websocket" : "http_long_poll";
    const sentAt = new Date().toISOString();
    const startedAt = Date.now();
    const acknowledgement = new Promise<Record<string, unknown>>(
      (resolve, reject) => {
        const timer = setTimeout(() => {
          this.pendingProbes.delete(probeId);
          reject(new Error("probe timeout"));
        }, WorkspaceGateway.PROBE_TIMEOUT_MS);
        this.pendingProbes.set(probeId, { resolve, timer });
      },
    );
    // A rejected promise nobody awaits (queueing failed first) must not
    // surface as an unhandled rejection.
    acknowledgement.catch(() => undefined);
    try {
      await this.send({
        protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
        protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        messageId: `message-${crypto.randomUUID()}`,
        timestamp: sentAt,
        type: "diagnostic.probe",
        executionWorkspaceId: this.executionWorkspaceId ?? undefined,
        workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
        payload: { probeId, sentAt },
      });
    } catch (error) {
      const pending = this.pendingProbes.get(probeId);
      if (pending) {
        clearTimeout(pending.timer);
        this.pendingProbes.delete(probeId);
      }
      return Response.json(
        {
          error:
            error instanceof Error
              ? error.message
              : "Delivery probe could not be queued",
        },
        { status: 503 },
      );
    }
    tryLogTraceEvent({
      traceStage: "probe_sent",
      workspaceId: this.executionWorkspaceId ?? undefined,
      workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
      context: { transport, probeId },
    });
    try {
      const ack = await acknowledgement;
      const roundTripMs = Date.now() - startedAt;
      tryLogTraceEvent({
        traceStage: "probe_acknowledged",
        workspaceId: this.executionWorkspaceId ?? undefined,
        workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
        durationMs: roundTripMs,
        context: { transport, probeId },
      });
      return Response.json({
        probeId,
        transport,
        outcome: "acknowledged",
        roundTripMs,
        sentAt,
        serviceReceivedAt: ack.receivedAt,
        serviceAcknowledgedAt: ack.ackedAt,
        clockOffsetMs: ack.clockOffsetMs ?? null,
        clockRttMs: ack.clockRttMs ?? null,
        syncState: ack.syncState ?? null,
        localQueueLength: ack.localQueueLength ?? null,
        activeAssignments: ack.activeAssignments ?? null,
      });
    } catch {
      return Response.json(
        {
          probeId,
          transport,
          outcome: "timeout",
          timeoutMs: WorkspaceGateway.PROBE_TIMEOUT_MS,
          note: "No acknowledgement arrived. The Workspace Service may predate delivery probes or may not be reading its connection.",
        },
        { status: 504 },
      );
    }
  }

  /**
   * Wakes the Service to list and download uploaded Work Request inputs
   * (Input Delivery v1). The message carries no identifiers or content, so
   * it is safe on both transports; a Service that misses it still polls.
   */
  private async announceInputsAvailable(): Promise<Response> {
    if (!(await this.isRuntimeLive()))
      return Response.json({ delivered: false });
    try {
      await this.send({
        protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
        protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        messageId: `message-${crypto.randomUUID()}`,
        timestamp: new Date().toISOString(),
        type: "input.available",
        executionWorkspaceId: this.executionWorkspaceId ?? undefined,
        workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
        payload: {},
      });
    } catch {
      return Response.json({ delivered: false });
    }
    return Response.json({ delivered: true });
  }

  /**
   * Asks the Workspace Service to run a Worker's Profile-defined usage command
   * and returns the provider's report verbatim. Nothing is stored or parsed:
   * every provider calculates usage differently.
   */
  private async requestWorkerUsage(request: Request): Promise<Response> {
    if (!(await this.isRuntimeLive()))
      return Response.json({ error: "Workspace is offline" }, { status: 503 });
    const body = (await request.json().catch(() => null)) as {
      workerId?: unknown;
    } | null;
    const workerId = body?.workerId;
    if (
      typeof workerId !== "string" ||
      !/^[A-Za-z0-9._:-]{1,128}$/.test(workerId)
    )
      return Response.json({ error: "Invalid Worker" }, { status: 400 });
    if (
      this.pendingUsageRequests.size >=
      WorkspaceGateway.MAX_PENDING_USAGE_REQUESTS
    )
      return Response.json(
        { error: "Too many usage requests are in progress" },
        { status: 429 },
      );
    const requestId = `usage-${crypto.randomUUID()}`;
    const result = new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingUsageRequests.delete(requestId);
        reject(new Error("usage timeout"));
      }, WorkspaceGateway.USAGE_TIMEOUT_MS);
      this.pendingUsageRequests.set(requestId, { resolve, timer });
    });
    result.catch(() => undefined);
    try {
      await this.send({
        protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
        protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        messageId: `message-${crypto.randomUUID()}`,
        timestamp: new Date().toISOString(),
        type: "worker.usage.request",
        executionWorkspaceId: this.executionWorkspaceId ?? undefined,
        workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
        payload: { requestId, workerId },
      });
    } catch {
      const pending = this.pendingUsageRequests.get(requestId);
      if (pending) {
        clearTimeout(pending.timer);
        this.pendingUsageRequests.delete(requestId);
      }
      return Response.json(
        { error: "Usage request could not be queued" },
        { status: 503 },
      );
    }
    try {
      const payload = await result;
      return Response.json({
        status: payload.status,
        output: payload.output ?? "",
        errorOutput: payload.errorOutput ?? "",
        exitCode: payload.exitCode ?? null,
        truncated: payload.truncated === true,
        errorCode: payload.errorCode ?? null,
        errorMessage: payload.errorMessage ?? null,
        fetchedAt: new Date().toISOString(),
      });
    } catch {
      return Response.json(
        {
          status: "error",
          errorCode: "usage_timeout",
          errorMessage:
            "The Workspace did not return a usage report. It may need to be updated.",
        },
        { status: 504 },
      );
    }
  }

  /**
   * Runs one MCP tool step on the Workspace with at-most-once dispatch. The
   * durable claim is written before the message is sent and is never undone;
   * every uncertain path records `unknown` and is never replayed.
   */
  private async requestMcpToolCall(request: Request): Promise<Response> {
    const body = await request.json().catch(() => null);
    const parsed = McpToolCallRequestSchema.safeParse(body);
    const workspaceId = this.state.id.name ?? this.executionWorkspaceId;
    if (!parsed.success || !workspaceId)
      return Response.json({ error: "Invalid tool call" }, { status: 400 });
    const call = parsed.data;
    const db = this.env.SYNTILA_DB;
    const previous = await loadMcpToolCall(db, call.taskId);
    if (previous) {
      if (
        previous.workspaceId !== workspaceId ||
        previous.dispatchKey !== call.dispatchKey
      )
        return Response.json(
          { error: "Tool call belongs to another Workspace" },
          { status: 409 },
        );
      return Response.json(mcpToolCallReply(previous));
    }
    // Nothing has been claimed yet, so an offline Workspace is a clean refusal.
    if (!(await this.isRuntimeLive()))
      return Response.json({ error: "Workspace is offline" }, { status: 503 });
    // An older Service would reject the unknown message; refuse before claiming.
    if (!(await this.serviceHasCapability(SERVICE_MCP_TOOL_CALL_CAPABILITY)))
      return Response.json(
        { error: "Workspace does not support tool calls" },
        { status: 503 },
      );
    const claim = await claimMcpToolDispatch(db, {
      taskId: call.taskId,
      workspaceId,
      claimedAt: new Date().toISOString(),
    });
    if (!claim) {
      const existing = await loadMcpToolCall(db, call.taskId);
      if (
        existing &&
        (existing.workspaceId !== workspaceId ||
          existing.dispatchKey !== call.dispatchKey)
      )
        return Response.json(
          { error: "Tool call belongs to another Workspace" },
          { status: 409 },
        );
      return Response.json(mcpToolCallReply(existing));
    }
    const finish = async (
      state: McpToolState,
      code: string,
      result?: Record<string, unknown>,
    ) => {
      await recordMcpToolOutcome(db, {
        taskId: call.taskId,
        state,
        code,
        result,
        completedAt: new Date().toISOString(),
      });
      return Response.json(
        mcpToolCallReply(await loadMcpToolCall(db, call.taskId)),
      );
    };
    const answer = new Promise<Record<string, unknown>>((resolve) => {
      this.pendingMcpToolCalls.set(call.taskId, {
        resolve,
        workspaceRuntimeId: this.workspaceRuntimeId,
      });
    });
    try {
      await this.send({
        protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
        protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        messageId: `message-${crypto.randomUUID()}`,
        timestamp: new Date().toISOString(),
        type: "mcp.tool_call.request",
        executionWorkspaceId: this.executionWorkspaceId ?? undefined,
        workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
        payload: call,
      });
    } catch {
      this.pendingMcpToolCalls.delete(call.taskId);
      return finish("unknown", "send_failed");
    }
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<null>((resolve) => {
      timer = setTimeout(
        () => resolve(null),
        call.timeoutMs + WorkspaceGateway.MCP_TOOL_CALL_MARGIN_MS,
      );
    });
    const payload = await Promise.race([answer, timeout]);
    clearTimeout(timer);
    this.pendingMcpToolCalls.delete(call.taskId);
    if (!payload) return finish("unknown", "result_timeout");
    return finish(
      payload.state as McpToolState,
      String(payload.code),
      payload.result as Record<string, unknown> | undefined,
    );
  }

  /**
   * Asks the Workspace what it durably recorded for one logical tool step.
   * Read-only: it never claims, dispatches or changes Cloud's own record, so an
   * `unknown` Cloud outcome stays `unknown`; the answer is for diagnosis and a
   * person's decision. Only the Workspace that owns the claim is asked.
   */
  private async requestMcpToolCallStatus(request: Request): Promise<Response> {
    const body = await request.json().catch(() => null);
    const parsed = McpToolCallStatusRequestSchema.safeParse(body);
    const workspaceId = this.state.id.name ?? this.executionWorkspaceId;
    if (!parsed.success || !workspaceId)
      return Response.json(
        { error: "Invalid status request" },
        { status: 400 },
      );
    const query = parsed.data;
    const cloud = await loadMcpToolCall(this.env.SYNTILA_DB, query.taskId);
    if (!cloud)
      return Response.json({ cloud: null, workspace: null }, { status: 404 });
    if (
      cloud.workspaceId !== workspaceId ||
      cloud.dispatchKey !== query.dispatchKey
    )
      return Response.json(
        { error: "Tool call belongs to another Workspace" },
        { status: 409 },
      );
    const cloudView = {
      state: cloud.state,
      code: cloud.state ? cloud.code : "dispatch_claimed",
    };
    if (!(await this.isRuntimeLive()))
      return Response.json({
        cloud: cloudView,
        workspace: null,
        reason: "offline",
      });
    if (
      !(await this.serviceHasCapability(
        SERVICE_MCP_TOOL_CALL_STATUS_CAPABILITY,
      ))
    )
      return Response.json({
        cloud: cloudView,
        workspace: null,
        reason: "unsupported",
      });
    if (this.pendingMcpToolCallStatus.has(query.taskId))
      return Response.json(
        { error: "A status request is in flight" },
        { status: 409 },
      );
    const answer = new Promise<Record<string, unknown>>((resolve) => {
      this.pendingMcpToolCallStatus.set(query.taskId, {
        resolve,
        workspaceRuntimeId: this.workspaceRuntimeId,
      });
    });
    try {
      await this.send({
        protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
        protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        messageId: `message-${crypto.randomUUID()}`,
        timestamp: new Date().toISOString(),
        type: "mcp.tool_call.status.request",
        executionWorkspaceId: this.executionWorkspaceId ?? undefined,
        workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
        payload: query,
      });
    } catch {
      this.pendingMcpToolCallStatus.delete(query.taskId);
      return Response.json({
        cloud: cloudView,
        workspace: null,
        reason: "send_failed",
      });
    }
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<null>((resolve) => {
      timer = setTimeout(
        () => resolve(null),
        WorkspaceGateway.MCP_STATUS_TIMEOUT_MS,
      );
    });
    const payload = await Promise.race([answer, timeout]);
    clearTimeout(timer);
    this.pendingMcpToolCallStatus.delete(query.taskId);
    if (!payload)
      return Response.json({
        cloud: cloudView,
        workspace: null,
        reason: "timeout",
      });
    const {
      schemaVersion: _v,
      taskId: _t,
      dispatchKey: _d,
      ...workspace
    } = payload;
    return Response.json({ cloud: cloudView, workspace });
  }

  private async cancelAssignment(request: Request): Promise<Response> {
    if (!(await this.isRuntimeLive()))
      return Response.json({ error: "Workspace is offline" }, { status: 503 });
    const body = (await request.json()) as WorkspaceAssignmentCorrelation & {
      payload: unknown;
    };
    const assignmentId = body.assignmentId;
    if (this.pendingCancelAcks.has(assignmentId))
      return Response.json(
        { error: "Cancellation is already in progress" },
        { status: 409 },
      );
    let timer: ReturnType<typeof setTimeout>;
    const ackPromise = new Promise<Record<string, unknown>>(
      (resolve, reject) => {
        timer = setTimeout(() => {
          this.pendingCancelAcks.delete(assignmentId);
          reject(
            new Error("Timed out waiting for Workspace process cancellation"),
          );
        }, 15_000);
        this.pendingCancelAcks.set(assignmentId, { resolve, timer });
      },
    );
    try {
      await this.send({
        protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
        protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        messageId: `message-${crypto.randomUUID()}`,
        timestamp: new Date().toISOString(),
        type: "assignment.cancel",
        ...body,
        payload: body.payload,
      });
    } catch (error) {
      const pending = this.pendingCancelAcks.get(assignmentId);
      if (pending) {
        clearTimeout(pending.timer);
        this.pendingCancelAcks.delete(assignmentId);
      }
      return Response.json(
        {
          error:
            error instanceof Error
              ? error.message
              : "Cancellation could not be queued",
          retryable: true,
        },
        { status: 503 },
      );
    }
    try {
      const acknowledgement = await ackPromise;
      if (acknowledgement.cancelled !== true)
        return Response.json(
          { cancelled: false, ...acknowledgement },
          { status: 409 },
        );
      return Response.json({ cancelled: true, ...acknowledgement });
    } catch (error) {
      return Response.json(
        {
          error:
            error instanceof Error
              ? error.message
              : "Cancellation was not acknowledged",
        },
        { status: 504 },
      );
    }
  }

  private async requestMcpAction(request: Request): Promise<Response> {
    const body = (await request.json().catch(() => null)) as unknown;
    const parsed = McpActionRequestSchema.safeParse(body);
    if (!parsed.success) {
      return Response.json(
        { error: "Invalid action request", details: parsed.error.issues },
        { status: 400 },
      );
    }
    const action = parsed.data;
    if (!(await this.isRuntimeLive())) {
      return Response.json(
        { error: "Workspace is offline", code: "workspace_offline" },
        { status: 503 },
      );
    }
    if (!(await this.serviceHasCapability(SERVICE_MCP_ACTION_CAPABILITY))) {
      return Response.json(
        {
          error: "Workspace Service does not support MCP management actions",
          code: "unsupported",
        },
        { status: 501 },
      );
    }
    const answer = new Promise<McpActionResult>((resolve) => {
      this.pendingMcpActions.set(action.actionId, {
        resolve,
        workspaceRuntimeId: this.workspaceRuntimeId,
      });
    });
    try {
      await this.send({
        protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
        protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
        messageId: `message-${crypto.randomUUID()}`,
        timestamp: new Date().toISOString(),
        type: "mcp.action.request",
        executionWorkspaceId: this.executionWorkspaceId ?? undefined,
        workspaceRuntimeId: this.workspaceRuntimeId ?? undefined,
        payload: action,
      });
    } catch {
      this.pendingMcpActions.delete(action.actionId);
      return Response.json(
        {
          error: "Failed to deliver action to Workspace Service",
          code: "send_failed",
        },
        { status: 502 },
      );
    }
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<null>((resolve) => {
      timer = setTimeout(
        () => resolve(null),
        WorkspaceGateway.MCP_ACTION_TIMEOUT_MS,
      );
    });
    const outcome = await Promise.race([answer, timeout]);
    if (timer) clearTimeout(timer);
    this.pendingMcpActions.delete(action.actionId);
    if (!outcome) {
      return Response.json(
        {
          error: "Workspace Service timed out answering action",
          code: "timeout",
        },
        { status: 504 },
      );
    }
    return Response.json(outcome);
  }

  private async send(message: Record<string, unknown>): Promise<void> {
    const serialized = serializeWorkspaceRuntimeMessage(message as never);
    if (this.socket) {
      this.socket.send(serialized);
      return;
    }
    if (!this.sessionId || !this.workspaceRuntimeId) return;
    if (this.httpEvents.length >= MAX_WORKSPACE_HTTP_EVENTS) {
      throw new Error("Workspace HTTP event queue is full");
    }
    this.httpLastActivityAt = new Date().toISOString();
    this.httpCursor += 1;
    this.httpEvents.push({
      cursor: this.httpCursor,
      envelope: {
        contract: "syntila.desktop-auth-transport",
        version: "1.0",
        eventId: `srv-${this.httpCursor}`,
        occurredAt: new Date().toISOString(),
        message: JSON.parse(serialized),
      },
    });
    await this.persistHttpRuntime();
    this.httpWaiter?.();
    this.httpWaiter = null;
  }

  private sendError(error: string): void {
    if (this.socket) this.socket.send(JSON.stringify({ error }));
  }
}

/** The bounded reply to the workflow; an unrecorded outcome is unknown. */
function mcpToolCallReply(record: McpToolCallRecord | null) {
  return {
    state: record?.state ?? "unknown",
    code: record?.state ? record.code : "dispatch_already_claimed",
    result: record?.result ?? undefined,
  };
}
