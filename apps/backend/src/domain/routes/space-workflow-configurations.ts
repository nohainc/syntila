import { spaceOwnerOf, spaceWorkflowDefault, userWorkflowDefault } from "../queries.js";
import type { SecurityEnv } from "./http-security.js";
import { HttpError } from "./http-security.js";
import { dataOf } from "../../platform/data.js";

/** All members execute the same Space configuration, seeded by its owner's own. */
export async function loadSpaceWorkflowConfigurations(
  env: Pick<SecurityEnv, "SYNTILA_DB">,
  spaceId: string,
  workflowId?: string,
) {
  const space = await spaceOwnerOf(dataOf(env).read, spaceId);
  if (!space) throw new HttpError(404, "Space not found");
  const workflowFilter = workflowId ?? null;
  const rows = await dataOf(env).read.rows<{ workflow_id: string; configuration_json: string }>`
    SELECT workflow_id, configuration_json FROM user_worker_workflow_configurations
     WHERE user_id = ${space.ownerUserId}
       AND (${workflowFilter}::text IS NULL OR workflow_id = ${workflowFilter})
    UNION ALL SELECT workflow_id, configuration_json FROM space_workflow_configurations
     WHERE space_id = ${spaceId}
       AND (${workflowFilter}::text IS NULL OR workflow_id = ${workflowFilter})`;
  // Space rows deliberately replace an entire workflow, including Worker and Auto model/effort fields.
  const configurations = new Map(
    rows.map((row) => [
      row.workflow_id,
      JSON.parse(row.configuration_json),
    ]),
  );
  return {
    ownerUserId: space.ownerUserId,
    defaultWorkflowId:
      (await spaceWorkflowDefault(dataOf(env).read, spaceId))?.workflowId ??
      (await userWorkflowDefault(dataOf(env).read, space.ownerUserId))?.workflowId ??
      "chat",
    configurations: [...configurations.values()],
  };
}
