import { buildEnvelope, MESSAGING_PROTOCOL, type CommandFrame, type MessagingEnvelope } from "./envelope.js";

/**
 * Translates unified commands to the Worker Agent message handlers (ADR-038).
 */
const COMMAND_OF_LEGACY: Record<string, string> = {
  "agent.hello": "session.hello",
  "agent.heartbeat": "session.heartbeat",
  "agent.sync.request": "session.sync",
  "assignment.ack": "assignment.ack",
  "assignment.start.ack": "assignment.start.ack",
  "assignment.activity": "assignment.activity",
  "assignment.start.permit.request": "assignment.start.permit",
  "assignment.result": "assignment.result",
  "assignment.error": "assignment.error",
  "assignment.cancelled": "assignment.cancelled",
  "assignment.cancel.ack": "assignment.cancel.ack",
};
const LEGACY_OF_COMMAND = Object.fromEntries(Object.entries(COMMAND_OF_LEGACY).map(([k, v]) => [v, k]));

/** Identifiers the legacy envelope carries at its top level. */
const ASSIGNMENT_FIELDS = ["assignmentId", "runId", "taskId", "attemptId", "idempotencyKey", "workerId"] as const;

export function isBridgedCommand(command: string): boolean {
  return command in LEGACY_OF_COMMAND;
}

/** A unified command becomes the legacy message the Worker handlers already process. */
export function commandToLegacy(frame: CommandFrame, workerScope: string, legacy: { protocolName: string; protocolVersion: string }): Record<string, unknown> {
  const type = LEGACY_OF_COMMAND[frame.command];
  if (!type) throw new Error(`Unknown command: ${frame.command}`);
  const { payload } = frame;
  const top: Record<string, unknown> = {};
  const rest: Record<string, unknown> = { ...payload };
  for (const key of ASSIGNMENT_FIELDS) if (key in payload) { top[key] = payload[key]; delete rest[key]; }
  const body = type === "assignment.activity" && rest.activity && typeof rest.activity === "object" && !Array.isArray(rest.activity)
    ? rest.activity : rest;
  return {
    protocol: legacy.protocolName,
    protocolVersion: legacy.protocolVersion,
    messageId: frame.requestId,
    timestamp: new Date().toISOString(),
    type,
    ...top,
    payload: body,
  };
}

/** A legacy outbound frame becomes a unified envelope on the Worker's own inbox. */
export function legacyToEnvelope(message: Record<string, unknown>, workerId: string): MessagingEnvelope {
  const payload: Record<string, unknown> = { ...((message.payload as Record<string, unknown> | undefined) ?? {}) };
  for (const key of ASSIGNMENT_FIELDS) if (message[key] !== undefined) payload[key] = message[key];
  const legacyType = String(message.type ?? "");
  const assignmentId = typeof message.assignmentId === "string" ? message.assignmentId : null;
  return buildEnvelope({
    eventId: typeof message.messageId === "string" ? message.messageId : undefined,
    occurredAt: typeof message.timestamp === "string" ? message.timestamp : undefined,
    type: COMMAND_OF_LEGACY[legacyType] ?? legacyType,
    stream: assignmentId ? { kind: "assignment", id: assignmentId } : { kind: "worker_inbox", id: workerId },
    actor: { kind: "system", id: "gateway" },
    ...(typeof message.correlationId === "string" ? { correlationId: message.correlationId } : {}),
    payload,
  });
}

export { MESSAGING_PROTOCOL };
