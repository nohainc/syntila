import { DESKTOP_WORKSPACE_AUDIENCE, hashToken } from "@syntila/security";

import {
  disconnectWorkspaceRuntime,
  findDesktopHumanSession,
  getWorkspaceGatewayStatus,
  json,
  parseJson,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";
import { hasControlCharacters } from "./workspaces-shared.js";
import { ACTIVE_ASSIGNMENT_STATUS_SQL } from "../assignment-transitions.js";
import {
  PersonalWorkspaceLimitError,
  personalWorkspaceAdmissionSql,
} from "../account-plan.js";

type WorkspaceOwnershipRow = {
  runtimeId: string;
  workspaceId: string;
  installationId: string | null;
  ownerUserId: string;
  workspaceStatus: string;
  revokedAt: string | null;
};
type WorkspaceInstallationRow = {
  installationId: string;
  ownerUserId: string;
  workspaceId: string;
  status: "active" | "released";
  releasedAt: string | null;
  workspaceStatus: string;
  workspaceName: string;
};

type WorkspaceOwnershipFailureCode =
  | "workspace_owned_by_other_account"
  | "installation_binding_ambiguous"
  | "workspace_runtime_missing"
  | "workspace_identity_mismatch"
  | "release_required";

const otherAccountOwnershipMessage =
  "This Workspace installation is owned by another Syntila account. Sign in as its current owner, then disconnect and release ownership before switching accounts.";

function workspaceOwnershipFailure(
  code: WorkspaceOwnershipFailureCode,
  error: string,
  status: number,
): Response {
  return json({ error, code }, { status });
}

async function workspaceInstallationBindingIssue(
  env: SecurityEnv,
  sessionUserId: string,
  installationId: string,
): Promise<Response | null> {
  const installation = await env.SYNTILA_DB.prepare(
    `SELECT wi.installation_id AS installationId,
            wi.owner_user_id AS ownerUserId, wi.workspace_id AS workspaceId,
            wi.status AS status, wi.released_at AS releasedAt,
            w.status AS workspaceStatus, w.name AS workspaceName
       FROM workspace_installations wi
       JOIN execution_workspaces w ON w.id = wi.workspace_id
      WHERE wi.installation_id = ?1`,
  )
    .bind(installationId)
    .first<WorkspaceInstallationRow>();
  if (!installation) return null;
  if (
    installation.status === "active" &&
    installation.ownerUserId !== sessionUserId
  ) {
    return workspaceOwnershipFailure(
      "workspace_owned_by_other_account",
      otherAccountOwnershipMessage,
      409,
    );
  }
  const activeRuntime = await env.SYNTILA_DB.prepare(
    `SELECT COUNT(*) AS count FROM workspace_runtime_identities
      WHERE workspace_id = ?1 AND revoked_at IS NULL`,
  )
    .bind(installation.workspaceId)
    .first<{ count: number }>();
  if ((activeRuntime?.count ?? 0) > 1) {
    return workspaceOwnershipFailure(
      "installation_binding_ambiguous",
      "Cloud found multiple active runtime identities for this Workspace. Do not continue until the runtime state is reviewed.",
      409,
    );
  }
  return null;
}

/** Classifies failed local IDs without exposing a foreign account's identity. */
async function workspaceIdentityFailure(
  env: SecurityEnv,
  sessionUserId: string,
  installationId: string,
  workspaceId: string,
  runtimeId: string,
): Promise<Response> {
  const bindingIssue = await workspaceInstallationBindingIssue(
    env,
    sessionUserId,
    installationId,
  );
  if (bindingIssue) return bindingIssue;

  const runtime = await env.SYNTILA_DB.prepare(
    `SELECT i.workspace_id AS workspaceId, w.owner_user_id AS ownerUserId
       FROM workspace_runtime_identities i
       JOIN execution_workspaces w ON w.id = i.workspace_id
      WHERE i.id = ?1`,
  )
    .bind(runtimeId)
    .first<{
      workspaceId: string;
      ownerUserId: string;
    }>();
  if (!runtime) {
    return workspaceOwnershipFailure(
      "workspace_runtime_missing",
      "The Workspace runtime identity no longer exists in Cloud.",
      404,
    );
  }
  return workspaceOwnershipFailure(
    "workspace_identity_mismatch",
    "The stored Workspace/runtime identity does not match this installation. Check the local registration before retrying.",
    409,
  );
}

function currentOwnerOwnership(
  state:
    | "owned_by_current_user"
    | "local_registration_stale"
    | "installation_conflict"
    | "released",
  installation: WorkspaceInstallationRow,
  runtime?: { runtimeId?: string; workspaceStatus: string } | null,
) {
  return {
    state,
    workspaceId: installation.workspaceId,
    workspaceName: installation.workspaceName,
    ...(runtime ? { workspaceRuntimeId: runtime.runtimeId } : {}),
    ownerUserId: installation.ownerUserId,
    ownerMatchesCurrentSession: true,
    runtimeState: runtime?.workspaceStatus ?? installation.workspaceStatus,
  };
}

/** Returns a privacy-preserving ownership read model for the local installation. */
export async function handleCheckWorkspaceOwnership(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session } = await findDesktopHumanSession(
    request,
    env,
    undefined,
    DESKTOP_WORKSPACE_AUDIENCE,
  );
  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  const installationId =
    typeof body.installationId === "string" ? body.installationId.trim() : "";
  const workspaceId =
    typeof body.workspaceId === "string" ? body.workspaceId.trim() : "";
  const runtimeId =
    typeof body.runtimeId === "string" ? body.runtimeId.trim() : "";
  if (
    body.contractVersion !== "1.0" ||
    !/^install_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      installationId,
    )
  ) {
    return json(
      {
        error: "Workspace installation identity is invalid",
        code: "invalid_installation_id",
      },
      { status: 400 },
    );
  }

  const installation = await env.SYNTILA_DB.prepare(
    `SELECT wi.installation_id AS installationId,
            wi.owner_user_id AS ownerUserId, wi.workspace_id AS workspaceId,
            wi.status AS status, wi.released_at AS releasedAt,
            w.status AS workspaceStatus, w.name AS workspaceName
       FROM workspace_installations wi
       JOIN execution_workspaces w ON w.id = wi.workspace_id
      WHERE wi.installation_id = ?1`,
  )
    .bind(installationId)
    .first<WorkspaceInstallationRow>();

  let localRow: WorkspaceOwnershipRow | null = null;
  if (workspaceId && runtimeId) {
    localRow = await env.SYNTILA_DB.prepare(
      `SELECT i.id AS runtimeId, i.workspace_id AS workspaceId,
              i.installation_id AS installationId, w.owner_user_id AS ownerUserId,
              w.status AS workspaceStatus, i.revoked_at AS revokedAt
         FROM workspace_runtime_identities i
         JOIN execution_workspaces w ON w.id = i.workspace_id
        WHERE i.id = ?1 AND i.workspace_id = ?2`,
    )
      .bind(runtimeId, workspaceId)
      .first<WorkspaceOwnershipRow>();
  }

  if (installation?.status === "active") {
    if (installation.ownerUserId !== session.userId) {
      return json({ state: "owned_by_other_user" });
    }
    const activeRuntimeCount = await env.SYNTILA_DB.prepare(
      `SELECT COUNT(*) AS count FROM workspace_runtime_identities
        WHERE workspace_id = ?1 AND revoked_at IS NULL`,
    )
      .bind(installation.workspaceId)
      .first<{ count: number }>();
    if ((activeRuntimeCount?.count ?? 0) > 1) {
      return json({ state: "corrupt_or_ambiguous" });
    }
    const runtime = await env.SYNTILA_DB.prepare(
      `SELECT i.id AS runtimeId, w.status AS workspaceStatus
         FROM workspace_runtime_identities i
         JOIN execution_workspaces w ON w.id = i.workspace_id
        WHERE i.workspace_id = ?1 AND i.revoked_at IS NULL
        ORDER BY i.created_at DESC, i.id DESC
        LIMIT 1`,
    )
      .bind(installation.workspaceId)
      .first<{ runtimeId: string; workspaceStatus: string }>();
    const hasLocalRegistration = Boolean(workspaceId || runtimeId);
    if (
      hasLocalRegistration &&
      (!workspaceId ||
        !runtimeId ||
        workspaceId !== installation.workspaceId ||
        runtimeId !== runtime?.runtimeId)
    ) {
      return json(
        currentOwnerOwnership(
          "local_registration_stale",
          installation,
          runtime,
        ),
      );
    }
    if (!runtime) {
      return json(
        currentOwnerOwnership("local_registration_stale", installation),
      );
    }
    return json(
      currentOwnerOwnership("owned_by_current_user", installation, runtime),
    );
  }

  if (installation?.status === "released") {
    if (installation.ownerUserId !== session.userId) {
      return json({ state: "released" });
    }
    const latestRuntime = await env.SYNTILA_DB.prepare(
      `SELECT i.id AS runtimeId, w.status AS workspaceStatus
         FROM workspace_runtime_identities i
         JOIN execution_workspaces w ON w.id = i.workspace_id
        WHERE i.workspace_id = ?1
        ORDER BY i.created_at DESC, i.id DESC
        LIMIT 1`,
    )
      .bind(installation.workspaceId)
      .first<{ runtimeId: string; workspaceStatus: string }>();
    return json(currentOwnerOwnership("released", installation, latestRuntime));
  }

  if (localRow?.ownerUserId === session.userId) {
    const localInstallation = await env.SYNTILA_DB.prepare(
      `SELECT wi.installation_id AS installationId,
              wi.owner_user_id AS ownerUserId, wi.workspace_id AS workspaceId,
              wi.status AS status, wi.released_at AS releasedAt,
              w.status AS workspaceStatus, w.name AS workspaceName
         FROM workspace_installations wi
         JOIN execution_workspaces w ON w.id = wi.workspace_id
        WHERE wi.workspace_id = ?1 AND wi.status = 'active'`,
    )
      .bind(localRow.workspaceId)
      .first<WorkspaceInstallationRow>();
    if (localInstallation?.ownerUserId === session.userId) {
      return json(
        currentOwnerOwnership("installation_conflict", localInstallation, {
          runtimeId: localRow.runtimeId,
          workspaceStatus: localRow.workspaceStatus,
        }),
      );
    }
  }

  if (localRow?.ownerUserId === session.userId) {
    return json({ state: "local_registration_stale" });
  }

  if (workspaceId || runtimeId) {
    return json({ state: "local_registration_stale" });
  }
  const releaseHistory = await env.SYNTILA_DB.prepare(
    `SELECT 1 AS released
       FROM workspace_audit_log
      WHERE action = 'workspace.ownership.released'
        AND CASE
              WHEN json_valid(details_json) = 1
              THEN json_extract(details_json, '$.installationId')
              ELSE NULL
            END = ?1
      LIMIT 1`,
  )
    .bind(installationId)
    .first<{ released: number }>();
  if (releaseHistory) return json({ state: "released" });
  // Keep ownerUserId as a compatibility alias for older Workspace clients;
  // with an unbound installation it identifies only the authenticated caller.
  return json({ state: "unbound", ownerUserId: session.userId });
}

/** Repairs only a missing v8 ownership row backed by the caller's exact legacy registration. */
export async function handleReconcileWorkspaceOwnership(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session, now } = await findDesktopHumanSession(
    request,
    env,
    undefined,
    DESKTOP_WORKSPACE_AUDIENCE,
  );
  const sessionCreatedAt = Date.parse(session.createdAt);
  if (
    !Number.isFinite(sessionCreatedAt) ||
    sessionCreatedAt < Date.now() - 5 * 60_000
  ) {
    return json(
      {
        error: "Fresh browser sign-in is required to reconcile this Workspace",
        code: "fresh_auth_required",
      },
      { status: 403 },
    );
  }

  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  const installationId =
    typeof body.installationId === "string" ? body.installationId.trim() : "";
  const workspaceId =
    typeof body.workspaceId === "string" ? body.workspaceId.trim() : "";
  const runtimeId =
    typeof body.runtimeId === "string" ? body.runtimeId.trim() : "";
  if (
    Object.keys(body).some(
      (key) =>
        ![
          "contractVersion",
          "installationId",
          "workspaceId",
          "runtimeId",
        ].includes(key),
    ) ||
    body.contractVersion !== "1.0" ||
    !/^install_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      installationId,
    ) ||
    !workspaceId ||
    !runtimeId
  ) {
    return json(
      {
        error: "Workspace reconciliation details are invalid",
        code: "invalid_reconciliation_identity",
      },
      { status: 400 },
    );
  }

  const existing = await env.SYNTILA_DB.prepare(
    `SELECT wi.installation_id AS installationId,
            wi.owner_user_id AS ownerUserId, wi.workspace_id AS workspaceId,
            wi.status AS status, wi.released_at AS releasedAt,
            w.status AS workspaceStatus, w.name AS workspaceName
       FROM workspace_installations wi
       JOIN execution_workspaces w ON w.id = wi.workspace_id
      WHERE wi.installation_id = ?1`,
  )
    .bind(installationId)
    .first<WorkspaceInstallationRow>();
  if (existing?.status === "active") {
    if (existing.ownerUserId !== session.userId) {
      return json({ state: "owned_by_other_user" });
    }
    const runtime = await env.SYNTILA_DB.prepare(
      `SELECT i.id AS runtimeId, w.status AS workspaceStatus
         FROM workspace_runtime_identities i
         JOIN execution_workspaces w ON w.id = i.workspace_id
        WHERE i.workspace_id = ?1 AND i.revoked_at IS NULL
        ORDER BY i.created_at DESC, i.id DESC LIMIT 1`,
    )
      .bind(existing.workspaceId)
      .first<{ runtimeId: string; workspaceStatus: string }>();
    return json(
      currentOwnerOwnership("local_registration_stale", existing, runtime),
    );
  }
  if (existing?.status === "released") return json({ state: "released" });

  const releaseHistory = await env.SYNTILA_DB.prepare(
    `SELECT 1 AS released
       FROM workspace_audit_log
      WHERE action = 'workspace.ownership.released'
        AND CASE WHEN json_valid(details_json) = 1
          THEN json_extract(details_json, '$.installationId') ELSE NULL END = ?1
      LIMIT 1`,
  )
    .bind(installationId)
    .first<{ released: number }>();
  if (releaseHistory) return json({ state: "released" });

  const legacy = await env.SYNTILA_DB.prepare(
    `SELECT i.id AS runtimeId, i.workspace_id AS workspaceId,
            i.installation_id AS installationId, w.owner_user_id AS ownerUserId,
            w.status AS workspaceStatus, i.revoked_at AS revokedAt,
            w.name AS workspaceName,
            (SELECT COUNT(*) FROM workspace_audit_log a
              WHERE a.workspace_id = i.workspace_id
                AND a.target_type = 'workspace_runtime'
                AND a.target_id = i.id
                AND a.action IN ('workspace.registered', 'workspace.recovered')
                AND CASE WHEN json_valid(a.details_json) = 1
                  THEN json_extract(a.details_json, '$.installationId')
                  ELSE NULL END = ?3) AS auditBinding
       FROM workspace_runtime_identities i
       JOIN execution_workspaces w ON w.id = i.workspace_id
      WHERE i.id = ?1 AND i.workspace_id = ?2`,
  )
    .bind(runtimeId, workspaceId, installationId)
    .first<
      WorkspaceOwnershipRow & { workspaceName: string; auditBinding: number }
    >();
  if (
    legacy &&
    (legacy.installationId === installationId || legacy.auditBinding > 0) &&
    legacy.ownerUserId !== session.userId &&
    legacy.revokedAt === null &&
    legacy.workspaceStatus !== "revoked"
  ) {
    return json({ state: "owned_by_other_user" });
  }
  if (
    !legacy ||
    legacy.ownerUserId !== session.userId ||
    (legacy.installationId !== installationId && legacy.auditBinding === 0) ||
    (legacy.installationId !== null &&
      legacy.installationId !== installationId) ||
    legacy.workspaceStatus === "revoked"
  ) {
    return json({ state: "not_reconcilable" }, { status: 409 });
  }

  const competing = await env.SYNTILA_DB.prepare(
    `SELECT
       (SELECT COUNT(DISTINCT i.workspace_id)
          FROM workspace_runtime_identities i
          JOIN execution_workspaces w ON w.id = i.workspace_id
         WHERE i.installation_id = ?1
           AND (i.workspace_id <> ?2 OR w.owner_user_id <> ?3)) AS conflictingHistory,
       (SELECT COUNT(*) FROM workspace_runtime_identities i
          WHERE i.installation_id = ?1 AND i.revoked_at IS NULL
            AND i.workspace_id <> ?2) AS competingActiveRuntime,
       (SELECT COUNT(*) FROM workspace_installations wi
          WHERE wi.workspace_id = ?2 AND wi.status = 'active') AS competingWorkspaceBinding,
       (SELECT COUNT(*) FROM workspace_runtime_identities i
          WHERE i.workspace_id = ?2 AND i.revoked_at IS NULL) AS activeRuntimeCount`,
  )
    .bind(installationId, workspaceId, session.userId)
    .first<{
      conflictingHistory: number;
      competingActiveRuntime: number;
      competingWorkspaceBinding: number;
      activeRuntimeCount: number;
    }>();
  if (
    !competing ||
    competing.conflictingHistory > 0 ||
    competing.competingActiveRuntime > 0 ||
    competing.competingWorkspaceBinding > 0 ||
    competing.activeRuntimeCount > 1
  ) {
    return json({ state: "corrupt_or_ambiguous" }, { status: 409 });
  }

  const auditId = `audit-${crypto.randomUUID()}`;
  try {
    await env.SYNTILA_DB.batch([
      env.SYNTILA_DB.prepare(
        `INSERT INTO workspace_installations
          (installation_id, owner_user_id, workspace_id, status, created_at, updated_at, released_at)
         VALUES (?1, ?2, ?3, 'active', ?4, ?4, NULL)`,
      ).bind(installationId, session.userId, workspaceId, now),
      env.SYNTILA_DB.prepare(
        `INSERT INTO workspace_audit_log
          (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
         VALUES (?1, ?2, 'user', ?3, 'workspace.ownership.reconciled', 'workspace_installation', ?4, ?5, ?6)`,
      ).bind(
        auditId,
        workspaceId,
        session.userId,
        installationId,
        JSON.stringify({ source: "legacy_runtime_identity", runtimeId }),
        now,
      ),
    ]);
  } catch {
    return json({ state: "corrupt_or_ambiguous" }, { status: 409 });
  }

  const reconciled: WorkspaceInstallationRow = {
    installationId,
    ownerUserId: session.userId,
    workspaceId,
    status: "active",
    releasedAt: null,
    workspaceStatus: legacy.workspaceStatus,
    workspaceName: legacy.workspaceName,
  };
  return json(
    currentOwnerOwnership("local_registration_stale", reconciled, {
      ...(legacy.revokedAt === null ? { runtimeId } : {}),
      workspaceStatus: legacy.workspaceStatus,
    }),
  );
}

/** Disconnects runtime participation while retaining the installation owner binding. */
export async function handleDisconnectDesktopWorkspace(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session, now } = await findDesktopHumanSession(
    request,
    env,
    undefined,
    DESKTOP_WORKSPACE_AUDIENCE,
  );
  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  const installationId =
    typeof body.installationId === "string" ? body.installationId.trim() : "";
  const workspaceId =
    typeof body.workspaceId === "string" ? body.workspaceId.trim() : "";
  const runtimeId =
    typeof body.runtimeId === "string" ? body.runtimeId.trim() : "";
  if (!installationId || !workspaceId || !runtimeId) {
    return json(
      {
        error: "Workspace disconnect identity is incomplete",
        code: "invalid_disconnect_identity",
      },
      { status: 400 },
    );
  }
  const bindingIssue = await workspaceInstallationBindingIssue(
    env,
    session.userId,
    installationId,
  );
  if (bindingIssue) return bindingIssue;
  const owned = await env.SYNTILA_DB.prepare(
    `SELECT i.id AS runtimeId, i.workspace_id AS workspaceId,
            i.credential_token_hash AS credentialHash,
            i.revoked_at AS revokedAt, wi.owner_user_id AS ownerUserId,
            w.status AS workspaceStatus
       FROM workspace_runtime_identities i
       JOIN execution_workspaces w ON w.id = i.workspace_id
       JOIN workspace_installations wi ON wi.workspace_id = i.workspace_id
      WHERE wi.installation_id = ?1 AND wi.status = 'active'
        AND i.workspace_id = ?2 AND i.id = ?3`,
  )
    .bind(installationId, workspaceId, runtimeId)
    .first<{
      runtimeId: string;
      workspaceId: string;
      credentialHash: string;
      revokedAt: string | null;
      ownerUserId: string;
      workspaceStatus: string;
    }>();
  if (!owned || owned.ownerUserId !== session.userId) {
    return workspaceIdentityFailure(
      env,
      session.userId,
      installationId,
      workspaceId,
      runtimeId,
    );
  }
  if (owned.revokedAt !== null)
    return json({ disconnected: true, workspaceId, installationId });

  const active = await env.SYNTILA_DB.prepare(
    `SELECT COUNT(*) AS count FROM worker_assignments
      WHERE execution_workspace_id = ?1 AND status IN (${ACTIVE_ASSIGNMENT_STATUS_SQL})`,
  )
    .bind(workspaceId)
    .first<{ count: number }>();
  if ((active?.count ?? 0) > 0) {
    return json(
      {
        error: "Finish active Workspace assignments before disconnecting",
        code: "active_work",
      },
      { status: 409 },
    );
  }

  const disconnectedAt = now;
  const result = await env.SYNTILA_DB.batch([
    env.SYNTILA_DB.prepare(
      `UPDATE workspace_runtime_identities SET revoked_at = ?1
        WHERE id = ?2 AND workspace_id = ?3 AND revoked_at IS NULL`,
    ).bind(disconnectedAt, runtimeId, workspaceId),
    env.SYNTILA_DB.prepare(
      `UPDATE execution_workspaces SET status = 'offline', updated_at = ?1
        WHERE id = ?2 AND owner_user_id = ?3 AND status <> 'revoked'`,
    ).bind(disconnectedAt, workspaceId, session.userId),
    env.SYNTILA_DB.prepare(
      `INSERT INTO workspace_audit_log
        (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, 'workspace.disconnected', 'workspace_runtime', ?4, ?5, ?6)`,
    ).bind(
      `audit-${crypto.randomUUID()}`,
      workspaceId,
      session.userId,
      runtimeId,
      JSON.stringify({ installationId, disconnectedAt }),
      disconnectedAt,
    ),
  ]);
  if ((result[0]?.meta?.changes ?? 0) !== 1) {
    return json(
      {
        error: "Workspace runtime state changed concurrently",
        code: "runtime_state_conflict",
      },
      { status: 409 },
    );
  }
  const gatewayDisconnected = await disconnectWorkspaceRuntime(
    env,
    workspaceId,
    runtimeId,
  );
  return json({
    disconnected: true,
    workspaceId,
    installationId,
    disconnectedAt,
    gatewayDisconnected,
  });
}

/** Releases Cloud ownership only after a fresh same-owner human session. */
export async function handleReleaseDesktopWorkspace(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session, now } = await findDesktopHumanSession(
    request,
    env,
    undefined,
    DESKTOP_WORKSPACE_AUDIENCE,
  );
  const sessionCreatedAt = Date.parse(session.createdAt);
  if (
    !Number.isFinite(sessionCreatedAt) ||
    sessionCreatedAt < Date.now() - 5 * 60_000
  ) {
    return json(
      {
        error: "Fresh sign-in is required to release this Workspace",
        code: "fresh_auth_required",
      },
      { status: 403 },
    );
  }
  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  const installationId =
    typeof body.installationId === "string" ? body.installationId.trim() : "";
  const workspaceId =
    typeof body.workspaceId === "string" ? body.workspaceId.trim() : "";
  const runtimeId =
    typeof body.runtimeId === "string" ? body.runtimeId.trim() : "";
  if (!installationId || !workspaceId || !runtimeId) {
    return json(
      {
        error: "Workspace release identity is incomplete",
        code: "invalid_release_identity",
      },
      { status: 400 },
    );
  }
  const bindingIssue = await workspaceInstallationBindingIssue(
    env,
    session.userId,
    installationId,
  );
  if (bindingIssue) return bindingIssue;
  const owned = await env.SYNTILA_DB.prepare(
    `SELECT i.id AS runtimeId, i.workspace_id AS workspaceId,
            wi.owner_user_id AS ownerUserId, w.status AS workspaceStatus
       FROM workspace_runtime_identities i
       JOIN execution_workspaces w ON w.id = i.workspace_id
       JOIN workspace_installations wi ON wi.workspace_id = i.workspace_id
      WHERE wi.installation_id = ?1 AND wi.status = 'active'
        AND i.workspace_id = ?2 AND i.id = ?3`,
  )
    .bind(installationId, workspaceId, runtimeId)
    .first<{
      runtimeId: string;
      workspaceId: string;
      ownerUserId: string;
      workspaceStatus: string;
    }>();
  if (!owned || owned.ownerUserId !== session.userId) {
    return workspaceIdentityFailure(
      env,
      session.userId,
      installationId,
      workspaceId,
      runtimeId,
    );
  }

  const gatewayStatus = await getWorkspaceGatewayStatus(env, workspaceId);
  if (
    gatewayStatus === null ||
    gatewayStatus.online ||
    owned.workspaceStatus === "online"
  ) {
    return json(
      {
        error: "Disconnect the Workspace runtime before releasing ownership",
        code: "runtime_connected",
      },
      { status: 409 },
    );
  }

  const active = await env.SYNTILA_DB.prepare(
    `SELECT COUNT(*) AS count FROM worker_assignments
      WHERE execution_workspace_id = ?1
        AND status IN (${ACTIVE_ASSIGNMENT_STATUS_SQL})`,
  )
    .bind(workspaceId)
    .first<{ count: number }>();
  if ((active?.count ?? 0) > 0) {
    return json(
      {
        error: "Finish active Workspace assignments before releasing ownership",
        code: "active_work",
      },
      { status: 409 },
    );
  }

  const reserved = await env.SYNTILA_DB.prepare(
    `UPDATE execution_workspaces SET status = 'revoked', updated_at = ?1
      WHERE id = ?2 AND owner_user_id = ?3 AND status = ?4`,
  )
    .bind(now, workspaceId, session.userId, owned.workspaceStatus)
    .run();
  if ((reserved.meta?.changes ?? 0) !== 1) {
    return json(
      {
        error:
          "The Workspace identity changed while ownership was being released. Check its current state and retry.",
        code: "workspace_identity_mismatch",
      },
      { status: 409 },
    );
  }

  const released = await env.SYNTILA_DB.batch([
    env.SYNTILA_DB.prepare(
      `UPDATE workspace_runtime_identities
          SET revoked_at = COALESCE(revoked_at, ?1), installation_id = NULL
        WHERE workspace_id = ?2`,
    ).bind(now, workspaceId),
    env.SYNTILA_DB.prepare(
      `UPDATE workspace_installations
          SET status = 'released', released_at = ?1, updated_at = ?1
        WHERE installation_id = ?2 AND workspace_id = ?3
          AND owner_user_id = ?4 AND status = 'active'`,
    ).bind(now, installationId, workspaceId, session.userId),
    env.SYNTILA_DB.prepare(
      `UPDATE workspace_space_grants SET status = 'revoked', updated_at = ?1
        WHERE workspace_id = ?2 AND status IN ('active', 'suspended')`,
    ).bind(now, workspaceId),
    env.SYNTILA_DB.prepare(
      `INSERT INTO workspace_audit_log
        (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, 'workspace.ownership.released', 'workspace_runtime', ?4, ?5, ?6)`,
    ).bind(
      `audit-${crypto.randomUUID()}`,
      workspaceId,
      session.userId,
      runtimeId,
      JSON.stringify({ installationId, releasedAt: now }),
      now,
    ),
  ]);
  if ((released[1]?.meta?.changes ?? 0) !== 1) {
    return workspaceOwnershipFailure(
      "workspace_identity_mismatch",
      "The Workspace installation ownership changed while it was being released. Check its current state and retry.",
      409,
    );
  }
  return json({ released: true, workspaceId, installationId, releasedAt: now });
}

export async function handleRegisterWorkspaceFromDesktop(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const { session, now } = await findDesktopHumanSession(
    request,
    env,
    undefined,
    DESKTOP_WORKSPACE_AUDIENCE,
  );
  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return json(
      { error: "Workspace registration details are invalid" },
      { status: 400 },
    );
  }
  const installationId =
    typeof body.installationId === "string" ? body.installationId.trim() : "";
  const name =
    typeof body.proposedWorkspaceName === "string"
      ? body.proposedWorkspaceName.trim()
      : "";
  const hostname =
    typeof body.hostname === "string" ? body.hostname.trim() : "";
  const platform = body.platform;
  const architecture = body.architecture;
  const appVersion =
    typeof body.appVersion === "string" ? body.appVersion.trim() : "";
  const capabilities = body.runtimeCapabilities;
  if (
    Object.keys(body).some(
      (key) =>
        ![
          "contractVersion",
          "installationId",
          "proposedWorkspaceName",
          "hostname",
          "platform",
          "architecture",
          "appVersion",
          "runtimeCapabilities",
        ].includes(key),
    ) ||
    body.contractVersion !== "1.0" ||
    !/^install_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      installationId,
    ) ||
    !name ||
    name.length > 120 ||
    hasControlCharacters(name) ||
    !hostname ||
    hostname.length > 253 ||
    hasControlCharacters(hostname) ||
    !["macos", "linux", "windows"].includes(String(platform)) ||
    !["arm64", "x64", "x86"].includes(String(architecture)) ||
    !appVersion ||
    appVersion.length > 64 ||
    !/^[0-9A-Za-z.+-]+$/.test(appVersion) ||
    !capabilities ||
    typeof capabilities !== "object" ||
    Array.isArray(capabilities)
  ) {
    return json(
      { error: "Workspace registration details are invalid" },
      { status: 400 },
    );
  }
  const caps = capabilities as Record<string, unknown>;
  const supported = caps.supportedRuntimes;
  if (
    Object.keys(caps).some(
      (key) =>
        ![
          "os",
          "arch",
          "appVersion",
          "supportedRuntimes",
          "maxConcurrentWorkers",
        ].includes(key),
    ) ||
    caps.os !== platform ||
    caps.arch !== architecture ||
    caps.appVersion !== appVersion ||
    !Array.isArray(supported) ||
    supported.length > 16 ||
    supported.some(
      (x) => typeof x !== "string" || !/^[a-z0-9_-]{1,32}$/i.test(x),
    ) ||
    !Number.isInteger(caps.maxConcurrentWorkers) ||
    (caps.maxConcurrentWorkers as number) < 1 ||
    (caps.maxConcurrentWorkers as number) > 256
  ) {
    return json({ error: "Runtime capabilities are invalid" }, { status: 400 });
  }
  const installation = await env.SYNTILA_DB.prepare(
    `SELECT wi.installation_id AS installationId,
            wi.owner_user_id AS ownerUserId, wi.workspace_id AS workspaceId,
            wi.status AS status, wi.released_at AS releasedAt,
            w.name AS workspaceName, w.status AS workspaceStatus
       FROM workspace_installations wi
       JOIN execution_workspaces w ON w.id = wi.workspace_id
      WHERE wi.installation_id = ?1`,
  )
    .bind(installationId)
    .first<WorkspaceInstallationRow>();
  if (
    installation?.status === "active" &&
    installation.ownerUserId !== session.userId
  ) {
    return workspaceOwnershipFailure(
      "workspace_owned_by_other_account",
      otherAccountOwnershipMessage,
      409,
    );
  }
  const existing = installation?.status === "active" ? installation : null;
  if (existing?.workspaceStatus === "revoked") {
    return workspaceOwnershipFailure(
      "release_required",
      "This revoked Workspace must be explicitly released before it can be registered again.",
      409,
    );
  }
  if (existing) {
    const activeRuntime = await env.SYNTILA_DB.prepare(
      `SELECT COUNT(*) AS count FROM workspace_runtime_identities
        WHERE workspace_id = ?1 AND revoked_at IS NULL`,
    )
      .bind(existing.workspaceId)
      .first<{ count: number }>();
    if ((activeRuntime?.count ?? 0) > 1) {
      return workspaceOwnershipFailure(
        "installation_binding_ambiguous",
        "Cloud found multiple active runtime identities for this Workspace. Do not reconnect until the runtime state is reviewed.",
        409,
      );
    }
  }
  // A released installation can be claimed by the authenticated caller as a
  // new Workspace; a still-active record above remains owner-bound.
  const outcome = existing ? "recovered" : "created";
  const workspaceId = existing?.workspaceId ?? `ws-${crypto.randomUUID()}`;
  const workspaceName =
    name && name.trim().length > 0
      ? name.trim()
      : (existing?.workspaceName ?? name);
  const runtimeId = `runtime-${crypto.randomUUID()}`;
  const credential = `syntila_workspace_tok_${crypto.randomUUID().replace(/-/g, "")}`;
  const credentialHash = await hashToken(credential);
  const auditId = `audit-${crypto.randomUUID()}`;
  const statements = [];
  // New registrations are admitted by the INSERT itself (see the account plan's
  // personal Workspace allowance). Every later statement for a new Workspace
  // only runs when that row exists, so a refused admission writes nothing and
  // concurrent requests cannot both take the last slot.
  const admitted = existing
    ? ""
    : ` WHERE EXISTS (SELECT 1 FROM execution_workspaces WHERE id = '${workspaceId}')`;
  if (
    existing &&
    name &&
    name.trim().length > 0 &&
    name.trim() !== existing.workspaceName
  ) {
    statements.push(
      env.SYNTILA_DB.prepare(
        `UPDATE execution_workspaces SET name = ?1, updated_at = ?2 WHERE id = ?3`,
      ).bind(workspaceName, now, workspaceId),
    );
  }
  if (!existing) {
    statements.push(
      env.SYNTILA_DB.prepare(
        `INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at)
         SELECT ?1, ?2, ?3, 'offline', ?4, ?4
          WHERE ${personalWorkspaceAdmissionSql("?2")}`,
      ).bind(workspaceId, session.userId, workspaceName, now),
    );
    statements.push(
      env.SYNTILA_DB.prepare(
        `INSERT INTO workspace_installations
          (installation_id, owner_user_id, workspace_id, status, created_at, updated_at, released_at)
         SELECT ?1, ?2, ?3, 'active', ?4, ?4, NULL${admitted}
         ON CONFLICT(installation_id) DO UPDATE SET
           owner_user_id = excluded.owner_user_id,
           workspace_id = excluded.workspace_id,
           status = 'active',
           updated_at = excluded.updated_at,
           released_at = NULL
         WHERE workspace_installations.status = 'released'`,
      ).bind(installationId, session.userId, workspaceId, now),
    );
  }
  if (existing) {
    statements.push(
      env.SYNTILA_DB.prepare(
        `UPDATE workspace_runtime_identities SET revoked_at = ?1
          WHERE workspace_id = ?2 AND revoked_at IS NULL`,
      ).bind(now, workspaceId),
    );
  }
  statements.push(
    env.SYNTILA_DB.prepare(
      `INSERT INTO workspace_runtime_identities (id, workspace_id, credential_token_hash, installation_id, created_at, revoked_at) SELECT ?1, ?2, ?3, ?4, ?5, NULL${admitted}`,
    ).bind(runtimeId, workspaceId, credentialHash, installationId, now),
  );
  statements.push(
    env.SYNTILA_DB.prepare(
      `INSERT INTO workspace_runtime_facts (workspace_id, platform, architecture, hostname, app_version, runtime_capabilities_json, updated_at) SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7${admitted} ON CONFLICT(workspace_id) DO UPDATE SET platform=excluded.platform, architecture=excluded.architecture, hostname=excluded.hostname, app_version=excluded.app_version, runtime_capabilities_json=excluded.runtime_capabilities_json, updated_at=excluded.updated_at`,
    ).bind(
      workspaceId,
      platform,
      architecture,
      hostname,
      appVersion,
      JSON.stringify(caps),
      now,
    ),
  );
  statements.push(
    env.SYNTILA_DB.prepare(
      `INSERT INTO workspace_audit_log (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) SELECT ?1, ?2, 'user', ?3, ?4, 'workspace_runtime', ?5, ?6, ?7${admitted}`,
    ).bind(
      auditId,
      workspaceId,
      session.userId,
      outcome === "created" ? "workspace.registered" : "workspace.recovered",
      runtimeId,
      JSON.stringify({
        installationId,
        hostname,
        platform,
        architecture,
        appVersion,
      }),
      now,
    ),
  );
  try {
    const results = await env.SYNTILA_DB.batch(statements);
    if (!existing) {
      // The Workspace INSERT is always the first statement.
      if ((results[0]?.meta?.changes ?? 0) !== 1) {
        const limit = new PersonalWorkspaceLimitError();
        return json({ error: limit.message, code: limit.code }, { status: limit.status });
      }
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("Workspace registration batch failed:", message);
    return json(
      {
        error: `Workspace registration changed concurrently; retry the request (${message})`,
        code: "registration_conflict",
        details: message,
      },
      { status: 409 },
    );
  }
  const completedAt = new Date().toISOString();
  return json(
    {
      outcome,
      workspaceId,
      workspaceRuntimeId: runtimeId,
      workspaceName,
      ownerUserId: session.userId,
      runtimeCredential: credential,
      credentialIssuedAt: completedAt,
      credentialExpiresAt: null,
      completedAt,
    },
    { status: 201 },
  );
}
