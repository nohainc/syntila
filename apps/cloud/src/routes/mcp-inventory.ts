import { McpInventorySchema } from "@syntila/workspace-runtime-protocol";
import { getWorkspaceGatewayStatus } from "./workspace-access.js";
import { HttpError, json, securityContext } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";

/**
 * `GET /api/workspaces/:id/mcp-inventory`: the last sanitized MCP inventory a
 * Workspace published (identity, status, consented tool names and hashes,
 * Worker-type bindings). Information for choosing servers by name, never
 * authority: the Workspace re-checks consent, enablement and the tool hash
 * before every execution, and Cloud holds no commands, paths, endpoints or
 * tokens to return.
 *
 * Only the Workspace owner may read it. The answer says whether the Workspace
 * is online and how old the snapshot is, so the UI can mark a stale or
 * disconnected inventory instead of presenting it as current. A snapshot is
 * re-validated against the contract on the way out.
 */
export async function handleWorkspaceMcpInventory(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  if (request.method !== "GET") throw new HttpError(405, "Unsupported method");
  const context = await securityContext(request, env, ctx);
  const owned = await env.SYNTILA_DB.prepare(
    "SELECT 1 AS ok FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2 AND status != 'revoked'",
  )
    .bind(workspaceId, context.userId)
    .first();
  if (!owned) throw new HttpError(404, "Workspace not found");

  const gateway = env.SYNTILA_WORKSPACE_GATEWAY;
  const status = await getWorkspaceGatewayStatus(env, workspaceId);
  type Stored = { inventory?: unknown; receivedAt?: unknown };
  let stored = null as Stored | null;
  if (gateway) {
    try {
      const response = await gateway
        .getByName(workspaceId)
        .fetch("https://workspace-gateway/mcp-inventory");
      if (response.ok) stored = (await response.json()) as Stored | null;
    } catch {
      stored = null;
    }
  }
  const parsed = McpInventorySchema.safeParse(stored?.inventory);
  const receivedAt =
    typeof stored?.receivedAt === "string" ? stored.receivedAt : null;
  const ageMs = receivedAt ? Date.now() - Date.parse(receivedAt) : null;
  return json({
    schemaVersion: 1,
    // Unknown (null) when the gateway cannot say; never assumed online.
    online: status?.online ?? null,
    receivedAt,
    ageSeconds:
      ageMs !== null && Number.isFinite(ageMs)
        ? Math.max(0, Math.round(ageMs / 1000))
        : null,
    inventory: parsed.success ? parsed.data : null,
  });
}
