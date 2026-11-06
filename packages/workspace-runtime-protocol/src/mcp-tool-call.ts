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
