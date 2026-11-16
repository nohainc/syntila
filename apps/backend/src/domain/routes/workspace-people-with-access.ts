import { ownsActiveWorkspace } from "../queries.js";
import {
  HttpError,
  json,
  securityContext,
  type SecurityEnv,
} from "./http-security.js";
import { monthStartIso } from "./workspace-invitations.js";
import { loadEffectiveMemberAccess } from "./workspace-member-access.js";
import { dataOf } from "../../platform/data.js";

/**
 * Owner-only "People with access": everyone holding a Person Grant on this
 * Workspace, with their effective mode and usage. Usage is deliberately
 * aggregate (ADR-020): counts, approximate run time, Worker ids and the last
 * time they ran something. Space names, Thread titles, prompts and results of
 * the borrower are never read here.
 */
export async function handlePeopleWithAccess(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method !== "GET") throw new HttpError(405, "Unsupported method");
  const workspace = await ownsActiveWorkspace(env, workspaceId, context.userId);
  if (!workspace) throw new HttpError(404, "Workspace not found");
  const grants = await dataOf(env).read.rows<{
      userId: string;
      displayName: string;
      email: string;
      status: string;
      grantedAt: string;
      maxConcurrentRequests: number;
      maxRunSecondsPerMonth: number | null;
      custom: number;
    }>`SELECT g.user_id AS "userId", u.display_name AS "displayName", u.email, g.status,
            g.created_at AS "grantedAt", g.max_concurrent_requests AS "maxConcurrentRequests", g.max_run_seconds_per_month AS "maxRunSecondsPerMonth",
            EXISTS (SELECT 1 FROM workspace_member_overrides o
                     WHERE o.workspace_id = g.workspace_id AND o.user_id = g.user_id) AS custom
     FROM workspace_person_grants g JOIN users u ON u.id = g.user_id
     WHERE g.workspace_id = ${workspaceId} ORDER BY g.status, LOWER(u.display_name), g.user_id`;
  const usage = await dataOf(env).read.rows<{
      userId: string;
      requests: number;
      approxSeconds: number | null;
      lastUsedAt: string | null;
    }>`SELECT requested_by_user_id AS "userId",
            COUNT(*) AS requests,
            ROUND(SUM(GREATEST(0, EXTRACT(EPOCH FROM (updated_at - created_at)))))::bigint AS "approxSeconds",
            MAX(created_at) AS "lastUsedAt"
     FROM worker_assignments
     WHERE execution_workspace_id = ${workspaceId} AND requested_by_user_id IS NOT NULL
     GROUP BY requested_by_user_id`;
  const monthRows = await dataOf(env).read.rows<{ userId: string; seconds: number | null }>`SELECT requested_by_user_id AS "userId",
            ROUND(SUM(GREATEST(0, EXTRACT(EPOCH FROM (updated_at - created_at)))))::bigint AS seconds
     FROM worker_assignments
     WHERE execution_workspace_id = ${workspaceId} AND requested_by_user_id IS NOT NULL AND created_at >= ${monthStartIso()}
     GROUP BY requested_by_user_id`;
  const monthSeconds = new Map(
    monthRows.results.map((row) => [row.userId, row.seconds ?? 0]),
  );
  const workers = await dataOf(env).read.rows<{ userId: string; workerId: string }>`SELECT DISTINCT requested_by_user_id AS "userId", workspace_worker_id AS "workerId"
     FROM worker_assignments
     WHERE execution_workspace_id = ${workspaceId} AND requested_by_user_id IS NOT NULL AND workspace_worker_id IS NOT NULL`;
  const usageByUser = new Map(usage.results.map((row) => [row.userId, row]));
  const people = [];
  for (const grant of grants.results) {
    const used = usageByUser.get(grant.userId);
    const policy = await loadEffectiveMemberAccess(
      env,
      workspaceId,
      grant.userId,
    );
    people.push({
      userId: grant.userId,
      displayName: grant.displayName,
      email: grant.email,
      status: grant.status,
      grantedAt: grant.grantedAt,
      maxConcurrentRequests: grant.maxConcurrentRequests,
      maxRunSecondsPerMonth: grant.maxRunSecondsPerMonth,
      custom: grant.custom === 1,
      mode: policy?.mode ?? null,
      usage: {
        requests: used?.requests ?? 0,
        approxSeconds: used?.approxSeconds ?? 0,
        lastUsedAt: used?.lastUsedAt ?? null,
        monthSeconds: monthSeconds.get(grant.userId) ?? 0,
        workerIds: workers.results
          .filter((row) => row.userId === grant.userId)
          .map((row) => row.workerId)
          .sort(),
      },
    });
  }
  return json({ schemaVersion: 1, people });
}
