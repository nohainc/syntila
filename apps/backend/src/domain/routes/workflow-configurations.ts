import {
  loadWorkflowWorkspace,
  resolveUserWorkflowWorkspace,
} from "./workflow-workspace.js";
import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import {
  BUILTIN_WORKFLOW_CATALOG,
  DomainInvariantError,
  parseUserWorkflowConfiguration,
  resolveUserWorkflowConfiguration,
  validateWorkerExecutionSelection,
  type UserWorkflowConfiguration,
} from "@syntila/core";
import {
  HttpError,
  json,
  securityContext,
  type SecurityEnv,
} from "./http-security.js";
import { handleListWorkspaceWorkerInventory } from "./profiles.js";
import type { WorkerExecutionOptions } from "@syntila/core";
import {
  loadSpaceWorkflowDefault,
  loadUserWorkflowDefault,
} from "./workflow-default.js";
import { dataOf } from "../../platform/data.js";

function definitionFor(id: string) {
  const definition = Object.values(BUILTIN_WORKFLOW_CATALOG)
    .filter((entry) => entry.id === id)
    .sort((a, b) => b.version - a.version)[0];
  if (!definition) throw new HttpError(404, "Unknown workflow");
  return definition;
}

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
    const membership = await dataOf(env).read.row<{ ownerUserId: string; kind: string }>`SELECT s.owner_user_id AS "ownerUserId", COALESCE(s.kind, 'group') AS kind FROM spaces s JOIN space_memberships m ON m.space_id = s.id JOIN users u ON u.id = m.user_id WHERE s.id = ${spaceId} AND m.user_id = ${context.userId} AND u.status = 'active'`;
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
  // User-level configuration is stored per Workspace.
  const userWorkspaceId = spaceId
    ? null
    : await resolveUserWorkflowWorkspace(
        env,
        context.userId,
        new URL(request.url).searchParams.get("workspaceId"),
      );
  const table = spaceId
    ? "space_workflow_configurations"
    : "user_workflow_configurations";
  const key = spaceId ? "space_id" : "user_id";
  const owner = spaceId ?? context.userId;
  // Extra scope column/bind so every statement addresses one Workspace.
  const scopeSql = spaceId ? "" : " AND workspace_id = ?3";
  const scopeBinds = spaceId ? [] : [userWorkspaceId];

  if (request.method === "GET") {
    if (workflowId) definitionFor(workflowId);
    if (spaceId) {
      const effective = await loadSpaceWorkflowConfigurations(
        env,
        spaceId,
        workflowId,
      );
      return json({
        schemaVersion: 1,
        defaultWorkflowId: effective.defaultWorkflowId,
        configurations: effective.configurations,
      });
    }
    const rows = await dataOf(env).read.rows<{ configuration_json: string }>`SELECT configuration_json FROM user_workflow_configurations
      WHERE user_id = ${context.userId} AND workspace_id = ${userWorkspaceId} AND (${workflowId ?? null}::text IS NULL OR workflow_id = ${workflowId ?? null})`;
    return json({
      schemaVersion: 1,
      workspaceId: userWorkspaceId,
      defaultWorkflowId: await loadUserWorkflowDefault(
        env,
        context.userId,
        userWorkspaceId,
      ),
      configurations: rows.map((row) =>
        JSON.parse(row.configuration_json),
      ),
    });
  }
  if (!workflowId)
    throw new HttpError(405, "Choose a workflow for this operation");
  const definition = definitionFor(workflowId);
  const reset = async () => {
    if (spaceId) {
      await dataOf(env).read.run`DELETE FROM space_workflow_configurations WHERE space_id = ${owner} AND workflow_id = ${workflowId}`;
    } else {
      await dataOf(env).read.run`DELETE FROM user_workflow_configurations WHERE user_id = ${owner} AND workflow_id = ${workflowId} AND workspace_id = ${scopeBinds[0]}`;
    }
  };
  if (request.method === "DELETE") {
    await reset();
    if (spaceId) {
      const inherited = await loadSpaceWorkflowConfigurations(
        env,
        spaceId,
        workflowId,
      );
      return json({
        configuration:
          inherited.configurations[0] ??
          parseUserWorkflowConfiguration(definition, {
            schemaVersion: 1,
            workflowId,
            enabled: true,
            defaults: {},
            stepOverrides: {},
          }),
      });
    }
    return json({
      configuration: parseUserWorkflowConfiguration(definition, {
        schemaVersion: 1,
        workflowId,
        enabled: true,
        defaults: {},
        stepOverrides: {},
      }),
    });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");
  let configuration: UserWorkflowConfiguration;
  try {
    configuration = parseUserWorkflowConfiguration(
      definition,
      await request.json(),
    );
  } catch (error) {
    if (error instanceof DomainInvariantError || error instanceof SyntaxError)
      throw new HttpError(400, error.message);
    throw error;
  }
  if (workflowId === "chat" && !configuration.enabled)
    throw new HttpError(400, "Chat workflow cannot be disabled");
  const selectedWorkspace = spaceId
    ? await loadWorkflowWorkspace(env, context.userId, spaceId)
    : { workspaceId: userWorkspaceId };
  if (!selectedWorkspace.workspaceId)
    throw new HttpError(400, "Choose a Workspace before configuring workflows");
  const inventoryResponse = await handleListWorkspaceWorkerInventory(
    new Request(new URL("/api/workers/inventory", request.url), {
      headers: request.headers,
    }),
    env,
    ctx,
  );
  const inventory = (await inventoryResponse.json()) as {
    workers: {
      id: string;
      workspaceId: string;
      executionOptions: WorkerExecutionOptions | null;
    }[];
  };
  const allWorkers = inventory.workers;
  inventory.workers = inventory.workers.filter(
    (worker) => worker.workspaceId === selectedWorkspace.workspaceId,
  );
  const previous = spaceId
    ? await dataOf(env).read.row<{ configuration_json: string }>`SELECT configuration_json FROM space_workflow_configurations WHERE space_id = ${owner} AND workflow_id = ${workflowId}`
    : await dataOf(env).read.row<{ configuration_json: string }>`SELECT configuration_json FROM user_workflow_configurations WHERE user_id = ${owner} AND workflow_id = ${workflowId} AND workspace_id = ${scopeBinds[0]}`;
  const priorConfiguration: UserWorkflowConfiguration | undefined = previous
    ? JSON.parse(previous.configuration_json)
    : spaceId
      ? (await loadSpaceWorkflowConfigurations(env, spaceId, workflowId))
          .configurations[0]
      : undefined;
  const old: Record<
    string,
    import("@syntila/core").WorkflowSelection | undefined
  > = {
    ...resolveUserWorkflowConfiguration(definition, priorConfiguration).steps,
    defaults: priorConfiguration?.defaults,
  };
  for (const [stepId, selection] of Object.entries({
    ...resolveUserWorkflowConfiguration(definition, configuration).steps,
    defaults: configuration.defaults,
  })) {
    if (!selection.worker) {
      if (configuration.enabled)
        throw new HttpError(
          400,
          `${stepId === "defaults" ? "Workflow" : stepId}: Select a Worker for every enabled Workflow step`,
        );
      // Disabled Workflows may retain model/effort intent until they are enabled.
      if (!selection.model && !selection.effort && !selection.catalogRevision)
        continue;
      if (
        inventory.workers.some(
          (worker) =>
            worker.executionOptions &&
            !validateWorkerExecutionSelection(
              worker.executionOptions,
              selection.model ?? null,
              selection.effort ?? null,
            ),
        )
      )
        continue;
      throw new HttpError(
        400,
        "No owned Worker supports the selected model/effort",
      );
    }
    if (
      allWorkers.some(
        (worker) =>
          worker.id === selection.worker &&
          worker.workspaceId !== selectedWorkspace.workspaceId,
      )
    )
      throw new HttpError(400, "Worker is outside the selected Workspace");
    const worker = inventory.workers.find(
      (worker) => worker.id === selection.worker,
    );
    // Removing a step override may restore already-saved defaults even while
    // the Worker/Profile is unavailable. It does not invent a new selection.
    const inherited =
      stepId !== "defaults" &&
      !configuration.stepOverrides[
        stepId as keyof typeof configuration.stepOverrides
      ];
    const prior = inherited ? priorConfiguration?.defaults : old[stepId];
    // Unavailable inventory/Profile must not erase unchanged user intent.
    if (
      (!worker ||
        !worker.executionOptions ||
        (worker.executionOptions.schemaVersion === 2 &&
          worker.executionOptions.catalogStale)) &&
      prior?.worker === selection.worker &&
      prior?.model === selection.model &&
      prior?.effort === selection.effort &&
      prior?.catalogRevision === selection.catalogRevision
    )
      continue;
    if (!worker)
      throw new HttpError(400, "Worker is not owned by the current user");
    if (!selection.model && !selection.effort && !selection.catalogRevision)
      continue;
    if (!worker.executionOptions)
      throw new HttpError(400, "Worker execution options are unavailable");
    // Saved revisions describe observed capabilities, not an execution pin.
    const error = validateWorkerExecutionSelection(
      worker.executionOptions,
      selection.model ?? null,
      selection.effort ?? null,
    );
    if (error) throw new HttpError(400, error);
  }
  if (
    !spaceId &&
    configuration.enabled &&
    !Object.keys(configuration.defaults).length &&
    !Object.keys(configuration.stepOverrides).length
  ) {
    await reset();
  } else {
    const updatedAt = new Date().toISOString();
    if (spaceId) {
      await dataOf(env).read.run`INSERT INTO space_workflow_configurations
        (space_id, workflow_id, schema_version, configuration_json, updated_at) VALUES (${owner}, ${workflowId}, 1, ${JSON.stringify(configuration)}, ${updatedAt})
        ON CONFLICT(space_id, workflow_id) DO UPDATE SET configuration_json = excluded.configuration_json, updated_at = excluded.updated_at`;
    } else {
      await dataOf(env).read.run`INSERT INTO user_workflow_configurations
        (user_id, workflow_id, schema_version, configuration_json, updated_at, workspace_id) VALUES (${owner}, ${workflowId}, 1, ${JSON.stringify(configuration)}, ${updatedAt}, ${scopeBinds[0]})
        ON CONFLICT(user_id, workspace_id, workflow_id) DO UPDATE SET configuration_json = excluded.configuration_json, updated_at = excluded.updated_at`;
    }
  }
  const defaultWorkflowId = spaceId
    ? await loadSpaceWorkflowDefault(env, spaceId, owner)
    : await loadUserWorkflowDefault(env, context.userId, userWorkspaceId);
  if (defaultWorkflowId === workflowId && !configuration.enabled) {
    if (spaceId) {
      await dataOf(env).read.run`INSERT INTO space_workflow_defaults(space_id,workflow_id,updated_at)
         VALUES(${spaceId},'chat',${new Date().toISOString()})
         ON CONFLICT(space_id) DO UPDATE SET workflow_id='chat',updated_at=excluded.updated_at`;
    } else {
      await dataOf(env).read.run`INSERT INTO user_workflow_defaults(user_id,workspace_id,workflow_id,updated_at)
         VALUES(${context.userId},${userWorkspaceId},'chat',${new Date().toISOString()})
         ON CONFLICT(user_id,workspace_id) DO UPDATE SET workflow_id='chat',updated_at=excluded.updated_at`;
    }
  }
  return json({ configuration });
}
