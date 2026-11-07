import { z } from "zod";

/**
 * Service-owned MCP management actions initiated from AX / Cloud.
 *
 * Cloud acts only as an authenticated transport to the Workspace that owns the
 * local registry; Cloud never receives or stores local command paths, tokens or
 * credentials. All validation, policy decisions, probe executions and registry
 * mutations remain Service-side.
 */
export const McpActionKindSchema = z.enum([
  "addRemote",
  "enable",
  "disable",
  "remove",
  "bind",
  "unbind",
  "consent",
  "test",
]);

export const McpActionRequestSchema = z
  .object({
    actionId: z.string().min(1).max(128),
    action: McpActionKindSchema,
    serverId: z.string().regex(/^[a-z0-9][a-z0-9_-]{0,63}$/),
    displayName: z.string().min(1).max(80).optional(),
    endpoint: z.string().url().max(2048).optional(),
    tokenEnv: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]{0,127}$/).optional(),
    insecureLoopback: z.boolean().optional(),
    workerTypeId: z.string().regex(/^[a-z][a-z0-9_-]{0,63}$/).optional(),
    acceptHash: z.string().regex(/^[0-9a-f]{64}$/).optional(),
  })
  .strict();

export const McpActionResultSchema = z
  .object({
    actionId: z.string().min(1).max(128),
    ok: z.boolean(),
    action: McpActionKindSchema,
    serverId: z.string().regex(/^[a-z0-9][a-z0-9_-]{0,63}$/),
    result: z.record(z.string(), z.unknown()).optional(),
    error: z
      .object({
        code: z.string().min(1).max(64),
        message: z.string().min(1).max(1024),
      })
      .strict()
      .optional(),
  })
  .strict();

export type McpActionKind = z.infer<typeof McpActionKindSchema>;
export type McpActionRequest = z.infer<typeof McpActionRequestSchema>;
export type McpActionResult = z.infer<typeof McpActionResultSchema>;
