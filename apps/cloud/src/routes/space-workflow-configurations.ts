import { loadWorkflowWorkspace } from "./workflow-workspace.js";
import type { SecurityEnv } from "./http-security.js";
import { HttpError } from "./http-security.js";

/** All members execute the same Space configuration, seeded by its owner's globals. */
export async function loadSpaceWorkflowConfigurations(
  env: Pick<SecurityEnv, "SYNTILA_DB">,
  spaceId: string,
  workflowId?: string,
) {
  const space = await env.SYNTILA_DB.prepare(
    "SELECT owner_user_id AS ownerUserId FROM spaces WHERE id = ?1",
  )
    .bind(spaceId)
    .first<{ ownerUserId: string }>();
  if (!space) throw new HttpError(404, "Space not found");
  const workspace = await loadWorkflowWorkspace(
    env,
    space.ownerUserId,
    spaceId,
  );
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT workflow_id, configuration_json FROM user_workflow_configurations WHERE user_id = ?1 AND workspace_id = ?4 AND (?2 IS NULL OR workflow_id = ?2)
    UNION ALL SELECT workflow_id, configuration_json FROM space_workflow_configurations WHERE space_id = ?3 AND (?2 IS NULL OR workflow_id = ?2)`,
  )
    .bind(space.ownerUserId, workflowId ?? null, spaceId, workspace.workspaceId)
    .all<{ workflow_id: string; configuration_json: string }>();
  // Space rows deliberately replace an entire workflow, including Worker and Auto model/effort fields.
  const configurations = new Map(
    rows.results.map((row) => [
      row.workflow_id,
      JSON.parse(row.configuration_json),
    ]),
  );
  return {
    ...workspace,
    ownerUserId: space.ownerUserId,
    defaultWorkflowId:
      (
        await env.SYNTILA_DB.prepare(
          "SELECT workflow_id AS workflowId FROM space_workflow_defaults WHERE space_id = ?1",
        )
          .bind(spaceId)
          .first<{ workflowId: string }>()
      )?.workflowId ??
      (
        await env.SYNTILA_DB.prepare(
          "SELECT workflow_id AS workflowId FROM user_workflow_defaults WHERE user_id = ?1 AND workspace_id = ?2",
        )
          .bind(space.ownerUserId, workspace.workspaceId)
          .first<{ workflowId: string }>()
      )?.workflowId ??
      "chat",
    configurations: [...configurations.values()],
  };
}
