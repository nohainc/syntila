import { WorkflowDefaultSchema } from "@syntila/protocol";
import { readBody } from "./validation.js";
import { spaceWorkflowDefault, userWorkflowDefault } from "../queries.js";
import { BUILTIN_WORKFLOW_CATALOG } from "@syntila/core";
import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import {
  HttpError,
  json,
  securityContext,
  type SecurityEnv,
} from "./http-security.js";
import { dataOf } from "../../platform/data.js";

const CHAT_WORKFLOW_ID = "chat";

function definitionFor(id: string) {
  const definition = Object.values(BUILTIN_WORKFLOW_CATALOG).find(
    (entry) => entry.id === id,
  );
  if (!definition) throw new HttpError(400, "Unknown workflow");
  return definition;
}

/** The person's own configuration of one Workflow, if saved. */
async function ownConfiguration(
  env: Pick<SecurityEnv, "SYNTILA_DB">,
  userId: string,
  workflowId: string,
): Promise<{ enabled?: boolean } | null> {
  const row = await dataOf(env).read.row<{ configurationJson: string }>`SELECT configuration_json AS "configurationJson"
       FROM user_worker_workflow_configurations WHERE user_id = ${userId} AND workflow_id = ${workflowId}`;
  return row ? JSON.parse(row.configurationJson) : null;
}

export async function handleWorkflowDefault(
  request: Request,
  env: SecurityEnv,
  spaceId?: string,
  ctx?: ExecutionContext,
) {
  const context = await securityContext(request, env, ctx);
  let ownerUserId = context.userId;
  if (spaceId) {
    const membership = await dataOf(env).read.row<{ ownerUserId: string; kind: string }>`SELECT s.owner_user_id AS "ownerUserId", COALESCE(s.kind, 'group') AS kind
         FROM spaces s
         JOIN space_memberships m ON m.space_id = s.id
         JOIN users u ON u.id = m.user_id
        WHERE s.id = ${spaceId} AND m.user_id = ${context.userId} AND u.status = 'active'`;
    if (!membership) throw new HttpError(403, "Space membership required");
    if (membership.kind === "direct") {
      if (request.method !== "GET") {
        throw new HttpError(
          403,
          "Direct Spaces do not support Space-level default Workflow overrides; configure personal defaults instead",
        );
      }
    } else if (
      request.method !== "GET" &&
      membership.ownerUserId !== context.userId
    ) {
      throw new HttpError(403, "Only the Space owner can configure workflows");
    }
    ownerUserId = membership.ownerUserId;
  }
  const configurationOf = async (workflowId: string) =>
    spaceId
      ? (await loadSpaceWorkflowConfigurations(env, spaceId)).configurations.find(
          (value: { workflowId?: string }) => value.workflowId === workflowId,
        )
      : await ownConfiguration(env, ownerUserId, workflowId);

  if (request.method === "GET") {
    const selected = spaceId
      ? (await loadSpaceWorkflowConfigurations(env, spaceId)).defaultWorkflowId
      : ((await userWorkflowDefault(dataOf(env).read, ownerUserId))?.workflowId ?? CHAT_WORKFLOW_ID);
    const configuration = await configurationOf(selected);
    return json({
      schemaVersion: 1,
      defaultWorkflowId:
        configuration?.enabled === false ? CHAT_WORKFLOW_ID : selected,
    });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");
  const body = await readBody(request, WorkflowDefaultSchema, {
    message: "Invalid default workflow selection",
  });
  const workflowId = body.defaultWorkflowId;
  definitionFor(workflowId);
  if ((await configurationOf(workflowId))?.enabled === false)
    throw new HttpError(
      400,
      "Disabled workflows cannot be selected as default",
    );
  const now = new Date().toISOString();
  if (spaceId) {
    await dataOf(env).read.run`INSERT INTO space_workflow_defaults(space_id,workflow_id,updated_at)
       VALUES(${spaceId},${workflowId},${now})
       ON CONFLICT(space_id) DO UPDATE SET workflow_id=excluded.workflow_id,updated_at=excluded.updated_at`;
  } else {
    await dataOf(env).read.run`INSERT INTO user_workflow_defaults(user_id,workflow_id,updated_at)
       VALUES(${ownerUserId},${workflowId},${now})
       ON CONFLICT(user_id) DO UPDATE SET workflow_id=excluded.workflow_id,updated_at=excluded.updated_at`;
  }
  return json({ schemaVersion: 1, defaultWorkflowId: workflowId });
}
