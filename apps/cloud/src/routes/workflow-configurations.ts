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
    const membership = await db
      .prepare(
        `SELECT s.owner_user_id AS ownerUserId FROM spaces s JOIN space_memberships m ON m.space_id = s.id JOIN users u ON u.id = m.user_id WHERE s.id = ?1 AND m.user_id = ?2 AND u.status = 'active'`,
      )
      .bind(spaceId, context.userId)
      .first<{ ownerUserId: string }>();
    if (!membership) throw new HttpError(403, "Space membership required");
    if (request.method !== "GET" && membership.ownerUserId !== context.userId)
      throw new HttpError(403, "Only the Space owner can configure workflows");
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
    const rows = await db
      .prepare(
        `SELECT configuration_json FROM user_workflow_configurations
      WHERE user_id = ?1 AND workspace_id = ?3 AND (?2 IS NULL OR workflow_id = ?2)`,
      )
      .bind(context.userId, workflowId ?? null, userWorkspaceId)
      .all<{ configuration_json: string }>();
    return json({
      schemaVersion: 1,
      workspaceId: userWorkspaceId,
      defaultWorkflowId: await loadUserWorkflowDefault(
        env,
        context.userId,
        userWorkspaceId,
      ),
      configurations: rows.results.map((row) =>
        JSON.parse(row.configuration_json),
      ),
    });
  }
  if (!workflowId)
    throw new HttpError(405, "Choose a workflow for this operation");
  const definition = definitionFor(workflowId);
  const reset = async () => {
    await db
      .prepare(
        `DELETE FROM ${table} WHERE ${key} = ?1 AND workflow_id = ?2${scopeSql}`,
      )
      .bind(owner, workflowId, ...scopeBinds)
      .run();
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
  const previous = await db
    .prepare(
      `SELECT configuration_json FROM ${table} WHERE ${key} = ?1 AND workflow_id = ?2${scopeSql}`,
    )
    .bind(owner, workflowId, ...scopeBinds)
    .first<{ configuration_json: string }>();
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
    await db
      .prepare(
        spaceId
          ? `INSERT INTO ${table}
      (${key}, workflow_id, schema_version, configuration_json, updated_at) VALUES (?1, ?2, 1, ?3, ?4)
      ON CONFLICT(${key}, workflow_id) DO UPDATE SET configuration_json = excluded.configuration_json, updated_at = excluded.updated_at`
          : `INSERT INTO ${table}
      (${key}, workflow_id, schema_version, configuration_json, updated_at, workspace_id) VALUES (?1, ?2, 1, ?3, ?4, ?5)
      ON CONFLICT(${key}, workspace_id, workflow_id) DO UPDATE SET configuration_json = excluded.configuration_json, updated_at = excluded.updated_at`,
      )
      .bind(
        owner,
        workflowId,
        JSON.stringify(configuration),
        new Date().toISOString(),
        ...scopeBinds,
      )
      .run();
  }
  const defaultWorkflowId = spaceId
    ? await loadSpaceWorkflowDefault(env, spaceId, owner)
    : await loadUserWorkflowDefault(env, context.userId, userWorkspaceId);
  if (defaultWorkflowId === workflowId && !configuration.enabled) {
    if (spaceId) {
      await env.SYNTILA_DB.prepare(
        `INSERT INTO space_workflow_defaults(space_id,workflow_id,updated_at)
         VALUES(?1,'chat',?2)
         ON CONFLICT(space_id) DO UPDATE SET workflow_id='chat',updated_at=excluded.updated_at`,
      )
        .bind(spaceId, new Date().toISOString())
        .run();
    } else {
      await env.SYNTILA_DB.prepare(
        `INSERT INTO user_workflow_defaults(user_id,workspace_id,workflow_id,updated_at)
         VALUES(?1,?3,'chat',?2)
         ON CONFLICT(user_id,workspace_id) DO UPDATE SET workflow_id='chat',updated_at=excluded.updated_at`,
      )
        .bind(context.userId, new Date().toISOString(), userWorkspaceId)
        .run();
    }
  }
  return json({ configuration });
}
