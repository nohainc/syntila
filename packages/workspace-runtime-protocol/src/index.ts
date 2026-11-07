import type { ExecutionErrorCode } from "@syntila/protocol";

export * from "./workspace-runtime.js";
export * from "./desktop-auth-transport.js";
export * from "./mcp-tool-call.js";
export * from "./mcp-inventory.js";
export * from "./mcp-action.js";

/** Assignment completion payloads consumed by Cloud's state transition layer. */
export interface AssignmentResultPayload {
  readonly assignmentId: string;
  readonly status: "completed" | "failed" | "cancelled";
  readonly output: Record<string, unknown> | null;
  readonly findings?: readonly unknown[];
  readonly artifactIds: readonly string[];
  readonly evidence?: {
    readonly observedAt: string;
    readonly metrics?: Record<string, unknown>;
    readonly logs?: readonly string[];
  };
  readonly completedAt: string;
}

export interface AssignmentFailurePayload {
  readonly error: {
    readonly code: ExecutionErrorCode;
    readonly message: string;
    readonly retryable: boolean;
    /** Private, bounded diagnostics for issue reports; never user-facing. */
    readonly details?: {
      readonly diagnostic?: string;
      readonly processExitCode?: number;
    };
  };
  readonly failedAt: string;
}

export interface AssignmentCancelPayload {
  readonly assignmentId: string;
  readonly reason: string;
  /**
   * Stable identity of this revocation. Every re-send of the same cancel
   * carries the same value so the Service can deduplicate and record it.
   */
  readonly commandId?: string;
  readonly deadlineMs?: number;
}
export * from "./worker-plugin.js";
