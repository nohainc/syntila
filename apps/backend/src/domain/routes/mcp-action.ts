import { readJson } from "./validation.js";
import { ownsActiveWorkspace } from "../queries.js";
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
  const owned = await ownsActiveWorkspace(env, workspaceId, context.userId);
  if (!owned) throw new HttpError(404, "Workspace not found");

  const gateway = env.SYNTILA_WORKSPACE_GATEWAY;
  if (!gateway) throw new HttpError(503, "Workspace Gateway is not configured");

  // Free-form on purpose: the backend does not interpret an MCP action. It is
  // forwarded verbatim to the Workspace gateway, which owns the contract. The
  // body is already a JSON object (readJson) capped at 2 MiB (readBodyText);
  // the guard in test/domain/request-body-guard.test.ts allowlists this site.
  const body = await readJson(request);

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
