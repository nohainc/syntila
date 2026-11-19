import { dataOf } from "../platform/data.js";
import { assignmentStatus } from "./queries.js";
import {
  parseWorkspaceRuntimeMessage,
  serializeWorkspaceRuntimeMessage,
  WORKSPACE_RUNTIME_PROTOCOL_NAME,
  WORKSPACE_RUNTIME_PROTOCOL_VERSION,
  type AssignmentCancelPayload,
  type WorkspaceRuntimeMessage,
} from "@syntila/workspace-runtime-protocol";
import { assignmentStatusForEvidence, ASSIGNMENT_ACTIVE_STATUSES } from "@syntila/core";
import { extractBearerToken } from "@syntila/security";
import { signalAssignmentTerminal } from "./assignment-workflow-signal.js";
import { publishAssignmentPhase } from "./assignment-phase-events.js";
import { assignmentCommandDisposition } from "./assignment-delivery.js";
import { grantStartPermit } from "./assignment-start-permit.js";
import { finalizeAssignmentRevocation } from "./assignment-revocation.js";
import { ACTIVE_ASSIGNMENT_STATUS_SQL, transitionAssignment } from "./assignment-transitions.js";
import { recordAssignmentCancelled, recordAssignmentError, recordAssignmentResult } from "./assignment-dispatcher.js";
import { agentFenceIsCurrent, type AgentSessionFence } from "./agent-session-fence.js";
import { AgentLeaseKeeper, authenticateAgentSession, closeSession as closeAgentSession } from "./worker-agents.js";
import { isFeatureEnabled } from "../feature-flags.js";
import { logStructured, requestIdFor, tryLogDiagnosticEvent } from "./observability.js";
import type { WorkspaceGatewayEnv } from "./workspace-gateway/contracts.js";

/**
 * The gateway of one Worker's Agent (ADR-035, ADR-034). One object per Worker,
 * named `worker:<workerId>`; no Workspace is involved.
 *
 * It speaks the Agent's side of the existing wire protocol (hello, sync,
 * heartbeat, assignment lifecycle) and nothing else: no Workspace readiness,
 * inventory, usage or MCP. Authority is the Agent session fence, checked inside
 * every write. A message that names an assignment must name one of THIS
 * Worker's Worker-path assignments with matching identifiers; anything else is
 * ignored.
 *
 * The protocol's assignment envelope requires `executionWorkspaceId` and
 * `workspaceRuntimeId`. Here both carry the Worker scope (`worker:<id>`): a
 * correlation token the Agent echoes back, never an identity and never stored.
 */

/** Messages an Agent may send. Everything else is ignored. */
const AGENT_TYPES = new Set<string>([
  "workspace.hello",
  "workspace.heartbeat",
  "workspace.sync.request",
  "assignment.ack",
  "assignment.start.ack",
  "assignment.start.permit.request",
  "assignment.result",
  "assignment.error",
  "assignment.cancelled",
  "assignment.cancel.ack",
]);

const HEARTBEAT_INTERVAL_MS = 15_000;
const CANCEL_ACK_TIMEOUT_MS = 15_000;
const TERMINAL_RECENT_MS = 24 * 60 * 60 * 1000;

export const workerScope = (workerId: string): string => `worker:${workerId}`;

interface Attachment {
  workerId: string;
  sessionId: string;
  fence: AgentSessionFence;
}

interface AssignmentRow {
  id: string;
  run_id: string;
  task_id: string;
  attempt_id: string;
  idempotency_key: string;
  status: string;
  command_payload_json: string | null;
}

function withStartPermit(payload: unknown): unknown {
  if (!payload || typeof payload !== "object") return payload;
  const value = payload as { snapshot?: unknown };
  if (!value.snapshot || typeof value.snapshot !== "object") return payload;
  return { ...value, snapshot: { ...value.snapshot, startPermit: { required: true } } };
}

export class WorkerGateway implements DurableObject {
  private socket: WebSocket | null = null;
  private attachment: Attachment | null = null;
  private readonly leaseKeeper: AgentLeaseKeeper;
  private readonly pendingCancelAcks = new Map<
    string,
    { resolve: (payload: Record<string, unknown>) => void; timer: ReturnType<typeof setTimeout> }
  >();
  private readonly delivering = new Set<string>();

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: WorkspaceGatewayEnv,
  ) {
    this.leaseKeeper = new AgentLeaseKeeper(env as never);
  }

  /** Learned from the connection (the object name is not relied on). */
  private knownWorkerId: string | null = null;

  private get workerId(): string {
    return this.knownWorkerId ?? this.attachment?.fence.workerInstanceId ?? "";
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    this.restore();
    if (request.headers.get("Upgrade")?.toLowerCase() === "websocket") return this.acceptAgent(request, url);
    if (request.method === "GET" && url.pathname === "/status") {
      return Response.json({ online: this.socket !== null, sessionId: this.attachment?.sessionId ?? null });
    }
    if (request.method === "POST" && url.pathname === "/dispatch-assignment") return this.dispatch(request);
    if (request.method === "POST" && url.pathname === "/cancel-assignment") return this.cancel(request);
    if (request.method === "POST" && url.pathname === "/disconnect") {
      try {
        this.socket?.close(1000, "Worker disconnected");
      } catch {
        // Already closed.
      }
      return Response.json({ disconnected: this.socket !== null });
    }
    return Response.json({ error: "Not found" }, { status: 404 });
  }

  /** After hibernation the in-memory socket is gone; the attachment survives. */
  private restore(): void {
    if (this.socket) return;
    for (const socket of this.state.getWebSockets?.() ?? []) {
      const attached = socket.deserializeAttachment() as Attachment | null;
      if (attached?.sessionId && attached.fence && socket.readyState === WebSocket.OPEN) {
        this.socket = socket;
        this.attachment = attached;
        this.knownWorkerId = attached.workerId;
        return;
      }
    }
  }

  private async acceptAgent(request: Request, url: URL): Promise<Response> {
    const correlationId = requestIdFor(request);
    const token = extractBearerToken(request.headers);
    const sessionId = url.searchParams.get("workerSessionId");
    const claimedWorker = url.searchParams.get("workerId");
    if (!isFeatureEnabled("worker_agent_connect") || !isFeatureEnabled("worker_target_dispatch")) {
      return Response.json({ error: "Not found" }, { status: 404 });
    }
    if (!token || !sessionId || !claimedWorker) {
      return Response.json({ error: "workerId, workerSessionId and a session token are required" }, { status: 401 });
    }
    let principal;
    try {
      principal = await authenticateAgentSession(this.env as never, { workerId: claimedWorker, sessionId, sessionToken: token });
    } catch {
      principal = null;
    }
    if (!principal) {
      logStructured("warn", "WGW-01 agent_authentication_failed", { requestId: correlationId }, { workerId: claimedWorker });
      return Response.json({ error: "Invalid or expired Worker session" }, { status: 401 });
    }
    // A second connection of the same session replaces the first one.
    if (this.socket) {
      try {
        this.socket.close(1000, "Superseded by new connection");
      } catch {
        // Fenced by the session epoch anyway.
      }
    }
    const fence: AgentSessionFence = { workerInstanceId: principal.workerInstanceId, sessionId: principal.sessionId, epoch: principal.epoch };
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.knownWorkerId = claimedWorker;
    this.attachment = { workerId: claimedWorker, sessionId: principal.sessionId, fence };
    server.serializeAttachment(this.attachment);
    this.state.acceptWebSocket(server);
    this.socket = server;
    this.leaseKeeper.begin(fence);
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(socket: WebSocket, data: string | ArrayBuffer): void {
    const attached = socket.deserializeAttachment() as Attachment | null;
    if (!attached) return;
    this.socket = socket;
    this.attachment = attached;
    this.knownWorkerId = attached.workerId;
    void this.handle(data).catch((error: unknown) =>
      logStructured("error", "WGW-02 agent_message_failed", {}, { error: error instanceof Error ? error.message : String(error) }),
    );
  }

  webSocketClose(socket: WebSocket): void {
    void this.ended(socket);
  }

  webSocketError(socket: WebSocket): void {
    void this.ended(socket);
  }

  private async ended(socket: WebSocket): Promise<void> {
    const attached = (socket.deserializeAttachment() as Attachment | null) ?? this.attachment;
    if (this.socket === socket) {
      this.socket = null;
      this.attachment = null;
    }
    if (!attached) return;
    this.leaseKeeper.end(attached.fence);
    // Ends only this session (matched by id and epoch); a newer one is untouched.
    await closeAgentSession(this.env as never, attached.fence).catch(() => undefined);
  }

  private get fence(): AgentSessionFence | null {
    return this.attachment?.fence ?? null;
  }

  private row(assignmentId: string): Promise<AssignmentRow | null> {
    return dataOf(this.env).read.row<AssignmentRow>`SELECT id, run_id, task_id, attempt_id, idempotency_key, status, command_payload_json
       FROM worker_assignments
      WHERE id = ${assignmentId} AND worker_instance_id = ${this.workerId} AND execution_path = 'worker'`;
  }

  /** The Worker-path assignment this message names, or null when it is not ours. */
  private async owned(message: WorkspaceRuntimeMessage): Promise<AssignmentRow | null> {
    if (!message.assignmentId || message.workerId !== this.workerId) return null;
    const row = await this.row(message.assignmentId);
    if (
      !row ||
      message.runId !== row.run_id ||
      message.taskId !== row.task_id ||
      message.attemptId !== row.attempt_id ||
      message.idempotencyKey !== row.idempotency_key
    ) {
      return null;
    }
    return row;
  }

  private async handle(data: string | ArrayBuffer): Promise<void> {
    let message: WorkspaceRuntimeMessage;
    try {
      message = parseWorkspaceRuntimeMessage(typeof data === "string" ? JSON.parse(data) : data);
    } catch (error) {
      this.socket?.send(JSON.stringify({ error: error instanceof Error ? error.message : "Invalid protocol message" }));
      return;
    }
    if (!AGENT_TYPES.has(message.type)) return;
    const fence = this.fence;
    if (!fence) return;
    const now = new Date().toISOString();
    const payload = (message.payload ?? {}) as Record<string, unknown>;
    switch (message.type) {
      case "workspace.hello":
        await this.reply(message, "workspace.hello.ack", {
          sessionId: fence.sessionId,
          heartbeatIntervalMs: HEARTBEAT_INTERVAL_MS,
          serverTime: now,
          cloudCapabilities: [],
        });
        return;
      case "workspace.heartbeat":
        if ((await this.leaseKeeper.touch(fence)) === "lost") {
          this.socket?.close(1008, "Worker session superseded");
          return;
        }
        await this.reply(message, "workspace.heartbeat.ack", { acknowledged: true, serverTime: now });
        return;
      case "workspace.sync.request":
        await this.sync(message);
        return;
      case "assignment.ack": {
        // Terminal acknowledgements are Cloud's; they never move an assignment.
        if (payload.terminal === true) return;
        const row = await this.owned(message);
        if (!row) return;
        if ((payload.accepted ?? payload.status === "accepted") === true) {
          const moved = await transitionAssignment(dataOf(this.env).read, {
            to: assignmentStatusForEvidence("admission"),
            now,
            fence: { assignmentId: row.id, attemptId: row.attempt_id, agent: fence },
          });
          if (moved.applied) await publishAssignmentPhase(this.env, row.id);
        } else {
          await recordAssignmentError(
            this.env.SYNTILA_DB,
            row.id,
            {
              error: { code: "worker_not_ready", message: "The Worker was not ready to accept the assignment.", retryable: true },
              failedAt: now,
            },
            row.attempt_id,
            { onlyFrom: ["created", "dispatched"], agent: fence },
          );
        }
        return;
      }
      case "assignment.start.ack": {
        const row = await this.owned(message);
        if (!row) return;
        const moved = await transitionAssignment(dataOf(this.env).read, {
          to: assignmentStatusForEvidence("provider_start"),
          now,
          startTaskId: row.task_id,
          fence: { assignmentId: row.id, attemptId: row.attempt_id, agent: fence },
        });
        if (moved.applied) await publishAssignmentPhase(this.env, row.id);
        return;
      }
      case "assignment.start.permit.request": {
        const row = await this.owned(message);
        if (!row) return;
        const decision = await grantStartPermit(dataOf(this.env).read, {
          assignmentId: row.id,
          attemptId: row.attempt_id,
          agent: fence,
        });
        tryLogDiagnosticEvent({
          assignmentId: row.id,
          workerId: this.workerId,
          runId: row.run_id,
          taskId: row.task_id,
          attemptId: row.attempt_id,
          component: "cloud",
          operation: "assignment",
          stage: "start_permit",
          severity: decision.granted ? "info" : "warning",
          retryable: false,
          context: { status: decision.granted ? "granted" : `denied_${(decision as { reason: string }).reason}` },
        });
        await this.reply(
          message,
          "assignment.start.permit.grant",
          decision.granted
            ? { granted: true, permitId: decision.permitId, expiresAt: decision.expiresAt }
            : { granted: false, reason: (decision as { reason: string }).reason },
        );
        if (decision.granted) await publishAssignmentPhase(this.env, row.id);
        return;
      }
      case "assignment.result": {
        const row = await this.owned(message);
        if (!row) return;
        const done = await recordAssignmentResult(this.env.SYNTILA_DB, row.id, message.payload as never, row.attempt_id, fence);
        // A result from a session that is no longer current is not acknowledged.
        if (!done && (await this.stale())) return;
        await this.terminalAck(message, row, "completed");
        return;
      }
      case "assignment.error": {
        const row = await this.owned(message);
        if (!row) return;
        const failed = await recordAssignmentError(this.env.SYNTILA_DB, row.id, message.payload as never, row.attempt_id, {
          providerFailureKey: this.env.SYNTILA_PROVIDER_FAILURE_KEY,
          agent: fence,
        });
        if (failed) await publishAssignmentPhase(this.env, row.id);
        if (!failed && (await this.stale())) return;
        await this.terminalAck(message, row, "failed");
        return;
      }
      case "assignment.cancelled": {
        const row = await this.owned(message);
        if (!row) return;
        await this.cancellationEvidence(row, message.payload as never);
        await this.terminalAck(message, row, "cancelled");
        return;
      }
      case "assignment.cancel.ack": {
        const row = await this.owned(message);
        if (!row) return;
        if (payload.cancelled === true) {
          const recorded = await this.cancellationEvidence(row, {
            status: "cancelled",
            reason: typeof payload.reason === "string" ? payload.reason : "Cancelled by the Worker Agent",
          });
          if (recorded) await signalAssignmentTerminal(this.env, row.id);
        }
        const pending = this.pendingCancelAcks.get(row.id);
        if (pending) {
          clearTimeout(pending.timer);
          this.pendingCancelAcks.delete(row.id);
          pending.resolve(payload);
        }
        return;
      }
      default:
        return;
    }
  }

  /** True (and the socket is closed) when this session is no longer the Worker's current one. */
  private async stale(): Promise<boolean> {
    const fence = this.fence;
    if (!fence || (await agentFenceIsCurrent(dataOf(this.env).read, fence))) return false;
    try {
      this.socket?.close(1008, "Worker session superseded");
    } catch {
      // Already closed.
    }
    return true;
  }

  /** Cancellation evidence: finish a revocation Cloud started, else an ordinary cancel. */
  private async cancellationEvidence(row: AssignmentRow, cancellation: { status: "cancelled"; reason: string }): Promise<boolean> {
    if (await this.stale()) return false;
    const finalized = await finalizeAssignmentRevocation(this.env.SYNTILA_DB, row.id, row.attempt_id);
    if (finalized === "finalized") return true;
    if (finalized !== "not_revoking") return false;
    return recordAssignmentCancelled(this.env.SYNTILA_DB, row.id, cancellation, row.attempt_id, { agent: this.fence ?? undefined });
  }

  private correlation(row: Pick<AssignmentRow, "id" | "run_id" | "task_id" | "attempt_id" | "idempotency_key">) {
    return {
      executionWorkspaceId: workerScope(this.workerId),
      workspaceRuntimeId: workerScope(this.workerId),
      workerId: this.workerId,
      runId: row.run_id,
      taskId: row.task_id,
      attemptId: row.attempt_id,
      assignmentId: row.id,
      idempotencyKey: row.idempotency_key,
    };
  }

  private async terminalAck(message: WorkspaceRuntimeMessage, row: AssignmentRow, status: "completed" | "failed" | "cancelled"): Promise<void> {
    const current = await assignmentStatus(dataOf(this.env).read, row.id);
    const authoritative =
      current?.status === "completed" || current?.status === "failed" || current?.status === "cancelled"
        ? current.status
        : current?.status === "timed_out"
          ? "failed"
          : status;
    await this.send({
      ...this.envelope("assignment.ack", message.messageId),
      ...this.correlation(row),
      payload: { accepted: true, terminal: true, status: authoritative },
    });
    // The Workflow is told only after the result is durable and acknowledged. A
    // lost signal is recovered by the outbox sweep and the waiter's own check.
    await signalAssignmentTerminal(this.env, row.id);
  }

  private envelope(type: string, correlationId?: string) {
    return {
      protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
      protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
      messageId: `message-${crypto.randomUUID()}`,
      ...(correlationId ? { correlationId } : {}),
      timestamp: new Date().toISOString(),
      type,
    };
  }

  private reply(message: WorkspaceRuntimeMessage, type: string, payload: Record<string, unknown>): Promise<void> {
    const assignment = message.assignmentId
      ? {
          executionWorkspaceId: workerScope(this.workerId),
          workspaceRuntimeId: workerScope(this.workerId),
          workerId: message.workerId,
          runId: message.runId,
          taskId: message.taskId,
          attemptId: message.attemptId,
          assignmentId: message.assignmentId,
          idempotencyKey: message.idempotencyKey,
        }
      : { executionWorkspaceId: workerScope(this.workerId), workspaceRuntimeId: workerScope(this.workerId) };
    return this.send({ ...this.envelope(type, message.messageId), ...assignment, payload });
  }

  private async send(message: Record<string, unknown>): Promise<void> {
    if (!this.socket) throw new Error("Worker is offline");
    this.socket.send(serializeWorkspaceRuntimeMessage(message as never));
  }

  /**
   * The Agent's authoritative state: this Worker's live assignments and the
   * ones that ended in the last day, then the commands it may have missed.
   */
  private async sync(message: WorkspaceRuntimeMessage): Promise<void> {
    const read = dataOf(this.env).read;
    const since = new Date(Date.now() - TERMINAL_RECENT_MS).toISOString();
    const rows = await read.rows<{ id: string; status: string }>`SELECT id, status FROM worker_assignments
       WHERE worker_instance_id = ${this.workerId} AND execution_path = 'worker'
         AND (status IN (${read.raw(ACTIVE_ASSIGNMENT_STATUS_SQL)})
              OR (status IN ('completed', 'failed', 'cancelled', 'timed_out') AND updated_at >= ${since}::timestamptz))
       ORDER BY updated_at DESC LIMIT 500`;
    const active = new Set<string>(ASSIGNMENT_ACTIVE_STATUSES);
    await this.reply(message, "workspace.sync.result", {
      activeAssignmentIds: rows.filter((row) => active.has(row.status)).map((row) => row.id),
      assignmentStates: rows.map((row) => ({ assignmentId: row.id, status: row.status })),
    });
    await this.resendRevocations().catch(() => undefined);
    await this.resendUnacknowledged().catch(() => undefined);
  }

  /** A revocation the Agent may have missed while offline must still reach it. */
  private async resendRevocations(): Promise<void> {
    const rows = await dataOf(this.env).read.rows<AssignmentRow & { error_json: string | null }>`SELECT id, run_id, task_id, attempt_id, idempotency_key, status,
              command_payload_json, error_json::text AS error_json
         FROM worker_assignments
        WHERE worker_instance_id = ${this.workerId} AND execution_path = 'worker'
          AND status IN ('revocation_pending', 'reconciling') LIMIT 100`;
    for (const row of rows) {
      let reason = "Cloud revoked the assignment";
      let commandId = `revoke:${row.id}:${row.attempt_id}`;
      try {
        const stored = JSON.parse(row.error_json ?? "{}") as { revocation?: { reason?: unknown; commandId?: unknown } };
        if (typeof stored.revocation?.reason === "string") reason = stored.revocation.reason;
        if (typeof stored.revocation?.commandId === "string") commandId = stored.revocation.commandId;
      } catch {
        // Keep the defaults; the command is safe to send again.
      }
      await this.send({
        ...this.envelope("assignment.cancel"),
        ...this.correlation(row),
        payload: { assignmentId: row.id, reason, commandId, deadlineMs: Date.now() + 10_000 } satisfies AssignmentCancelPayload,
      });
    }
  }

  /** Commands persisted but not yet accepted: the Agent's journal drops duplicates. */
  private async resendUnacknowledged(): Promise<void> {
    const rows = await dataOf(this.env).read.rows<AssignmentRow>`SELECT id, run_id, task_id, attempt_id, idempotency_key, status, command_payload_json
         FROM worker_assignments
        WHERE worker_instance_id = ${this.workerId} AND execution_path = 'worker'
          AND status IN ('created', 'dispatched') AND command_payload_json IS NOT NULL
        ORDER BY created_at, id LIMIT 25`;
    for (const row of rows) {
      await this.deliver(row, JSON.parse(String(row.command_payload_json)));
    }
  }

  /**
   * Sends one start command. The `created -> dispatched` claim is written
   * before the command can exist, so from then on Cloud treats the Agent as
   * possibly holding it and every later stop goes through revocation.
   */
  private async deliver(row: AssignmentRow, payload: unknown): Promise<{ delivered: boolean; offline?: boolean; status?: string }> {
    if (!this.socket || !this.fence) return { delivered: false, offline: true };
    if (this.delivering.has(row.id)) return { delivered: false, status: row.status };
    this.delivering.add(row.id);
    try {
      const disposition = assignmentCommandDisposition(row.status);
      if (!disposition.shouldSend) return { delivered: false, status: row.status };
      const message = parseWorkspaceRuntimeMessage({
        ...this.envelope("assignment.start"),
        ...this.correlation(row),
        payload: withStartPermit(payload),
      });
      if (row.status === "created") {
        const claim = await transitionAssignment(dataOf(this.env).read, {
          to: "dispatched",
          onlyFrom: ["created"],
          fence: { assignmentId: row.id, attemptId: row.attempt_id, agent: this.fence },
        });
        if (!claim.applied && claim.outcome !== "duplicate") return { delivered: false, status: claim.currentStatus };
      }
      await this.send({ ...message });
      return { delivered: true };
    } finally {
      this.delivering.delete(row.id);
    }
  }

  private async dispatch(request: Request): Promise<Response> {
    const body = (await request.json().catch(() => null)) as { assignmentId?: string; payload?: unknown } | null;
    if (!body?.assignmentId) return Response.json({ error: "assignmentId is required" }, { status: 400 });
    const row = await this.row(body.assignmentId);
    if (!row) return Response.json({ error: "Assignment is not valid for this Worker" }, { status: 409 });
    // No live Agent: nothing was sent. The caller turns this into worker_offline.
    if (!this.socket) return Response.json({ delivered: false, offline: true });
    try {
      return Response.json(await this.deliver(row, body.payload));
    } catch {
      return Response.json({ error: "Command could not be sent" }, { status: 502 });
    }
  }

  private async cancel(request: Request): Promise<Response> {
    if (!this.socket) return Response.json({ error: "Worker is offline" }, { status: 503 });
    const body = (await request.json().catch(() => null)) as { assignmentId?: string; payload?: unknown } | null;
    if (!body?.assignmentId) return Response.json({ error: "assignmentId is required" }, { status: 400 });
    const row = await this.row(body.assignmentId);
    if (!row) return Response.json({ error: "Assignment is not valid for this Worker" }, { status: 409 });
    if (this.pendingCancelAcks.has(row.id)) return Response.json({ error: "Cancellation is already in progress" }, { status: 409 });
    const acknowledged = new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingCancelAcks.delete(row.id);
        reject(new Error("Timed out waiting for the Agent to stop the assignment"));
      }, CANCEL_ACK_TIMEOUT_MS);
      this.pendingCancelAcks.set(row.id, { resolve, timer });
    });
    try {
      await this.send({ ...this.envelope("assignment.cancel"), ...this.correlation(row), payload: body.payload });
    } catch {
      const pending = this.pendingCancelAcks.get(row.id);
      if (pending) {
        clearTimeout(pending.timer);
        this.pendingCancelAcks.delete(row.id);
      }
      return Response.json({ error: "Cancellation could not be sent", retryable: true }, { status: 503 });
    }
    try {
      const answer = await acknowledged;
      return answer.cancelled === true ? Response.json({ cancelled: true, ...answer }) : Response.json({ cancelled: false, ...answer }, { status: 409 });
    } catch (error) {
      return Response.json({ error: error instanceof Error ? error.message : "Cancellation was not acknowledged" }, { status: 504 });
    }
  }
}

