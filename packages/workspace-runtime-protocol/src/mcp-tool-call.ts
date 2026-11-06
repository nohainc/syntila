import { z } from "zod";

/** Internal v1 payload; not an advertised transport capability yet. */
export const MCP_TOOL_CALL_ARGUMENTS_MAX_BYTES = 64 * 1024;
export const McpToolCallRequestSchema = z
  .object({
    schemaVersion: z.literal(1),
    taskId: z.string().min(1).max(900),
    dispatchKey: z.string().min(1).max(912),
    serverId: z.string().regex(/^[a-z0-9][a-z0-9_-]{0,63}$/),
    tool: z.string().min(1).max(128),
    toolDefinitionHash: z.string().regex(/^[a-f0-9]{64}$/),
    arguments: z.record(z.string(), z.json()),
    timeoutMs: z.number().int().min(1).max(1_800_000),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.dispatchKey !== `mcp-tool-v1:${value.taskId}`) {
      ctx.addIssue({
        code: "custom",
        path: ["dispatchKey"],
        message: "Dispatch key must identify the logical task",
      });
    }
    const bytes = new TextEncoder().encode(JSON.stringify(value.arguments));
    if (bytes.length > MCP_TOOL_CALL_ARGUMENTS_MAX_BYTES) {
      ctx.addIssue({
        code: "custom",
        path: ["arguments"],
        message: "Tool arguments exceed the byte limit",
      });
    }
  });

export type McpToolCallRequest = z.infer<typeof McpToolCallRequestSchema>;

export const MCP_TOOL_CALL_RESULT_MAX_BYTES = 256 * 1024;
export const McpToolCallResultSchema = z
  .object({
    schemaVersion: z.literal(1),
    taskId: z.string().min(1).max(900),
    dispatchKey: z.string().min(1).max(912),
    state: z.enum(["completed", "toolError", "rejected", "unknown"]),
    code: z.string().min(1).max(128),
    result: z.record(z.string(), z.json()).optional(),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.dispatchKey !== `mcp-tool-v1:${value.taskId}`) {
      ctx.addIssue({
        code: "custom",
        path: ["dispatchKey"],
        message: "Dispatch key must identify the logical task",
      });
    }
    if (
      value.result !== undefined &&
      value.state !== "completed" &&
      value.state !== "toolError"
    ) {
      ctx.addIssue({
        code: "custom",
        path: ["result"],
        message: "Only completed or tool-error outcomes carry a result",
      });
    }
    const bytes = new TextEncoder().encode(JSON.stringify(value.result ?? {}));
    if (bytes.length > MCP_TOOL_CALL_RESULT_MAX_BYTES) {
      ctx.addIssue({
        code: "custom",
        path: ["result"],
        message: "Tool result exceeds the byte limit",
      });
    }
  });
export type McpToolCallResult = z.infer<typeof McpToolCallResultSchema>;

/**
 * Read-only reconciliation of one logical tool step. Cloud asks what the
 * Workspace durably knows about a key; the answer never dispatches anything.
 * `unclaimed` means the Workspace never began the call (still never replayed
 * automatically: Cloud's own claim stands); `claimed_no_outcome` means it began
 * and no outcome is recorded, so the result stays unknown.
 */
export const McpToolCallStatusRequestSchema = z
  .object({
    schemaVersion: z.literal(1),
    taskId: z.string().min(1).max(900),
    dispatchKey: z.string().min(1).max(912),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.dispatchKey !== `mcp-tool-v1:${value.taskId}`) {
      ctx.addIssue({
        code: "custom",
        path: ["dispatchKey"],
        message: "Dispatch key must identify the logical task",
      });
    }
  });
export type McpToolCallStatusRequest = z.infer<
  typeof McpToolCallStatusRequestSchema
>;

export const McpToolCallStatusResultSchema = z
  .object({
    schemaVersion: z.literal(1),
    taskId: z.string().min(1).max(900),
    dispatchKey: z.string().min(1).max(912),
    status: z.enum(["unclaimed", "claimed_no_outcome", "recorded"]),
    state: z.enum(["completed", "toolError", "rejected", "unknown"]).optional(),
    code: z.string().min(1).max(128).optional(),
    result: z.record(z.string(), z.json()).optional(),
  })
  .strict()
  .superRefine((value, ctx) => {
    if (value.dispatchKey !== `mcp-tool-v1:${value.taskId}`) {
      ctx.addIssue({
        code: "custom",
        path: ["dispatchKey"],
        message: "Dispatch key must identify the logical task",
      });
    }
    const recorded = value.status === "recorded";
    const hasState = value.state !== undefined;
    const hasCode = value.code !== undefined;
    if (hasState !== recorded || hasCode !== recorded) {
      ctx.addIssue({
        code: "custom",
        path: ["status"],
        message: "Only a recorded status carries a state and code",
      });
    }
    if (
      value.result !== undefined &&
      value.state !== "completed" &&
      value.state !== "toolError"
    ) {
      ctx.addIssue({
        code: "custom",
        path: ["result"],
        message: "Only completed or tool-error outcomes carry a result",
      });
    }
    const bytes = new TextEncoder().encode(JSON.stringify(value.result ?? {}));
    if (bytes.length > MCP_TOOL_CALL_RESULT_MAX_BYTES) {
      ctx.addIssue({
        code: "custom",
        path: ["result"],
        message: "Tool result exceeds the byte limit",
      });
    }
  });
export type McpToolCallStatusResult = z.infer<
  typeof McpToolCallStatusResultSchema
>;
