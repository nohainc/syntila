// GENERATED FILE. Do not edit by hand.

export const WORKSPACE_RUNTIME_PROTOCOL_SCHEMA_NAME =
  "syntila.workspace-runtime-protocol" as const;
export const WORKSPACE_RUNTIME_PROTOCOL_SCHEMA_VERSION = "5.1" as const;
export const WORKSPACE_RUNTIME_PROTOCOL_SCHEMA_MAX_MESSAGE_SIZE_BYTES =
  4194304 as const;
export const WORKSPACE_RUNTIME_PROTOCOL_SCHEMA_MESSAGE_TYPES = [
  "workspace.hello",
  "workspace.hello.ack",
  "workspace.heartbeat",
  "workspace.heartbeat.ack",
  "workspace.sync.request",
  "workspace.sync.result",
  "workspace.status",
  "workspace.readiness",
  "workspace.update",
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
export const WORKSPACE_RUNTIME_PROTOCOL_SCHEMA_BASE_ENVELOPE_FIELDS = [
  "protocol",
  "protocolVersion",
  "messageId",
  "correlationId",
  "timestamp",
  "type",
  "payload",
] as const;
export const WORKSPACE_RUNTIME_PROTOCOL_SCHEMA_ASSIGNMENT_ENVELOPE_FIELDS = [
  "executionWorkspaceId",
  "workspaceRuntimeId",
  "workerId",
  "runId",
  "taskId",
  "attemptId",
  "assignmentId",
  "idempotencyKey",
] as const;
