import { queryOf } from "../../platform/data.js";
import { handleWorkerWorkflowConfigurations } from "./worker-workflow-configurations.js";
import {
  HttpError,
  securityContext,
  type SecurityEnv,
} from "./http-security.js";

export async function handleWorkflowConfigurations(
  request: Request,
  env: SecurityEnv,
  workflowId?: string,
  ctx?: ExecutionContext,
  spaceId?: string,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const db = env.SYNTILA_DB;
  if (spaceId) {
    const membership = await queryOf(db).row<{ ownerUserId: string; kind: string }>`SELECT s.owner_user_id AS "ownerUserId", COALESCE(s.kind, 'group') AS kind FROM spaces s JOIN space_memberships m ON m.space_id = s.id JOIN users u ON u.id = m.user_id WHERE s.id = ${spaceId} AND m.user_id = ${context.userId} AND u.status = 'active'`;
    if (!membership) throw new HttpError(403, "Space membership required");
    if (membership.kind === "direct") {
      if (request.method !== "GET") {
        throw new HttpError(
          403,
          "Direct Spaces do not support Space-level Workflow overrides; configure personal Workflows instead",
        );
      }
    } else if (
      request.method !== "GET" &&
      membership.ownerUserId !== context.userId
    ) {
      throw new HttpError(403, "Only the Space owner can configure workflows");
    }
  }
  return handleWorkerWorkflowConfigurations(request, env, context.userId, workflowId, spaceId);
}
