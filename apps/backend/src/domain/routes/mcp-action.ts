import { HttpError, securityContext } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";

/**
 * `POST /api/workspaces/:id/mcp-action`: invokes a Service-owned MCP management
 * action on the Workspace (enable, disable, remove, consent, test).
 *
 * Cloud acts only as an authenticated transport to the Workspace that owns the
 * local registry; Cloud never receives or stores local command paths, tokens or
 * credentials. Only the Workspace owner (or authorized member) may invoke it.
 */
export async function handleWorkspaceMcpAction(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  if (request.method !== "POST") throw new HttpError(405, "Unsupported method");
  const context = await securityContext(request, env, ctx);
  const owned = await env.SYNTILA_DB.prepare(
    "SELECT 1 AS ok FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2 AND status != 'revoked'",
  )
    .bind(workspaceId, context.userId)
    .first();
  if (!owned) throw new HttpError(404, "Workspace not found");

  const gateway = env.SYNTILA_WORKSPACE_GATEWAY;
  if (!gateway) throw new HttpError(503, "Workspace Gateway is not configured");

  const body = (await request.json().catch(() => null)) as unknown;
  if (!body || typeof body !== "object") {
    throw new HttpError(400, "Invalid JSON body");
  }

  const response = await gateway
    .getByName(workspaceId)
    .fetch("https://workspace-gateway/mcp-action", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  return new Response(response.body, {
    status: response.status,
    headers: { "Content-Type": "application/json" },
  });
}
