import { HttpError, securityContext } from "./http-security.js";
import type { SecurityEnv } from "./http-security.js";

/**
 * `GET /api/workspaces/:id/mcp-tool-calls/:taskId/status`: asks what Cloud and
 * the owning Workspace durably recorded for a logical key.
 *
 * Read-only reconciliation for diagnosis: never dispatches, never retries,
 * and never modifies Cloud or Workspace journal records. Only the Workspace
 * owner may query it.
 */
export async function handleWorkspaceMcpToolCallStatus(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  taskId: string,
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

  if (!taskId || taskId.length > 900) {
    throw new HttpError(400, "Invalid taskId");
  }

  const gateway = env.SYNTILA_WORKSPACE_GATEWAY;
  if (!gateway) throw new HttpError(503, "Workspace Gateway is not configured");

  const response = await gateway
    .getByName(workspaceId)
    .fetch("https://workspace-gateway/mcp-tool-call-status", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        schemaVersion: 1,
        taskId,
        dispatchKey: `mcp-tool-v1:${taskId}`,
      }),
    });

  return new Response(response.body, {
    status: response.status,
    headers: { "Content-Type": "application/json" },
  });
}
