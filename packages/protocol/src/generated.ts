// GENERATED FILE. Do not edit by hand.

export const EXECUTION_ERROR_CODES = [
  "worker_not_ready",
  "cli_not_found",
  "authentication_required",
  "unsupported_cli_version",
  "model_not_supported",
  "permission_denied",
  "space_folder_exists",
  "quota_exhausted",
  "provider_unavailable",
  "timeout",
  "cancelled",
  "execution_failed",
  "context_limit_exceeded",
  "additional_folders_unsupported",
] as const;
export const EXECUTION_ERROR_MESSAGES = {
  worker_not_ready: "The selected Worker is not ready on its Workspace.",
  cli_not_found: "The required local CLI could not be found.",
  authentication_required:
    "Sign in to the configured provider on this computer.",
  unsupported_cli_version: "The installed local CLI version is not supported.",
  model_not_supported: "The selected model is not supported by this Worker.",
  permission_denied:
    "A local permission required for this assignment was denied.",
  space_folder_exists:
    "A folder with this Space's name already exists on the Workspace and is not empty. Confirm to use it.",
  quota_exhausted: "The provider's usage limit has been reached.",
  provider_unavailable: "The provider is temporarily unavailable.",
  timeout: "The assignment exceeded its time limit.",
  cancelled: "The assignment was cancelled.",
  execution_failed: "The assignment could not be completed.",
  context_limit_exceeded:
    "This conversation exceeds the supported context limit. Clear AI History and retry; the latest answer is kept as context.",
  additional_folders_unsupported:
    "This Worker cannot use the Space's additional folders yet. Detach the additional folders or choose another Worker.",
} as const;

export const REALTIME_EVENTS_NAME = "syntila.realtime-events" as const;
export const REALTIME_EVENTS_VERSION = "1.1" as const;
export const REALTIME_EVENT_ENVELOPE_FIELDS = [
  "eventId",
  "type",
  "version",
  "timestamp",
  "sequence",
  "payload",
] as const;
export const REALTIME_EVENT_OPTIONAL_ENVELOPE_FIELDS = [
  "spaceId",
  "runId",
  "taskId",
  "assignmentId",
  "threadId",
  "attemptId",
  "workspaceRuntimeId",
  "workspaceId",
  "stream",
] as const;
export const REALTIME_STREAM_KINDS = [
  "execution_workspace",
  "space",
  "user",
] as const;
export const COLLABORATION_REALTIME_EVENT_TYPES = [
  "space.created",
  "space.updated",
  "space.archived",
  "space.deleted",
  "thread.created",
  "thread.updated",
  "thread.deleted",
  "thread.work_cleared",
  "thread.chat_cleared",
  "thread.queue_updated",
  "thread.read",
  "discussion.created",
  "discussion.updated",
  "discussion.deleted",
  "workspace_space_grant.updated",
  "people.updated",
  "workspace_invitation.updated",
] as const;
export const DURABLE_REALTIME_EVENT_TYPES = [
  "work_request.created",
  "work_request.started",
  "work_request.input_updated",
  "work_request.completed",
  "work_request.failed",
  "work_request.cancelled",
  "step.queued",
  "step.running",
  "step.completed",
  "step.failed",
  "step.cancelled",
  "step.phase",
  "run.started",
  "run.paused",
  "run.resumed",
  "run.completed",
  "run.failed",
  "assignment.accepted",
  "assignment.completed",
  "assignment.failed",
  "assignment.cancelled",
  "artifact.created",
  "space.created",
  "space.updated",
  "space.archived",
  "space.deleted",
  "thread.created",
  "thread.updated",
  "thread.deleted",
  "thread.work_cleared",
  "thread.chat_cleared",
  "thread.queue_updated",
  "thread.read",
  "discussion.created",
  "discussion.updated",
  "discussion.deleted",
  "workspace_space_grant.updated",
  "people.updated",
  "workspace_invitation.updated",
] as const;
export const EPHEMERAL_REALTIME_EVENT_TYPES = [
  "assignment.activity",
  "stream.delta",
  "tool.invocation.status",
  "heartbeat",
] as const;
