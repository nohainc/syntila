import { WorkflowDefaultSchema } from "@syntila/protocol";
import { readBody } from "./validation.js";
import { spaceWorkflowDefault, userWorkflowDefault } from "../queries.js";
import { BUILTIN_WORKFLOW_CATALOG } from "@syntila/core";
import {
  loadWorkflowWorkspace,
  resolveUserWorkflowWorkspace,
} from "./workflow-workspace.js";
import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import {
  HttpError,
  json,
  securityContext,
  type SecurityEnv,
} from "./http-security.js";
import { dataOf } from "../../platform/data.js";

const CHAT_WORKFLOW_ID = "chat";

async function loadUserWorkflowConfig(
  env: SecurityEnv,
  userId: string,
  workflowId: string,
  workspaceId: string | null,
) {
  const row = await dataOf(env).read.row<{ configurationJson: string }>`
    SELECT configuration_json AS "configurationJson" FROM user_workflow_configurations
    WHERE user_id = ${userId} AND workflow_id = ${workflowId} AND workspace_id = ${workspaceId}
  `;
  return JSON.parse(row?.configurationJson ?? "null");
}

function definitionFor(id: string) {
  const definition = Object.values(BUILTIN_WORKFLOW_CATALOG).find(
    (entry) => entry.id === id,
  );
  if (!definition) throw new HttpError(400, "Unknown workflow");
  return definition;
}

export async function loadUserWorkflowDefault(
  env: Pick<SecurityEnv, "SYNTILA_DB">,
  userId: string,
  workspaceId: string | null,
) {
  if (!workspaceId) return CHAT_WORKFLOW_ID;
  const row = await userWorkflowDefault(env, userId, workspaceId);
  return row?.workflowId ?? CHAT_WORKFLOW_ID;
}

export async function loadSpaceWorkflowDefault(
  env: Pick<SecurityEnv, "SYNTILA_DB">,
  spaceId: string,
  ownerUserId: string,
) {
  const row = await spaceWorkflowDefault(env, spaceId);
  if (row) return row.workflowId;
  const { workspaceId } = await loadWorkflowWorkspace(
    env,
    ownerUserId,
    spaceId,
  );
  return loadUserWorkflowDefault(env, ownerUserId, workspaceId);
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

  const userWorkspaceId = spaceId
    ? null
    : await resolveUserWorkflowWorkspace(
        env,
        ownerUserId,
        new URL(request.url).searchParams.get("workspaceId"),
      );

  if (request.method === "GET") {
    const selected = spaceId
      ? await loadSpaceWorkflowDefault(env, spaceId, ownerUserId)
      : await loadUserWorkflowDefault(env, ownerUserId, userWorkspaceId);
    const configuration = spaceId
      ? (
          await loadSpaceWorkflowConfigurations(env, spaceId)
        ).configurations.find((value) => value.workflowId === selected)
      : await loadUserWorkflowConfig(env, ownerUserId, selected, userWorkspaceId);
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
  if (workflowId !== CHAT_WORKFLOW_ID) {
    const workspaceId = spaceId
      ? (await loadWorkflowWorkspace(env, ownerUserId, spaceId)).workspaceId
      : userWorkspaceId;
    if (!workspaceId)
      throw new HttpError(
        400,
        "Choose a Workspace before selecting a workflow",
      );
  }
  const configuration = spaceId
    ? (await loadSpaceWorkflowConfigurations(env, spaceId)).configurations.find(
        (value) => value.workflowId === workflowId,
      )
    : await loadUserWorkflowConfig(env, ownerUserId, workflowId, userWorkspaceId);
  if (configuration?.enabled === false)
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
    await dataOf(env).read.run`INSERT INTO user_workflow_defaults(user_id,workspace_id,workflow_id,updated_at)
       VALUES(${ownerUserId},${userWorkspaceId},${workflowId},${now})
       ON CONFLICT(user_id,workspace_id) DO UPDATE SET workflow_id=excluded.workflow_id,updated_at=excluded.updated_at`;
  }
  return json({ schemaVersion: 1, defaultWorkflowId: workflowId });
}
