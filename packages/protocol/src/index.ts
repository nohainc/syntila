import {
  EXECUTION_ERROR_CODES,
  EXECUTION_ERROR_MESSAGES,
} from "./generated.js";

export {
  EXECUTION_ERROR_CODES,
  EXECUTION_ERROR_MESSAGES,
} from "./generated.js";
export {
  COLLABORATION_REALTIME_EVENT_TYPES,
  REALTIME_STREAM_KINDS,
} from "./generated.js";
export * from "./realtime-events.js";
export * from "./execution-permissions.js";
export * from "./worker-descriptor.js";
export * from "./diagnostic-events.js";
export * from "./execution-events.js";
export * from "./execution-activity.js";
export * from "./api-requests.js";
export * from "./worker-instance.js";
export * from "./worker-agent.js";
export * from "./provider-failure.js";
// zod's types for consumers that type a schema parameter (the backend does not
// depend on zod itself).
export type { z } from "zod";

export type ExecutionErrorCode = (typeof EXECUTION_ERROR_CODES)[number];

export function isExecutionErrorCode(
  value: unknown,
): value is ExecutionErrorCode {
  return (
    typeof value === "string" &&
    (EXECUTION_ERROR_CODES as readonly string[]).includes(value)
  );
}

export function canonicalExecutionErrorCode(
  value: unknown,
): ExecutionErrorCode {
  // These fixed Syntila errors can already be stored on tasks that failed
  // before assignment creation. Never expose arbitrary diagnostic text.
  if (
    typeof value === "string" &&
    [
      "Context exceeds the byte limit",
      "Conversation bootstrap exceeds the history or byte limit",
      "Conversation bootstrap exceeds the history limit",
      "Conversation bootstrap exceeds the byte limit",
      "This conversation exceeds the supported context limit. Clear AI History and retry; the latest answer is kept as context.",
    ].includes(value)
  )
    return "context_limit_exceeded";
  return isExecutionErrorCode(value) ? value : "execution_failed";
}

export function executionErrorMessage(code: ExecutionErrorCode): string {
  return EXECUTION_ERROR_MESSAGES[code];
}
