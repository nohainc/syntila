import { dataOf } from "../../platform/data.js";
import {
  BUILTIN_WORKFLOW_CATALOG,
  DomainInvariantError,
  parseUserWorkflowConfiguration,
  type UserWorkflowConfiguration,
} from "@syntila/core";
import { HttpError, json, type SecurityEnv } from "./http-security.js";
import { spaceWorkflowDefault } from "../queries.js";

/**
 * Workflow configuration without a Workspace (ADR-035). Selections name Worker
 * IDs. Saved configurations that still hold legacy Workspace Worker IDs are
 * translated when read; a Worker that no longer exists is dropped from the
 * selection and reported, never silently replaced.
 */

export interface ConfigurationIssue {
  readonly workflowId: string;
  readonly stepId: string;
  readonly code: "worker_unavailable";
  readonly message: string;
}

function definitionFor(id: string) {
  const definition = Object.values(BUILTIN_WORKFLOW_CATALOG)
    .filter((entry) => entry.id === id)
    .sort((a, b) => b.version - a.version)[0];
  if (!definition) throw new HttpError(404, "Unknown workflow");
  return definition;
}

/** The owner's live Worker for an ID that is either a Worker ID or a legacy one. */
async function resolveWorker(env: SecurityEnv, ownerUserId: string, id: string): Promise<string | null> {
  const row = await dataOf(env).read.row<{ id: string }>`SELECT w.id FROM worker_instances w
     WHERE w.owner_user_id = ${ownerUserId} AND w.revoked_at IS NULL
       AND (w.id = ${id} OR w.id = (SELECT m.worker_instance_id FROM legacy_worker_mapping m WHERE m.legacy_worker_id = ${id}))
     ORDER BY (w.id = ${id}) DESC LIMIT 1`;
  return row?.id ?? null;
}

type Selection = Record<string, unknown> & { worker?: string };

async function translateSelection(
  env: SecurityEnv,
  ownerUserId: string,
  workflowId: string,
  stepId: string,
  selection: Selection | undefined,
  issues: ConfigurationIssue[],
): Promise<Selection | undefined> {
  if (!selection || typeof selection.worker !== "string") return selection;
  const worker = await resolveWorker(env, ownerUserId, selection.worker);
  if (worker) return { ...selection, worker };
  const { worker: _dropped, ...rest } = selection;
  issues.push({
    workflowId,
    stepId,
    code: "worker_unavailable",
    message: "The saved Worker is no longer available. Choose a Worker.",
  });
  return rest;
}

export async function translateConfiguration(
  env: SecurityEnv,
  ownerUserId: string,
  configuration: UserWorkflowConfiguration,
): Promise<{ configuration: UserWorkflowConfiguration; issues: ConfigurationIssue[] }> {
  const issues: ConfigurationIssue[] = [];
  const workflowId = configuration.workflowId;
  const defaults = (await translateSelection(env, ownerUserId, workflowId, "defaults", configuration.defaults as Selection, issues)) ?? {};
  const stepOverrides: Record<string, unknown> = {};
  for (const [stepId, selection] of Object.entries(configuration.stepOverrides)) {
    stepOverrides[stepId] = await translateSelection(env, ownerUserId, workflowId, stepId, selection as Selection, issues);
  }
  return {
    configuration: { ...configuration, defaults, stepOverrides } as UserWorkflowConfiguration,
    issues,
  };
}

async function loadOwn(env: SecurityEnv, userId: string, workflowId: string | undefined) {
  const filter = workflowId ?? null;
  const own = await dataOf(env).read.rows<{ workflow_id: string; configuration_json: string }>`SELECT workflow_id, configuration_json
     FROM user_worker_workflow_configurations
    WHERE user_id = ${userId} AND (${filter}::text IS NULL OR workflow_id = ${filter})`;
  // Older rows, saved against a Workspace, until the person saves again.
  const legacy = await dataOf(env).read.rows<{ workflow_id: string; configuration_json: string }>`SELECT DISTINCT ON (workflow_id) workflow_id, configuration_json
     FROM user_workflow_configurations
    WHERE user_id = ${userId} AND (${filter}::text IS NULL OR workflow_id = ${filter})
    ORDER BY workflow_id, updated_at DESC`;
  const byWorkflow = new Map(legacy.map((row) => [row.workflow_id, row.configuration_json]));
  for (const row of own) byWorkflow.set(row.workflow_id, row.configuration_json);
  return [...byWorkflow.values()].map((text) => JSON.parse(text) as UserWorkflowConfiguration);
}

async function loadSpace(env: SecurityEnv, spaceId: string, workflowId: string | undefined) {
  const filter = workflowId ?? null;
  const rows = await dataOf(env).read.rows<{ configuration_json: string }>`SELECT configuration_json
     FROM space_workflow_configurations
    WHERE space_id = ${spaceId} AND (${filter}::text IS NULL OR workflow_id = ${filter})`;
  return rows.map((row) => JSON.parse(row.configuration_json) as UserWorkflowConfiguration);
}

export async function handleWorkerWorkflowConfigurations(
  request: Request,
  env: SecurityEnv,
  userId: string,
  workflowId: string | undefined,
  spaceId: string | undefined,
): Promise<Response> {
  // A Space's Workers are its owner's; a person's own preferences are theirs.
  const ownerId = spaceId
    ? ((await dataOf(env).read.row<{ owner: string }>`SELECT owner_user_id AS owner FROM spaces WHERE id = ${spaceId}`)?.owner ?? userId)
    : userId;

  if (request.method === "GET") {
    if (workflowId) definitionFor(workflowId);
    const stored = spaceId ? await loadSpace(env, spaceId, workflowId) : await loadOwn(env, userId, workflowId);
    const configurations: UserWorkflowConfiguration[] = [];
    const issues: ConfigurationIssue[] = [];
    for (const configuration of stored) {
      const translated = await translateConfiguration(env, ownerId, configuration);
      configurations.push(translated.configuration);
      issues.push(...translated.issues);
    }
    const defaultWorkflowId = spaceId ? ((await spaceWorkflowDefault(dataOf(env).read, spaceId))?.workflowId ?? "chat") : "chat";
    return json({ schemaVersion: 1, defaultWorkflowId, configurations, issues });
  }

  if (!workflowId) throw new HttpError(405, "Choose a workflow for this operation");
  const definition = definitionFor(workflowId);
  const empty = parseUserWorkflowConfiguration(definition, {
    schemaVersion: 1,
    workflowId,
    enabled: true,
    defaults: {},
    stepOverrides: {},
  });

  if (request.method === "DELETE") {
    const q = dataOf(env).read;
    if (spaceId) await q.run`DELETE FROM space_workflow_configurations WHERE space_id = ${spaceId} AND workflow_id = ${workflowId}`;
    else {
      await q.run`DELETE FROM user_worker_workflow_configurations WHERE user_id = ${userId} AND workflow_id = ${workflowId}`;
      await q.run`DELETE FROM user_workflow_configurations WHERE user_id = ${userId} AND workflow_id = ${workflowId}`;
    }
    return json({ configuration: empty });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");

  let configuration: UserWorkflowConfiguration;
  try {
    configuration = parseUserWorkflowConfiguration(definition, await request.json());
  } catch (error) {
    if (error instanceof DomainInvariantError || error instanceof SyntaxError) throw new HttpError(400, error.message);
    throw error;
  }
  if (workflowId === "chat" && !configuration.enabled) throw new HttpError(400, "Chat workflow cannot be disabled");
  // Every named Worker must be one of the owner's live Workers, by Worker ID.
  for (const [stepId, selection] of Object.entries({ defaults: configuration.defaults, ...configuration.stepOverrides })) {
    const worker = (selection as Selection | undefined)?.worker;
    if (typeof worker !== "string") continue;
    const owned = await dataOf(env).read.row<{ id: string }>`SELECT id FROM worker_instances WHERE id = ${worker} AND owner_user_id = ${ownerId} AND revoked_at IS NULL`;
    if (!owned) throw new HttpError(400, `${stepId === "defaults" ? "Workflow" : stepId}: Worker is not available. Choose one of your Workers.`);
  }
  const saved = JSON.stringify(configuration);
  const now = new Date().toISOString();
  const q = dataOf(env).read;
  if (spaceId) {
    await q.run`INSERT INTO space_workflow_configurations (space_id, workflow_id, schema_version, configuration_json, updated_at)
       VALUES (${spaceId}, ${workflowId}, 1, ${saved}, ${now})
       ON CONFLICT (space_id, workflow_id) DO UPDATE SET configuration_json = excluded.configuration_json, updated_at = excluded.updated_at`;
  } else {
    await q.run`INSERT INTO user_worker_workflow_configurations (user_id, workflow_id, schema_version, configuration_json, updated_at)
       VALUES (${userId}, ${workflowId}, ${configuration.schemaVersion}, ${saved}, ${now})
       ON CONFLICT (user_id, workflow_id) DO UPDATE SET schema_version = excluded.schema_version, configuration_json = excluded.configuration_json, updated_at = excluded.updated_at`;
  }
  return json({ configuration });
}
