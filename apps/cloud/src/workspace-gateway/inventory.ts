import {
  PluginInventoryExecutorSchema,
  WorkspaceAllowedFolderSchema,
  WorkspaceWorkerInventoryEntrySchema,
} from "@syntila/workspace-runtime-protocol";
import type { WorkspaceGatewayEnv } from "./contracts.js";

/** Persists the Workspace-owned logical Worker snapshot and prunes omissions. */
export async function recordWorkspaceWorkerInventory(
  env: WorkspaceGatewayEnv,
  workspaceId: string | null,
  payload: unknown,
): Promise<void> {
  if (!workspaceId || !payload || typeof payload !== "object") return;
  const reports = (payload as Record<string, unknown>).workers;
  if (!Array.isArray(reports) || reports.length > 500) return;
  const ids = reports.map((item) =>
    item && typeof item === "object" ? item.workerId : undefined,
  );
  if (new Set(ids).size !== ids.length) return;
  const owner = await env.SYNTILA_DB.prepare(
    "SELECT owner_user_id FROM execution_workspaces WHERE id = ?1 AND status != 'revoked'",
  )
    .bind(workspaceId)
    .first<{ owner_user_id: string }>();
  if (!owner) return;
  const now = new Date().toISOString();
  const fullSnapshot =
    (payload as Record<string, unknown>).fullSnapshot === true;
  const reportedWorkerIds = new Set<string>();
  // Slots are owned by Cloud and set on the web Workspaces page. A Service
  // that still reports its old local value only seeds a Workspace that has
  // none yet, so the owner's existing limit carries over; it never overrides.
  const parallelSlots = (payload as Record<string, unknown>).parallelSlots;
  if (
    typeof parallelSlots === "number" &&
    Number.isInteger(parallelSlots) &&
    parallelSlots >= 1 &&
    parallelSlots <= 1024
  ) {
    await env.SYNTILA_DB.prepare(
      `UPDATE execution_workspaces SET parallel_slots = ?2, updated_at = ?3
        WHERE id = ?1 AND parallel_slots IS NULL`,
    )
      .bind(workspaceId, parallelSlots, now)
      .run();
  }
  await recordWorkspaceAllowedFolders(
    env,
    workspaceId,
    (payload as Record<string, unknown>).allowedFolders,
    now,
  );
  for (const raw of reports) {
    if (!raw || typeof raw !== "object") continue;
    const item = raw as Record<string, unknown>;
    const workerId = item.workerId;
    const workerTypeId = item.workerTypeId;
    const activationState = item.activationState;
    const readinessState = item.readinessState;
    const revision = item.revision;
    const concurrency = item.localConcurrencyLimit;
    if (
      typeof workerId !== "string" ||
      typeof workerTypeId !== "string" ||
      !["enabled", "disabled"].includes(String(activationState)) ||
      ![
        "not_probed",
        "ready",
        "setup_required",
        "sign_in_required",
        "worker_runtime_unavailable",
        "test_failed",
      ].includes(String(readinessState)) ||
      !Number.isSafeInteger(revision) ||
      (revision as number) < 1 ||
      !Number.isInteger(concurrency) ||
      (concurrency as number) < 1
    ) {
      continue;
    }
    // Plugin Workers (ADR-027) carry an `executor` and use a plugin-shaped type
    // ID. The two must agree, and the plugin must be in the Workspace owner's
    // own library: a Workspace can neither claim another account's plugin nor
    // give an official Worker an executor.
    const pluginShaped = /^plugin-[0-9a-f]{12}$/.test(workerTypeId);
    let executorJson: string | null = null;
    if (item.executor !== undefined) {
      const executor = PluginInventoryExecutorSchema.safeParse(item.executor);
      if (!executor.success || !pluginShaped) continue;
      const owned = await env.SYNTILA_DB.prepare(
        `SELECT 1 AS ok FROM worker_catalog
          WHERE worker_type_id = ?1 AND origin = 'plugin' AND owner_user_id = ?2`,
      )
        .bind(workerTypeId, owner.owner_user_id)
        .first();
      if (!owned) continue;
      executorJson = JSON.stringify(executor.data);
    } else if (pluginShaped) {
      continue;
    }
    const previous = await env.SYNTILA_DB.prepare(
      "SELECT workspace_id, revision, model_catalog_json FROM workspace_worker_inventory WHERE worker_id = ?1",
    )
      .bind(workerId)
      .first<{
        workspace_id: string;
        revision: number;
        model_catalog_json: string | null;
      }>();
    // A Worker ID is permanently owned by the Workspace that first synced
    // it, and its local revision only moves forward. Releasing a Workspace
    // deletes its Workers, so a new registration starts clean.
    if (previous && previous.workspace_id !== workspaceId) {
      continue;
    }
    // Structurally valid entries count as reported even when their revision
    // is unchanged. Malformed entries cannot keep omitted Workers alive.
    reportedWorkerIds.add(workerId);
    if (previous && Number(previous.revision) >= (revision as number)) {
      if (Number(previous.revision) === revision) {
        await env.SYNTILA_DB.prepare(
          `UPDATE workspace_worker_inventory SET last_seen_at = ?3
              WHERE worker_id = ?1 AND workspace_id = ?2 AND revision = ?4`,
        )
          .bind(workerId, workspaceId, now, revision)
          .run();
      }
      continue;
    }
    const nullableText = (value: unknown, max: number): string | null =>
      typeof value === "string" && value.trim().length <= max
        ? value.trim() || null
        : null;
    const nullableSafeToken = (
      value: unknown,
      pattern: RegExp,
    ): string | null =>
      typeof value === "string" && pattern.test(value.trim())
        ? value.trim()
        : null;
    const readinessIssueCode =
      typeof item.readinessIssueCode === "string" &&
      /^[a-z][a-z0-9_]{0,127}$/.test(item.readinessIssueCode)
        ? item.readinessIssueCode
        : null;
    const validatedCatalog =
      WorkspaceWorkerInventoryEntrySchema.shape.modelCatalog.safeParse(
        item.modelCatalog,
      );
    // Inventory credentials identify the Workspace; the current Profile
    // snapshot binds capability metadata to this Worker and exact revision.
    let acceptedCatalog = validatedCatalog.success
      ? validatedCatalog.data
      : null;
    if (acceptedCatalog) {
      let expectedDigest: string | undefined;
      if (executorJson) {
        const executor = JSON.parse(executorJson);
        const pin = await env.SYNTILA_DB.prepare(
          `SELECT manifest_digest FROM workspace_worker_plugin_enablements
           WHERE workspace_id = ?1 AND plugin_ref = ?2 AND version = ?3 AND intent = 'enabled'`,
        )
          .bind(workspaceId, workerTypeId, executor.version)
          .first<{ manifest_digest: string }>();
        if (
          pin &&
          pin.manifest_digest === executor.manifestDigest &&
          executor.version === item.providerToolVersion
        )
          expectedDigest = pin.manifest_digest;
      } else {
        const profile = await env.SYNTILA_DB.prepare(
          `SELECT digest FROM worker_profiles WHERE worker_type_id = ?1 AND revision = ?2
           UNION ALL SELECT digest FROM worker_profile_history
           WHERE worker_type_id = ?1 AND revision = ?2 LIMIT 1`,
        )
          .bind(workerTypeId, item.profileReleaseVersion ?? null)
          .first<{ digest: string }>();
        expectedDigest = profile?.digest;
      }
      if (
        !expectedDigest ||
        acceptedCatalog.profileDigest !== expectedDigest ||
        acceptedCatalog.providerToolVersion !== item.providerToolVersion
      )
        acceptedCatalog = null;
      // Once a Worker publishes v2, legacy data cannot replace it. Clearing
      // capabilities blocks execution until the service refreshes its catalog.
      if (
        acceptedCatalog?.schemaVersion === 1 &&
        previous?.model_catalog_json
      ) {
        try {
          const old = JSON.parse(previous.model_catalog_json);
          if (old.schemaVersion === 2)
            acceptedCatalog =
              old.profileDigest === acceptedCatalog.profileDigest &&
              old.providerToolVersion === acceptedCatalog.providerToolVersion
                ? { ...old, stale: true }
                : null;
        } catch {
          /* Corrupt historical metadata is never reused. */
        }
      }
    }
    await env.SYNTILA_DB.prepare(
      `INSERT INTO workspace_worker_inventory
          (worker_id, workspace_id, owner_user_id, worker_type_id,
           activation_state, readiness_state, readiness_issue_code,
           engine_version, profile_definition_id, profile_release_version,
           provider_tool_name, provider_tool_version,
           local_concurrency_limit, revision,
           created_at, updated_at, last_seen_at, model_catalog_json,
           executor_json)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
         ON CONFLICT(worker_id) DO UPDATE SET
           worker_type_id = excluded.worker_type_id,
           activation_state = excluded.activation_state,
           readiness_state = excluded.readiness_state,
           readiness_issue_code = excluded.readiness_issue_code,
           engine_version = excluded.engine_version,
           profile_definition_id = excluded.profile_definition_id,
           profile_release_version = excluded.profile_release_version,
           provider_tool_name = excluded.provider_tool_name,
           provider_tool_version = excluded.provider_tool_version,
           model_catalog_json = excluded.model_catalog_json,
           executor_json = excluded.executor_json,
           local_concurrency_limit = excluded.local_concurrency_limit,
           revision = excluded.revision,
           updated_at = excluded.updated_at,
           last_seen_at = excluded.last_seen_at
         WHERE workspace_worker_inventory.workspace_id = excluded.workspace_id
           AND workspace_worker_inventory.revision < excluded.revision`,
    )
      .bind(
        workerId,
        workspaceId,
        owner.owner_user_id,
        workerTypeId,
        activationState,
        readinessState,
        readinessIssueCode,
        nullableSafeToken(
          item.engineVersion,
          /^[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}$/,
        ),
        typeof item.profileDefinitionId === "string" &&
          /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(item.profileDefinitionId) &&
          item.profileDefinitionId.length <= 96
          ? item.profileDefinitionId
          : null,
        Number.isSafeInteger(item.profileReleaseVersion) &&
          (item.profileReleaseVersion as number) > 0
          ? item.profileReleaseVersion
          : null,
        nullableSafeToken(
          item.providerToolName,
          /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$/,
        ),
        nullableSafeToken(
          item.providerToolVersion,
          /^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$/,
        ),
        Math.min(1024, concurrency as number),
        revision,
        nullableText(item.createdAt, 40) ?? now,
        now,
        nullableText(item.lastSeenAt, 40) ?? now,
        acceptedCatalog ? JSON.stringify(acceptedCatalog) : null,
        executorJson,
      )
      .run();
    await env.SYNTILA_DB.prepare(
      `INSERT OR IGNORE INTO worker_scheduling (worker_id, state, updated_at)
         SELECT worker_id, 'disabled', ?2 FROM workspace_worker_inventory WHERE worker_id = ?1`,
    )
      .bind(workerId, now)
      .run();
  }
  // Full snapshots are authoritative. Removed local slots disappear from
  // inventory; scheduling and audit rows cascade with the inventory row.
  if (fullSnapshot) {
    const existing = await env.SYNTILA_DB.prepare(
      `SELECT worker_id FROM workspace_worker_inventory
          WHERE workspace_id = ?1`,
    )
      .bind(workspaceId)
      .all<{ worker_id: string }>();
    for (const row of existing.results ?? []) {
      if (reportedWorkerIds.has(row.worker_id)) continue;
      await env.SYNTILA_DB.prepare(
        `DELETE FROM workspace_worker_inventory
            WHERE worker_id = ?1 AND workspace_id = ?2`,
      )
        .bind(row.worker_id, workspaceId)
        .run();
    }
  }
  // Workspace selection authorizes scheduling for ready, locally enabled
  // Workers, including ones configured after the Workspace was selected.
  // Reconcile even unchanged reports so an existing disabled row can recover.
  await env.SYNTILA_DB.prepare(
    `UPDATE worker_scheduling
        SET state = 'enabled', updated_at = ?2
      WHERE state = 'disabled'
        AND worker_id IN (
          SELECT i.worker_id FROM workspace_worker_inventory i
           WHERE i.workspace_id = ?1
             AND i.activation_state = 'enabled'
             AND i.readiness_state = 'ready'
             AND EXISTS (SELECT 1 FROM space_workflow_settings s
                          WHERE s.workspace_id = i.workspace_id)
        )`,
  )
    .bind(workspaceId, now)
    .run();
}

/**
 * Replaces the Workspace's Allowed Folders with the reported list. An omitted
 * or malformed list keeps the stored one. Removed folders are detached from
 * every Space; local files are never affected.
 */
export async function recordWorkspaceAllowedFolders(
  env: WorkspaceGatewayEnv,
  workspaceId: string,
  reported: unknown,
  now: string,
): Promise<void> {
  if (!Array.isArray(reported) || reported.length > 32) return;
  const folders = [];
  for (const entry of reported) {
    const parsed = WorkspaceAllowedFolderSchema.safeParse(entry);
    if (!parsed.success) return;
    folders.push(parsed.data);
  }
  if (new Set(folders.map((folder) => folder.id)).size !== folders.length)
    return;
  const db = env.SYNTILA_DB;
  const existing = await db
    .prepare(
      "SELECT folder_id FROM workspace_allowed_folders WHERE workspace_id = ?1",
    )
    .bind(workspaceId)
    .all<{ folder_id: string }>();
  const keep = new Set(folders.map((folder) => folder.id));
  for (const row of existing.results ?? []) {
    if (keep.has(row.folder_id)) continue;
    await db
      .prepare(
        "DELETE FROM space_additional_folders WHERE workspace_id = ?1 AND folder_id = ?2",
      )
      .bind(workspaceId, row.folder_id)
      .run();
    await db
      .prepare(
        "DELETE FROM workspace_allowed_folders WHERE workspace_id = ?1 AND folder_id = ?2",
      )
      .bind(workspaceId, row.folder_id)
      .run();
  }
  for (const folder of folders) {
    await db
      .prepare(
        `INSERT INTO workspace_allowed_folders
            (workspace_id, folder_id, display_name, status, checked_at, updated_at)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6)
          ON CONFLICT(workspace_id, folder_id) DO UPDATE SET
            display_name = excluded.display_name,
            status = excluded.status,
            checked_at = excluded.checked_at,
            updated_at = excluded.updated_at`,
      )
      .bind(
        workspaceId,
        folder.id,
        folder.displayName,
        folder.status,
        folder.checkedAt,
        now,
      )
      .run();
  }
}
