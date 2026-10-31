import { paidOwnerSql } from "../account-plan.js";
import { publishCollaborationEvent } from "../collaboration-events.js";
import {
  securityContext,
  HttpError,
  json,
  type SecurityEnv,
} from "./http-security.js";

export async function loadWorkflowWorkspace(
  env: Pick<SecurityEnv, "SYNTILA_DB">,
  userId: string,
  spaceId?: string,
) {
  const global = await env.SYNTILA_DB.prepare(
    "SELECT workspace_id AS workspaceId FROM user_workflow_settings WHERE user_id = ?1",
  )
    .bind(userId)
    .first<{ workspaceId: string | null }>();
  const space = spaceId
    ? await env.SYNTILA_DB.prepare(
        "SELECT workspace_id AS workspaceId FROM space_workflow_settings WHERE space_id = ?1",
      )
        .bind(spaceId)
        .first<{ workspaceId: string | null }>()
    : null;
  return {
    workspaceId: space ? space.workspaceId : (global?.workspaceId ?? null),
    inherited: Boolean(spaceId && !space),
  };
}
/**
 * Workspace a user-level workflow request addresses: the explicit one when
 * given, otherwise the user's selected Workspace. An explicit Workspace must be
 * owned by the user or lent to them, and not revoked.
 */
export async function resolveUserWorkflowWorkspace(
  env: Pick<SecurityEnv, "SYNTILA_DB">,
  userId: string,
  requested: string | null,
): Promise<string | null> {
  if (!requested) return (await loadWorkflowWorkspace(env, userId)).workspaceId;
  const owned = await env.SYNTILA_DB.prepare(
    "SELECT id FROM execution_workspaces WHERE id=?1 AND owner_user_id=?2 AND status != 'revoked'",
  )
    .bind(requested, userId)
    .first();
  if (
    !owned &&
    !(await loadBorrowedWorkspaces(env, userId)).some(
      (workspace) => workspace.id === requested,
    )
  )
    throw new HttpError(404, "Workspace not found");
  return requested;
}

/** Workspaces lent to this person by an active Person Grant (ADR-020). */
export async function loadBorrowedWorkspaces(
  env: Pick<SecurityEnv, "SYNTILA_DB">,
  userId: string,
) {
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT ew.id, ew.name, ew.owner_user_id AS ownerUserId
     FROM workspace_person_grants g
     JOIN execution_workspaces ew ON ew.id = g.workspace_id AND ew.status != 'revoked'
     WHERE g.user_id = ?1 AND g.status = 'active'
       AND ${paidOwnerSql("ew.owner_user_id")}
     ORDER BY ew.name, ew.id`,
  )
    .bind(userId)
    .all<{ id: string; name: string; ownerUserId: string }>();
  return rows.results ?? [];
}

/** A lent Workspace answers only its borrower's Chat, which reads only. */
const BORROWED_PERMISSIONS = ["repository:read"];

/**
 * Selection is restricted to Workspaces owned by this user, or lent to them by
 * an active Person Grant, and to Spaces they own. A lent Workspace never has
 * its Worker scheduling changed by the borrower, and its Space grant is made
 * by the lender with permissions capped by the borrower's mode.
 */
export async function prepareWorkflowWorkspaceGrant(
  env: SecurityEnv,
  ownerUserId: string,
  spaceId: string,
  workspaceId: string,
  now: string,
): Promise<D1PreparedStatement[]> {
  const owned = await env.SYNTILA_DB.prepare(
    "SELECT id FROM execution_workspaces WHERE id=?1 AND owner_user_id=?2 AND status != 'revoked'",
  )
    .bind(workspaceId, ownerUserId)
    .first();
  const lent = owned
    ? null
    : (await loadBorrowedWorkspaces(env, ownerUserId)).find(
        (workspace) => workspace.id === workspaceId,
      );
  if (!owned && !lent)
    throw new HttpError(
      403,
      "Workspace is unavailable or not owned by the settings owner",
    );
  const existing = await env.SYNTILA_DB.prepare(
    "SELECT id,status,expires_at FROM workspace_space_grants WHERE space_id=?1 AND workspace_id=?2 AND status IN ('active','suspended')",
  )
    .bind(spaceId, workspaceId)
    .first<{ id: string; status: string; expires_at: string | null }>();
  if (
    existing?.status === "suspended" ||
    (existing?.expires_at && existing.expires_at <= now)
  )
    throw new HttpError(
      409,
      "The selected Workspace grant is suspended or expired",
    );
  if (lent) {
    if (existing) return [];
    return [
      env.SYNTILA_DB.prepare(
        "INSERT INTO workspace_space_grants(id,space_id,workspace_id,granted_by_user_id,status,allowed_permissions_json,concurrency_json,created_at,updated_at) VALUES(?1,?2,?3,?4,'active',?5,'{\"maxConcurrentAssignments\":1}',?6,?6)",
      ).bind(
        crypto.randomUUID(),
        spaceId,
        workspaceId,
        lent.ownerUserId,
        JSON.stringify(BORROWED_PERMISSIONS),
        now,
      ),
      env.SYNTILA_DB.prepare(
        "INSERT INTO space_audit_log(id,space_id,actor_type,actor_id,action,target_type,target_id,details_json,created_at) VALUES(?1,?2,'user',?3,'workflow.workspace.authorized','execution_workspace',?4,?5,?6)",
      ).bind(
        crypto.randomUUID(),
        spaceId,
        ownerUserId,
        workspaceId,
        JSON.stringify({ workspaceId, lent: true }),
        now,
      ),
    ];
  }
  const statements: D1PreparedStatement[] = [
    // Selecting a Workflow Workspace is the user-facing execution boundary.
    // Ready, locally enabled Workers there are available to Cloud scheduling;
    // no second hidden scheduling toggle is required for Workflows.
    env.SYNTILA_DB.prepare(
      `UPDATE worker_scheduling
          SET state='enabled', updated_by_user_id=?2, updated_at=?3
        WHERE worker_id IN (
          SELECT worker_id FROM workspace_worker_inventory
           WHERE workspace_id=?1
             AND activation_state='enabled'
             AND readiness_state='ready'
        )
          AND state <> 'draining'`,
    ).bind(workspaceId, ownerUserId, now),
  ];
  if (existing) return statements;
  statements.push(
    env.SYNTILA_DB.prepare(
      "INSERT INTO workspace_space_grants(id,space_id,workspace_id,granted_by_user_id,status,allowed_permissions_json,concurrency_json,created_at,updated_at) VALUES(?1,?2,?3,?4,'active',?5,'{\"maxConcurrentAssignments\":3}',?6,?6)",
    ).bind(
      crypto.randomUUID(),
      spaceId,
      workspaceId,
      ownerUserId,
      JSON.stringify(["repository:read", "repository:write", "shell:execute"]),
      now,
    ),
    env.SYNTILA_DB.prepare(
      "INSERT INTO space_audit_log(id,space_id,actor_type,actor_id,action,target_type,target_id,details_json,created_at) VALUES(?1,?2,'user',?3,'workflow.workspace.authorized','execution_workspace',?4,?5,?6)",
    ).bind(
      crypto.randomUUID(),
      spaceId,
      ownerUserId,
      workspaceId,
      JSON.stringify({ workspaceId }),
      now,
    ),
  );
  return statements;
}

export async function handleWorkflowWorkspace(
  request: Request,
  env: SecurityEnv,
  spaceId?: string,
  ctx?: ExecutionContext,
) {
  const context = await securityContext(request, env, ctx);
  let ownerUserId = context.userId;
  if (spaceId) {
    const space = await env.SYNTILA_DB.prepare(
      "SELECT s.owner_user_id AS ownerUserId FROM spaces s JOIN space_memberships m ON m.space_id = s.id WHERE s.id = ?1 AND m.user_id = ?2",
    )
      .bind(spaceId, context.userId)
      .first<{ ownerUserId: string }>();
    if (!space) throw new HttpError(403, "Space membership required");
    ownerUserId = space.ownerUserId;
    if (request.method !== "GET" && ownerUserId !== context.userId)
      throw new HttpError(
        403,
        "Only the Space owner can select its workflow Workspace",
      );
  }
  const current = await loadWorkflowWorkspace(env, ownerUserId, spaceId);
  const owned = await env.SYNTILA_DB.prepare(
    "SELECT id, name FROM execution_workspaces WHERE owner_user_id = ?1 AND status != 'revoked' ORDER BY name, id",
  )
    .bind(ownerUserId)
    .all<{ id: string; name: string }>();
  // A Space, and the user-level default, may also run on a Workspace lent to
  // its owner; each Space then receives a grant capped by the borrower's mode.
  const choices = {
    results: [
      ...owned.results,
      ...(await loadBorrowedWorkspaces(env, ownerUserId)).map(
        ({ id, name }) => ({ id, name }),
      ),
    ],
  };
  if (request.method === "GET") {
    if (current.workspaceId && spaceId) {
      try {
        await env.SYNTILA_DB.batch(
          await prepareWorkflowWorkspaceGrant(
            env,
            ownerUserId,
            spaceId,
            current.workspaceId,
            new Date().toISOString(),
          ),
        );
      } catch (error) {
        // Reading never fails on the grant: a Workspace that is revoked,
        // no longer lent, or whose grant is suspended or expired stays
        // readable so the owner can see and change the selection.
        if (!(error instanceof HttpError)) throw error;
      }
    }
    return json({
      ...current,
      workspaces:
        context.userId === ownerUserId
          ? choices.results
          : choices.results.filter(
              (workspace) => workspace.id === current.workspaceId,
            ),
    });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");
  const body = (await request.json().catch(() => null)) as Record<
    string,
    unknown
  >;
  if (
    !body ||
    typeof body !== "object" ||
    Array.isArray(body) ||
    Object.keys(body).some(
      (k) => !["workspaceId", "confirmReset", "inherit"].includes(k),
    ) ||
    (body.inherit !== undefined && typeof body.inherit !== "boolean")
  )
    throw new HttpError(400, "Invalid Workspace selection");
  if (body.inherit && !spaceId)
    throw new HttpError(
      400,
      "Only a Space may inherit global Workspace selection",
    );
  if (
    !body.inherit &&
    body.workspaceId !== null &&
    typeof body.workspaceId !== "string"
  )
    throw new HttpError(400, "Choose a Workspace");
  const selected = body.inherit
    ? (await loadWorkflowWorkspace(env, ownerUserId)).workspaceId
    : (body.workspaceId as string | null);
  if (selected && !choices.results.some((w) => w.id === selected))
    throw new HttpError(403, "Workspace is not owned by the settings owner");
  const changed =
    selected !== current.workspaceId ||
    Boolean(body.inherit) !== current.inherited;
  const resetToGlobal = Boolean(body.inherit && spaceId && current.inherited);
  if (!changed && !resetToGlobal)
    return json({ ...current, workspaces: choices.results });
  // User configuration is stored per Workspace, so a global switch only
  // discards overrides of Spaces that inherit the global Workspace.
  const inheritingOverrides = spaceId
    ? 0
    : ((
        await env.SYNTILA_DB.prepare(
          "SELECT COUNT(*) AS n FROM space_workflow_configurations WHERE space_id IN (SELECT s.id FROM spaces s WHERE s.owner_user_id=?1 AND NOT EXISTS (SELECT 1 FROM space_workflow_settings ws WHERE ws.space_id=s.id))",
        )
          .bind(ownerUserId)
          .first<{ n: number }>()
      )?.n ?? 0);
  if ((spaceId || inheritingOverrides > 0) && body.confirmReset !== true)
    throw new HttpError(
      409,
      "Changing Workspace resets Space workflow overrides; confirmReset is required",
    );
  const db = env.SYNTILA_DB;
  const now = new Date().toISOString();
  const statements: D1PreparedStatement[] = [];
  if (spaceId) {
    if (body.inherit)
      statements.push(
        db
          .prepare("DELETE FROM space_workflow_settings WHERE space_id = ?1")
          .bind(spaceId),
      );
    else
      statements.push(
        db
          .prepare(
            "INSERT INTO space_workflow_settings(space_id,workspace_id,updated_at) VALUES(?1,?2,?3) ON CONFLICT(space_id) DO UPDATE SET workspace_id=excluded.workspace_id,updated_at=excluded.updated_at",
          )
          .bind(spaceId, selected, now),
      );
    statements.push(
      db
        .prepare(
          "DELETE FROM space_workflow_configurations WHERE space_id = ?1",
        )
        .bind(spaceId),
    );
    // Additional folders belong to one Workspace; switching detaches them.
    // Local files are untouched.
    statements.push(
      db
        .prepare(
          "DELETE FROM space_additional_folders WHERE space_id = ?1 AND workspace_id IS NOT ?2",
        )
        .bind(spaceId, selected),
    );
    statements.push(
      db
        .prepare("DELETE FROM space_workflow_defaults WHERE space_id = ?1")
        .bind(spaceId),
    );
    if (selected)
      statements.push(
        ...(await prepareWorkflowWorkspaceGrant(
          env,
          ownerUserId,
          spaceId,
          selected,
          now,
        )),
      );
  } else {
    statements.push(
      db
        .prepare(
          "INSERT INTO user_workflow_settings(user_id,workspace_id,updated_at) VALUES(?1,?2,?3) ON CONFLICT(user_id) DO UPDATE SET workspace_id=excluded.workspace_id,updated_at=excluded.updated_at",
        )
        .bind(ownerUserId, selected, now),
    );
    statements.push(
      db
        .prepare(
          "DELETE FROM space_workflow_configurations WHERE space_id IN (SELECT s.id FROM spaces s WHERE s.owner_user_id=?1 AND NOT EXISTS (SELECT 1 FROM space_workflow_settings ws WHERE ws.space_id=s.id))",
        )
        .bind(ownerUserId),
    );
    statements.push(
      db
        .prepare(
          "DELETE FROM space_workflow_defaults WHERE space_id IN (SELECT s.id FROM spaces s WHERE s.owner_user_id=?1 AND NOT EXISTS (SELECT 1 FROM space_workflow_settings ws WHERE ws.space_id=s.id))",
        )
        .bind(ownerUserId),
    );
    statements.push(
      db
        .prepare(
          "DELETE FROM space_additional_folders WHERE workspace_id IS NOT ?2 AND space_id IN (SELECT s.id FROM spaces s WHERE s.owner_user_id=?1 AND NOT EXISTS (SELECT 1 FROM space_workflow_settings ws WHERE ws.space_id=s.id))",
        )
        .bind(ownerUserId, selected),
    );
  }
  const affectedSpaces = spaceId
    ? [spaceId]
    : (
        await db
          .prepare(
            "SELECT s.id FROM spaces s WHERE s.owner_user_id=?1 AND NOT EXISTS (SELECT 1 FROM space_workflow_settings ws WHERE ws.space_id=s.id)",
          )
          .bind(ownerUserId)
          .all<{ id: string }>()
      ).results.map((space) => space.id);
  if (!spaceId && selected) {
    for (const id of affectedSpaces)
      statements.push(
        ...(await prepareWorkflowWorkspaceGrant(
          env,
          ownerUserId,
          id,
          selected,
          now,
        )),
      );
  }
  await db.batch(statements);
  for (const id of affectedSpaces)
    await publishCollaborationEvent(env, "space.updated", id, id);
  return json({
    ...(await loadWorkflowWorkspace(env, ownerUserId, spaceId)),
    workspaces: choices.results,
  });
}
