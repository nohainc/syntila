// GENERATED FILE. Do not edit by hand.

export const WORKER_AGENT_PROTOCOL_SCHEMA_NAME =
  "syntila.worker-agent-protocol" as const;
export const WORKER_AGENT_PROTOCOL_SCHEMA_VERSION = "5.1" as const;
export const WORKER_AGENT_PROTOCOL_SCHEMA_MAX_MESSAGE_SIZE_BYTES =
  4194304 as const;
export const WORKER_AGENT_PROTOCOL_SCHEMA_MESSAGE_TYPES = [
  "agent.hello",
  "agent.hello.ack",
  "agent.heartbeat",
  "agent.heartbeat.ack",
  "agent.sync.request",
  "agent.sync.result",
  "agent.status",
  "agent.readiness",
  "agent.update",
  "worker.inventory",
  "thread.status",
  "assignment.start",
  "assignment.start.ack",
  "assignment.startup",
  "assignment.start.permit.request",
  "assignment.start.permit.grant",
  "assignment.ack",
  "assignment.activity",
  "assignment.result",
  "assignment.error",
  "assignment.cancel",
  "assignment.cancel.ack",
  "assignment.cancelled",
  "diagnostic.probe",
  "diagnostic.probe.ack",
  "worker.usage.request",
  "worker.usage.result",
  "mcp.tool_call.request",
  "mcp.tool_call.result",
  "mcp.tool_call.status.request",
  "mcp.tool_call.status.result",
  "mcp.inventory",
  "input.available",
] as const;
export const WORKER_AGENT_PROTOCOL_SCHEMA_BASE_ENVELOPE_FIELDS = [
  "protocol",
  "protocolVersion",
  "messageId",
  "correlationId",
  "timestamp",
  "type",
  "payload",
] as const;
export const WORKER_AGENT_PROTOCOL_SCHEMA_ASSIGNMENT_ENVELOPE_FIELDS = [
  "workerId",
  "runId",
  "taskId",
  "attemptId",
  "assignmentId",
  "idempotencyKey",
] as const;
