import { z } from "zod";

/**
 * Sanitized MCP inventory v1: what Cloud and the AX app may know about a
 * Workspace's MCP servers. It carries identity, status, consented tool names
 * and definition hashes, and Worker-type bindings. It never carries launch
 * commands, executable paths, endpoints, tokens, environment values or tool
 * descriptions/schemas; the objects are strict, so such fields are rejected,
 * not stripped. Internal v1 payload; not an advertised transport capability yet.
 *
 * Inventory is information, never authority: the Workspace re-checks consent,
 * enablement and the tool hash before every execution.
 */
export const MCP_INVENTORY_MAX_SERVERS = 64;
export const MCP_INVENTORY_MAX_TOOLS = 128;

/** Fixed diagnostic codes; free text from a server never reaches Cloud. */
export const McpInventoryDiagnosticSchema = z.enum([
  "not_consented",
  "definition_changed",
  "binary_changed",
  "unreachable",
  "auth_required",
  "profile_unsupported",
  "registry_unreadable",
]);

/**
 * `unknown` until a fresh diagnostic supplies evidence; enablement and consent
 * alone never imply that a server is reachable or unchanged.
 */
export const McpInventoryAvailabilitySchema = z.enum([
  "unknown",
  "available",
  "unavailable",
  "incompatible",
]);

const serverId = z.string().regex(/^[a-z0-9][a-z0-9_-]{0,63}$/);

export const McpInventoryToolSchema = z
  .object({
    name: z.string().min(1).max(128),
    definitionHash: z.string().regex(/^[a-f0-9]{64}$/),
  })
  .strict();

export const McpInventoryServerSchema = z
  .object({
    serverId,
    displayName: z.string().min(1).max(80),
    transport: z.enum(["local", "remote"]),
    consented: z.boolean(),
    enabled: z.boolean(),
    availability: McpInventoryAvailabilitySchema,
    diagnostic: McpInventoryDiagnosticSchema.optional(),
    tools: z.array(McpInventoryToolSchema).max(MCP_INVENTORY_MAX_TOOLS),
    boundWorkerTypes: z
      .array(z.string().regex(/^[a-z][a-z0-9_-]{0,63}$/))
      .max(32),
  })
  .strict()
  .superRefine((server, ctx) => {
    const names = new Set<string>();
    for (const [index, tool] of server.tools.entries()) {
      if (names.has(tool.name))
        ctx.addIssue({
          code: "custom",
          path: ["tools", index, "name"],
          message: "Tool names must be unique",
        });
      names.add(tool.name);
    }
    if (
      new Set(server.boundWorkerTypes).size !== server.boundWorkerTypes.length
    )
      ctx.addIssue({
        code: "custom",
        path: ["boundWorkerTypes"],
        message: "Worker bindings must be unique",
      });
  });

export const McpInventorySchema = z
  .object({
    schemaVersion: z.literal(1),
    /** Increases with every local change so stale snapshots can be ignored. */
    revision: z.number().int().min(0),
    servers: z.array(McpInventoryServerSchema).max(MCP_INVENTORY_MAX_SERVERS),
  })
  .strict()
  .superRefine((inventory, ctx) => {
    const ids = new Set<string>();
    for (const [index, server] of inventory.servers.entries()) {
      if (ids.has(server.serverId))
        ctx.addIssue({
          code: "custom",
          path: ["servers", index, "serverId"],
          message: "Server IDs must be unique",
        });
      ids.add(server.serverId);
    }
  });

export type McpInventory = z.infer<typeof McpInventorySchema>;
export type McpInventoryServer = z.infer<typeof McpInventoryServerSchema>;
