import { paidOwnerSql } from "../account-plan.js";
import {
  spaceModelOptions,
  spaceWorkerExecutionOptions,
} from "../worker-execution-options.js";
export {
  spaceModelOptions,
  spaceWorkerExecutionOptions,
} from "../worker-execution-options.js";
import { extractBearerToken } from "@syntila/security";
import { listWorkerProfiles } from "../worker-profile-registry.js";
import { HttpError, json, securityContext } from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import {
  loadEffectiveMemberAccess,
  restrictExecutionOptions,
  type WorkspaceMemberAccessPolicy,
} from "./workspace-member-access.js";
import { WorkspaceRuntimeAuthenticator } from "../workspace-gateway/runtime-authenticator.js";

export async function handleListWorkspaceWorkerInventory(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const params = new URL(request.url).searchParams;
  const workspaceId = params.get("workspaceId");
  const columns = `SELECT i.worker_id, i.workspace_id, ew.name AS workspace_name,
            i.worker_type_id, i.activation_state, i.readiness_state,
            i.readiness_issue_code, i.local_concurrency_limit,
            i.engine_version, i.profile_definition_id,
            i.profile_release_version, i.provider_tool_name,
            i.provider_tool_version, i.last_seen_at,
            catalog.display_name AS catalog_display_name,
            catalog.description AS catalog_description,
            catalog.lifecycle_state AS catalog_lifecycle_state,
            catalog.visibility_state AS catalog_visibility_state,
            COALESCE(current_profile.profile_json, history.profile_json) AS model_profile_json,
            COALESCE(current_profile.digest, history.digest) AS model_profile_digest,
            i.model_catalog_json
       FROM workspace_worker_inventory i
       JOIN execution_workspaces ew ON ew.id = i.workspace_id
       LEFT JOIN worker_catalog catalog ON catalog.worker_type_id = i.worker_type_id
       LEFT JOIN worker_profiles current_profile
         ON current_profile.worker_type_id = i.worker_type_id
        AND current_profile.revision = i.profile_release_version
       LEFT JOIN worker_profile_history history
         ON history.worker_type_id = i.worker_type_id
        AND history.revision = i.profile_release_version`;
  const rows = await env.SYNTILA_DB.prepare(
    `${columns}
      WHERE i.owner_user_id = ?1
        AND (?2 IS NULL OR i.workspace_id = ?2)
      ORDER BY i.workspace_id, i.worker_type_id, i.worker_id`,
  )
    .bind(context.userId, workspaceId)
    .all<Record<string, unknown>>();
  const owned = (rows.results ?? []).map((row) =>
    projectInventoryRow(row, null),
  );
  // Space members and people a Workspace is lent to also see what the owner
  // shares with them: the Workers of those Workspaces, limited by the owner's
  // member-access policy. Only clients that ask for it receive them.
  const shared: unknown[] = [];
  if (params.get("includeShared") === "true") {
    const sharedRows = await env.SYNTILA_DB.prepare(
      `${columns}
        WHERE ew.status != 'revoked'
          AND i.owner_user_id <> ?1
          AND (?2 IS NULL OR i.workspace_id = ?2)
          AND (EXISTS (
            SELECT 1
              FROM space_memberships m
              JOIN spaces s ON s.id = m.space_id
              LEFT JOIN space_workflow_settings sws ON sws.space_id = s.id
              LEFT JOIN user_workflow_settings uws ON uws.user_id = s.owner_user_id
             WHERE m.user_id = ?1 AND s.owner_user_id <> ?1
               -- A Workspace lent to the Space owner is not passed on to
               -- their Space members (ADR-020: grants are non-transferable).
               AND s.owner_user_id = i.owner_user_id
               AND i.workspace_id = CASE WHEN sws.space_id IS NOT NULL THEN sws.workspace_id ELSE uws.workspace_id END)
            OR i.workspace_id IN (
            SELECT g.workspace_id FROM workspace_person_grants g
              JOIN execution_workspaces gw ON gw.id = g.workspace_id
             WHERE g.user_id = ?1 AND g.status = 'active'
               AND ${paidOwnerSql("gw.owner_user_id")}))
        ORDER BY i.workspace_id, i.worker_type_id, i.worker_id`,
    )
      .bind(context.userId, workspaceId)
      .all<Record<string, unknown>>();
    const policies = new Map<string, WorkspaceMemberAccessPolicy | null>();
    for (const row of sharedRows.results ?? []) {
      const id = String(row.workspace_id);
      if (!policies.has(id))
        policies.set(
          id,
          await loadEffectiveMemberAccess(env, id, context.userId),
        );
      const policy = policies.get(id)!;
      const entry = policy?.workers[String(row.worker_id)];
      // A restricted Workspace shares only the Workers it lists.
      if (policy && !entry) continue;
      shared.push(projectInventoryRow(row, entry ?? null, true));
    }
  }
  return json({ workers: [...owned, ...shared] });
}

function projectInventoryRow(
  row: Record<string, unknown>,
  shared: WorkspaceMemberAccessPolicy["workers"][string] | null,
  masked = false,
) {
  const executionOptions = spaceWorkerExecutionOptions(
    row.model_profile_json,
    row.provider_tool_version,
    row.model_catalog_json,
    row.model_profile_digest,
  );
  return {
    executionOptions: shared
      ? restrictExecutionOptions(executionOptions, shared)
      : executionOptions,
    // The legacy projection is unused by clients; do not widen what members see.
    modelOptions: masked
      ? null
      : spaceModelOptions(
          row.model_profile_json,
          row.provider_tool_version,
          row.model_catalog_json,
          row.model_profile_digest,
        ),
    id: String(row.worker_id),
    workspaceId: String(row.workspace_id),
    workspaceName: String(row.workspace_name),
    // Shared Workers belong to someone else; only owned ones may answer Chat
    // as the viewer's own Worker in a Space.
    shared: masked,
    workerTypeId: String(row.worker_type_id),
    displayName:
      row.catalog_display_name == null
        ? String(row.worker_type_id)
        : String(row.catalog_display_name),
    description:
      row.catalog_description == null ? null : String(row.catalog_description),
    catalogLifecycleState:
      row.catalog_lifecycle_state == null
        ? "retired"
        : String(row.catalog_lifecycle_state),
    catalogVisibilityState:
      row.catalog_visibility_state == null
        ? "hidden"
        : String(row.catalog_visibility_state),
    activationState: String(row.activation_state),
    readinessState: String(row.readiness_state),
    readinessIssueCode:
      row.readiness_issue_code == null
        ? null
        : String(row.readiness_issue_code),
    localConcurrencyLimit: Number(row.local_concurrency_limit),
    // Machine and provider details stay with the Workspace owner.
    engineVersion:
      masked || row.engine_version == null ? null : String(row.engine_version),
    profileDefinitionId:
      row.profile_definition_id == null
        ? null
        : String(row.profile_definition_id),
    profileReleaseVersion:
      row.profile_release_version == null
        ? null
        : Number(row.profile_release_version),
    providerToolName:
      masked || row.provider_tool_name == null
        ? null
        : String(row.provider_tool_name),
    providerToolVersion:
      masked || row.provider_tool_version == null
        ? null
        : String(row.provider_tool_version),
    lastSeenAt: String(row.last_seen_at),
  };
}

async function requireWorkspaceRuntime(
  request: Request,
  env: SecurityEnv,
): Promise<void> {
  const url = new URL(request.url);
  const runtimeId = url.searchParams.get("workspaceRuntimeId");
  const credential = extractBearerToken(request.headers);
  if (!runtimeId || !credential)
    throw new HttpError(401, "Workspace runtime credentials are required");
  const runtime = await new WorkspaceRuntimeAuthenticator(
    env.SYNTILA_DB,
  ).authenticateRuntime(runtimeId, credential);
  if (!runtime)
    throw new HttpError(401, "Workspace runtime credential is invalid");
}

export async function handleListWorkspaceWorkerCatalog(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  await requireWorkspaceRuntime(request, env);
  return json(await listWorkerProfiles(env.SYNTILA_DB));
}

export async function handleListWorkerCatalog(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  await securityContext(request, env, ctx);
  return json(await listWorkerProfiles(env.SYNTILA_DB));
}
