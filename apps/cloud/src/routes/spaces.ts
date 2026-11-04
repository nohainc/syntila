import {
  SpaceMemberLimitError,
  getSpaceMemberUsage,
  spaceMemberAdmissionSql,
  spaceMemberCapacityRefused,
} from "../account-plan.js";
import { prepareWorkflowWorkspaceGrant } from "./workflow-workspace.js";
import {
  defaultSpaceMemberPermissions,
  spaceMemberPermissions,
  SPACE_MEMBER_PERMISSION_KEYS,
  parseSpaceSettings,
} from "@syntila/security";
import {
  loadSpacePermissions,
  requireSpaceOwner,
  validateMemberPermissions,
  permissionJsonPath,
} from "./space-permissions.js";
import { conditionalJson } from "./conditional-read.js";
import { MutationIdempotency } from "./mutation-idempotency.js";
import {
  activeWorkSql,
  lastSpaceActivitySql,
  unreadSql,
} from "./thread-activity.js";
import { publishCollaborationEvent } from "../collaboration-events.js";
import {
  resolveAppUrl,
  sendSpaceInvitationEmail,
} from "../invitation-email.js";
import { classifyEmailDeliveryFailure } from "../email/email-config.js";
import { hashToken, authorizeSpaceOwner } from "@syntila/security";
import {
  HttpError,
  authorizeSpaceOwnerOrThrow,
  authorizeRequest,
  json,
  parseJson,
  requiredString,
  securityContext,
  securityEnv,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

function spaceSettings(value: unknown): Record<string, unknown> {
  const settings = parseJson<Record<string, unknown>>(value);
  delete settings.defaultExecutionPolicy;
  return settings;
}

function publicSpaceSettings(value: unknown): Record<string, unknown> {
  const settings = spaceSettings(value);
  delete settings.memberPermissions;
  delete settings.invitationPermissions;
  return settings;
}

// =========================================================================
// Spaces API Handlers
// =========================================================================

export async function handleListSpaces(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    securityEnv(env),
    "spaces:read",
    undefined,
    accessContext,
  );
  {
    const includeArchived =
      new URL(request.url).searchParams.get("archived") === "true";
    const rows = await env.SYNTILA_DB.prepare(
      `SELECT p.id, p.name, p.description, pm.role,
              p.settings_json AS settingsJson, p.created_at AS createdAt, ${lastSpaceActivitySql("p")} AS updatedAt,
              EXISTS (
                SELECT 1 FROM threads t
                 WHERE t.space_id = p.id AND ${activeWorkSql("t")}
              ) AS hasActiveWork,
              EXISTS (
                SELECT 1 FROM threads t
                  LEFT JOIN thread_read_states rs
                    ON rs.thread_id = t.id AND rs.user_id = ?1
                 WHERE t.space_id = p.id
                   AND ${unreadSql("t", "?1", "COALESCE(rs.read_at, pm.created_at)")}
              ) AS hasUnread,
              (SELECT up.pinned_at FROM user_pins up
                WHERE up.user_id = ?1 AND up.kind = 'space'
                  AND up.target_id = p.id) AS pinnedAt,
              (SELECT up.position FROM user_pins up
                WHERE up.user_id = ?1 AND up.kind = 'space'
                  AND up.target_id = p.id) AS pinPosition
       FROM spaces p
       JOIN space_memberships pm ON pm.space_id = p.id
       WHERE pm.user_id = ?1
         ${includeArchived ? "" : "AND COALESCE(json_extract(p.settings_json, '$.archived'), 0) = 0"}
       ORDER BY updatedAt DESC, p.id DESC`,
    )
      .bind(context.userId)
      .all<{
        id: string;
        name: string;
        description: string | null;
        role: string;
        settingsJson: string;
        createdAt: string;
        updatedAt: string;
        hasActiveWork: number;
        hasUnread: number;
        pinnedAt: string | null;
        pinPosition: number | null;
      }>();

    const spaces = (rows.results ?? []).map((row) => {
      const settings = publicSpaceSettings(row.settingsJson);
      return {
        id: row.id,
        name: row.name,
        description: row.description,
        role: row.role,
        permissions: spaceMemberPermissions(
          row.role,
          row.settingsJson,
          context.userId,
        ),
        instructions:
          typeof settings.instructions === "string"
            ? settings.instructions
            : "",
        settings,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        hasActiveWork: row.hasActiveWork === 1,
        hasUnread: row.hasUnread === 1,
        pinnedAt: row.pinnedAt ?? null,
        pinPosition: row.pinPosition ?? 0,
      };
    });
    return json({ spaces });
  }

  return json({ spaces: [] });
}

export async function handleCreateSpace(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:manage",
    undefined,
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const name = requiredString(body.name, "name");
  const description =
    typeof body.description === "string" ? body.description : null;
  const settings =
    typeof body.settings === "object" && body.settings !== null
      ? (body.settings as Record<string, unknown>)
      : {};
  delete settings.defaultExecutionPolicy;
  delete settings.memberPermissions;
  delete settings.invitationPermissions;
  if (settings.allowWork !== undefined)
    throw new HttpError(
      400,
      "Configure enabled workflows on the Workflows page",
    );
  if (
    settings.showAiHistory !== undefined &&
    typeof settings.showAiHistory !== "boolean"
  )
    throw new HttpError(400, "showAiHistory must be a boolean");
  // The Workspace is an explicit choice per Space (or none); Spaces never
  // receive a Workspace implicitly.
  if (
    body.workspaceId !== undefined &&
    body.workspaceId !== null &&
    typeof body.workspaceId !== "string"
  )
    throw new HttpError(400, "workspaceId must be a string or null");
  const workspaceId =
    typeof body.workspaceId === "string" && body.workspaceId
      ? body.workspaceId
      : null;
  const now = new Date().toISOString();
  const id = `space-${crypto.randomUUID()}`;

  {
    const duplicate = await env.SYNTILA_DB.prepare(
      `SELECT id FROM spaces
       WHERE owner_user_id = ?1 AND LOWER(TRIM(name)) = LOWER(TRIM(?2))
       LIMIT 1`,
    )
      .bind(context.userId, name)
      .first<{ id: string }>();
    if (duplicate) {
      throw new HttpError(409, "You already have a Space with this name");
    }
    // Refused (403) when the chosen Workspace is not owned or lent to the
    // creator; nothing is created then.
    const workspaceGrants = workspaceId
      ? await prepareWorkflowWorkspaceGrant(
          env,
          context.userId,
          id,
          workspaceId,
          now,
        )
      : [];
    await publishCollaborationEvent(env, "space.created", id, id, {
      mutations: [
        env.SYNTILA_DB.prepare(
          `INSERT INTO spaces (id, owner_user_id, name, description, settings_json, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)`,
        ).bind(
          id,
          context.userId,
          name,
          description,
          JSON.stringify(settings),
          now,
        ),
        env.SYNTILA_DB.prepare(
          `INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at)
         VALUES (?1, ?2, ?3, 'owner', ?4, ?4)
         ON CONFLICT(space_id, user_id) DO NOTHING`,
        ).bind(`pm-${crypto.randomUUID()}`, id, context.userId, now),
        env.SYNTILA_DB.prepare(
          "INSERT INTO space_workflow_settings(space_id, workspace_id, updated_at) VALUES (?1, ?2, ?3)",
        ).bind(id, workspaceId, now),
        ...workspaceGrants,
      ],
    });
    return json(
      {
        space: {
          id,
          name,
          description,
          instructions:
            typeof settings.instructions === "string"
              ? settings.instructions
              : "",
          settings,
          createdAt: now,
          updatedAt: now,
        },
      },
      { status: 201 },
    );
  }
}

export async function handleGetSpace(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:read",
    spaceId,
    accessContext,
  );
  const row = await env.SYNTILA_DB.prepare(
    `SELECT p.id, p.name, p.description, pm.role,
            p.settings_json AS settingsJson, p.created_at AS createdAt, p.updated_at AS updatedAt
     FROM spaces p JOIN space_memberships pm ON pm.space_id = p.id
     WHERE p.id = ?1 AND pm.user_id = ?2`,
  )
    .bind(spaceId, context.userId)
    .first<{
      id: string;
      name: string;
      description: string | null;
      role: string;
      settingsJson: string;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!row) throw new HttpError(404, "Space not found");
  const settings = publicSpaceSettings(row.settingsJson);
  return conditionalJson(request, {
    space: {
      id: row.id,
      name: row.name,
      description: row.description,
      role: row.role,
      permissions: spaceMemberPermissions(
        row.role,
        row.settingsJson,
        context.userId,
      ),
      instructions:
        typeof settings.instructions === "string" ? settings.instructions : "",
      settings,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    },
  });
}

export async function handleUpdateSpace(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:write",
    spaceId,
    accessContext,
  );
  const existing = await env.SYNTILA_DB.prepare(
    `SELECT id, owner_user_id AS ownerUserId, name, description,
            settings_json AS settingsJson,
            created_at AS createdAt, updated_at AS updatedAt
     FROM spaces WHERE id = ?1`,
  )
    .bind(spaceId)
    .first<{
      id: string;
      ownerUserId: string;
      name: string;
      description: string | null;
      settingsJson: string;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!existing) throw new HttpError(404, "Space not found");

  if (context.userId !== existing.ownerUserId)
    throw new HttpError(403, "Only the Space owner can update Space settings");
  const body = (await request.json()) as Record<string, unknown>;
  if (
    body.settings &&
    typeof body.settings === "object" &&
    Object.prototype.hasOwnProperty.call(body.settings, "threadOrder")
  ) {
    if (
      context.userId !== existing.ownerUserId &&
      context.spaceRoles[spaceId] !== "owner"
    )
      throw new HttpError(403, "Only the Space owner can reorder Threads");
  }
  const incomingSettings = parseSpaceSettings(body.settings);
  if (
    Object.hasOwn(incomingSettings, "memberPermissions") ||
    Object.hasOwn(incomingSettings, "invitationPermissions")
  ) {
    throw new HttpError(
      400,
      "Member rights must be changed through the member permission controls",
    );
  }
  if (incomingSettings.allowWork !== undefined)
    throw new HttpError(
      400,
      "Configure enabled workflows on the Workflows page",
    );
  if (incomingSettings.threadOrder !== undefined) {
    const order = incomingSettings.threadOrder;
    if (
      !Array.isArray(order) ||
      order.length > 1000 ||
      order.some((id) => typeof id !== "string" || id.length === 0) ||
      new Set(order).size !== order.length
    )
      throw new HttpError(
        400,
        "threadOrder must be a list of unique Thread ids",
      );
  }
  if (
    incomingSettings.sidebarExpanded !== undefined &&
    typeof incomingSettings.sidebarExpanded !== "boolean"
  )
    throw new HttpError(400, "sidebarExpanded must be a boolean");
  if (
    incomingSettings.showAiHistory !== undefined &&
    typeof incomingSettings.showAiHistory !== "boolean"
  )
    throw new HttpError(400, "showAiHistory must be a boolean");
  const settings = {
    ...spaceSettings(existing.settingsJson),
    ...(typeof body.settings === "object" && body.settings !== null
      ? (body.settings as Record<string, unknown>)
      : {}),
  };
  delete settings.defaultExecutionPolicy;
  if (typeof body.instructions === "string") {
    settings.instructions = body.instructions;
  }
  if (body.archived === true) settings.archived = true;
  if (body.archived === false) settings.archived = false;
  // Sidebar view state (expanded, Thread order) is not Space activity: it must
  // not move the Space in the newest-update-first list.
  const viewStateOnly =
    Object.keys(incomingSettings).every(
      (key) => key === "sidebarExpanded" || key === "threadOrder",
    ) &&
    body.instructions === undefined &&
    body.archived === undefined &&
    body.name === undefined &&
    body.description === undefined;
  const now = viewStateOnly ? existing.updatedAt : new Date().toISOString();
  const space = {
    id: existing.id,
    name:
      typeof body.name === "string" && body.name.trim().length > 0
        ? body.name.trim()
        : existing.name,
    description:
      body.description === null
        ? null
        : typeof body.description === "string"
          ? body.description
          : existing.description,
    settings,
    createdAt: existing.createdAt,
    updatedAt: now,
  };
  if (space.name.trim().toLowerCase() !== existing.name.trim().toLowerCase()) {
    const duplicate = await env.SYNTILA_DB.prepare(
      `SELECT id FROM spaces
       WHERE owner_user_id = ?1 AND id <> ?2
         AND LOWER(TRIM(name)) = LOWER(TRIM(?3))
       LIMIT 1`,
    )
      .bind(existing.ownerUserId, spaceId, space.name)
      .first<{ id: string }>();
    if (duplicate) {
      throw new HttpError(409, "You already have a Space with this name");
    }
  }
  const settingsPatch = {
    ...incomingSettings,
    ...(typeof body.instructions === "string"
      ? { instructions: body.instructions }
      : {}),
    ...(typeof body.archived === "boolean" ? { archived: body.archived } : {}),
  };
  const mutation = env.SYNTILA_DB.prepare(
    `UPDATE spaces SET name = ?1, description = ?2,
       settings_json = json_patch(settings_json, ?3), updated_at = ?4
     WHERE id = ?5`,
  ).bind(
    space.name,
    space.description,
    JSON.stringify(settingsPatch),
    now,
    spaceId,
  );
  await publishCollaborationEvent(
    env,
    settings.archived === true &&
      spaceSettings(existing.settingsJson).archived !== true
      ? "space.archived"
      : "space.updated",
    spaceId,
    spaceId,
    { mutations: [mutation] },
  );
  return json({
    space: {
      ...space,
      settings: publicSpaceSettings(JSON.stringify(space.settings)),
      instructions:
        typeof space.settings.instructions === "string"
          ? space.settings.instructions
          : "",
    },
  });
}

export async function handleDeleteSpace(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:manage",
    spaceId,
    accessContext,
  );
  {
    try {
      await authorizeSpaceOwner(
        env.SYNTILA_DB,
        context,
        spaceId,
        "spaces:manage",
      );
    } catch (error) {
      throw new HttpError(
        403,
        error instanceof Error ? error.message : "Forbidden",
      );
    }
    const audience = await env.SYNTILA_DB.prepare(
      "SELECT user_id FROM space_memberships WHERE space_id = ?1",
    )
      .bind(spaceId)
      .all<{ user_id: string }>();
    const threadFilter = "SELECT id FROM threads WHERE space_id = ?1";
    const workRequestFilter = `SELECT id FROM work_requests WHERE thread_id IN (${threadFilter})`;
    const workflowTaskFilter = `SELECT id FROM workflow_tasks WHERE work_request_id IN (${workRequestFilter})`;
    // Ordered transactional cleanup removes children before their parents and
    // commits the deletion signal with the mutation.
    const cleanupStatements = [
      `DELETE FROM workflow_task_dependencies
       WHERE task_id IN (${workflowTaskFilter})
          OR depends_on_task_id IN (${workflowTaskFilter})`,
      `DELETE FROM workflow_tasks
       WHERE work_request_id IN (${workRequestFilter})`,
      "DELETE FROM worker_assignments WHERE space_id = ?1",
      "DELETE FROM runs WHERE space_id = ?1",
      `DELETE FROM work_requests
       WHERE thread_id IN (${threadFilter})`,
      `DELETE FROM thread_execution_policies
       WHERE thread_id IN (${threadFilter})`,
      `DELETE FROM discussion_messages
       WHERE thread_id IN (${threadFilter})`,
      "DELETE FROM threads WHERE space_id = ?1",
      "DELETE FROM workspace_space_grants WHERE space_id = ?1",
      "DELETE FROM space_invitations WHERE space_id = ?1",
      "DELETE FROM space_audit_log WHERE space_id = ?1",
      "DELETE FROM space_memberships WHERE space_id = ?1",
      "DELETE FROM artifacts WHERE space_id = ?1",
      "DELETE FROM spaces WHERE id = ?1",
    ];
    await publishCollaborationEvent(env, "space.deleted", spaceId, spaceId, {
      recipientUserIds: (audience.results ?? []).map((row) => row.user_id),
      mutations: cleanupStatements.map((sql) =>
        env.SYNTILA_DB.prepare(sql).bind(spaceId),
      ),
    });
    return json({ spaceId, deleted: true });
  }
}

export async function handleListSpaceMembers(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(request, env, "spaces:read", spaceId, accessContext);
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT pm.user_id AS userId, u.display_name AS displayName, u.email, pm.role, pm.created_at AS createdAt
     FROM space_memberships pm JOIN users u ON u.id = pm.user_id
     WHERE pm.space_id = ?1 ORDER BY CASE pm.role WHEN 'owner' THEN 0 WHEN 'collaborator' THEN 1 ELSE 2 END, u.display_name`,
  )
    .bind(spaceId)
    .all();
  const space = await env.SYNTILA_DB.prepare(
    "SELECT settings_json AS settingsJson FROM spaces WHERE id = ?1",
  )
    .bind(spaceId)
    .first<{ settingsJson: string }>();
  return json({
    // Usage against the owner's plan; pending invitations reserve a slot.
    usage: await getSpaceMemberUsage(env as unknown as Env, spaceId),
    members: (rows.results ?? []).map((row) => ({
      ...row,
      permissions: spaceMemberPermissions(
        String(row.role),
        space?.settingsJson,
        String(row.userId),
      ),
    })),
  });
}

export async function handleListSpaceInvitations(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:read",
    spaceId,
    accessContext,
  );
  const policy = await loadSpacePermissions(env, context.userId, spaceId);
  if (policy.role !== "owner") return json({ invitations: [] });
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT id, email, invitee_user_id AS inviteeUserId, role, status, expires_at AS expiresAt, created_at AS createdAt
     FROM space_invitations WHERE space_id = ?1 AND status = 'pending' ORDER BY created_at DESC`,
  )
    .bind(spaceId)
    .all();
  const snapshots = parseSpaceSettings(
    parseSpaceSettings(policy.settingsJson).invitationPermissions,
  );
  return json({
    invitations: (rows.results ?? []).map((row) => ({
      ...row,
      permissions:
        snapshots[String(row.id)] ??
        defaultSpaceMemberPermissions(String(row.role)),
    })),
  });
}

export async function handleListSpaceAudit(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(request, env, "spaces:read", spaceId, accessContext);
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT id, action, target_type AS targetType, target_id AS targetId, created_at AS createdAt
     FROM space_audit_log WHERE space_id = ?1 ORDER BY created_at DESC LIMIT 100`,
  )
    .bind(spaceId)
    .all();
  return json({ entries: rows.results ?? [] });
}

export async function handleCreateSpaceInvitation(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:read",
    spaceId,
    accessContext,
  );
  const policy = await requireSpaceOwner(env, context, spaceId);
  const body = (await request.json()) as Record<string, unknown>;
  // A retried send with the same Idempotency-Key returns the first result
  // instead of "already pending".
  const receipt = await MutationIdempotency.from(
    request,
    env.SYNTILA_DB,
    context.userId,
    `space-invitation:${spaceId}`,
    body,
  );
  const replay = await receipt?.replay();
  if (replay) return replay;
  if (
    Object.keys(body).some(
      (key) => !["email", "userId", "role", "permissions"].includes(key),
    ) ||
    (body.email !== undefined) === (body.userId !== undefined)
  )
    throw new HttpError(
      400,
      "Provide either an email address or an established Person userId",
    );
  let email: string;
  let inviteeUserId: string | null = null;
  if (body.userId !== undefined) {
    const userId = requiredString(body.userId, "userId");
    if (userId === context.userId)
      throw new HttpError(400, "You cannot invite yourself");
    const person = await env.SYNTILA_DB.prepare(
      `SELECT u.email FROM people_relationships p JOIN users u ON u.id=?2 AND u.status='active'
      WHERE p.user_low_id=MIN(?1,?2) AND p.user_high_id=MAX(?1,?2)`,
    )
      .bind(context.userId, userId)
      .first<{ email: string }>();
    if (!person)
      throw new HttpError(
        403,
        "An established People relationship is required",
      );
    inviteeUserId = userId;
    email = person.email.trim().toLowerCase();
  } else email = requiredString(body.email, "email").trim().toLowerCase();
  if (email === context.user.email.trim().toLowerCase())
    throw new HttpError(400, "You cannot invite yourself");
  const role =
    body.role === "viewer" || body.role === "collaborator" ? body.role : null;
  if (!role || !email.includes("@"))
    throw new HttpError(400, "Valid email and Space role are required");
  const requestedPermissions =
    body.permissions === undefined
      ? defaultSpaceMemberPermissions(role)
      : validateMemberPermissions(body.permissions);
  const permissions = Object.fromEntries(
    SPACE_MEMBER_PERMISSION_KEYS.map((key) => [
      key,
      requestedPermissions[key] && policy.rights[key],
    ]),
  );
  if (
    body.permissions !== undefined &&
    SPACE_MEMBER_PERMISSION_KEYS.some(
      (key) => requestedPermissions[key] && !policy.rights[key],
    )
  )
    throw new HttpError(
      403,
      "You cannot invite a member with rights you do not hold",
    );
  const existingMember = await env.SYNTILA_DB.prepare(
    `SELECT pm.user_id FROM space_memberships pm
     JOIN users u ON u.id = pm.user_id
     WHERE pm.space_id = ?1 AND (pm.user_id = ?3 OR LOWER(u.email) = LOWER(?2))
     LIMIT 1`,
  )
    .bind(spaceId, email, inviteeUserId)
    .first<{ user_id: string }>();
  if (existingMember) {
    throw new HttpError(409, "This user is already a Space member");
  }
  await env.SYNTILA_DB.prepare(
    "UPDATE space_invitations SET status='expired',updated_at=?3 WHERE space_id=?1 AND (LOWER(email)=?2 OR invitee_user_id=?4) AND status='pending' AND expires_at<=?3",
  )
    .bind(spaceId, email, new Date().toISOString(), inviteeUserId)
    .run();
  const existingInvitation = await env.SYNTILA_DB.prepare(
    `SELECT id FROM space_invitations
     WHERE space_id = ?1 AND status = 'pending' AND (LOWER(email) = LOWER(?2) OR invitee_user_id = ?3)
     LIMIT 1`,
  )
    .bind(spaceId, email, inviteeUserId)
    .first<{ id: string }>();
  if (existingInvitation) {
    throw new HttpError(
      409,
      "A pending invitation already exists for this user",
    );
  }
  // Friendly early refusal; the INSERT below enforces the same rule atomically.
  if (await spaceMemberCapacityRefused(env as unknown as Env, spaceId))
    throw new SpaceMemberLimitError("owner");
  const now = new Date();
  const id = `pinv-${crypto.randomUUID()}`;
  const token = `space_invite_${crypto.randomUUID()}_${crypto.randomUUID()}`;
  const invitation = {
    id,
    spaceId,
    email,
    inviteeUserId,
    role,
    status: "pending",
  };
  const tokenHash = await hashToken(token);
  try {
    // The stored replay omits the secret token; it is shown only once.
    const write = (receipts: D1PreparedStatement[]) =>
      env.SYNTILA_DB.batch([
        ...receipts,
        env.SYNTILA_DB.prepare(
          // A refused reservation writes a NULL into the NOT NULL token_hash,
          // which rolls back this whole batch (and any idempotency receipt).
          `INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at, invitee_user_id)
     SELECT ?1, ?2, ?3, ?4,
            CASE WHEN ${spaceMemberAdmissionSql("?2")} THEN ?5 ELSE NULL END,
            ?6, 'pending', ?7, ?8, ?8, ?9`,
        ).bind(
          id,
          spaceId,
          email,
          role,
          tokenHash,
          context.userId,
          new Date(now.getTime() + 7 * 86400000).toISOString(),
          now.toISOString(),
          inviteeUserId,
        ),
        env.SYNTILA_DB.prepare(
          "UPDATE spaces SET settings_json = json_set(settings_json, ?1, json(?2)), updated_at = ?3 WHERE id = ?4",
        ).bind(
          permissionJsonPath("invitationPermissions", id),
          JSON.stringify(permissions),
          now.toISOString(),
          spaceId,
        ),
      ]);
    const concurrentReplay = receipt
      ? await receipt.commit({ invitation }, 201, write)
      : (await write([]), null);
    if (concurrentReplay) return concurrentReplay;
  } catch (error) {
    if (
      error instanceof Error &&
      /NOT NULL constraint failed: space_invitations\.token_hash/i.test(
        error.message,
      )
    )
      throw new SpaceMemberLimitError("owner");
    if (
      error instanceof Error &&
      /UNIQUE constraint failed.*(idx_space_invitations_pending_email|space_invitations.space_id, space_invitations.invitee_user_id)/i.test(
        error.message,
      )
    )
      throw new HttpError(
        409,
        "A pending invitation already exists for this user",
      );
    throw error;
  }
  await env.SYNTILA_DB.prepare(
    `INSERT INTO space_audit_log (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
     VALUES (?1, ?2, 'user', ?3, 'space.invitation.created', 'invitation', ?4, ?5, ?6)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      spaceId,
      context.userId,
      id,
      JSON.stringify({ email, role }),
      now.toISOString(),
    )
    .run();
  const recipient = inviteeUserId
    ? { id: inviteeUserId }
    : await env.SYNTILA_DB.prepare(
        `SELECT id FROM users WHERE LOWER(email) = LOWER(?1) LIMIT 1`,
      )
        .bind(email)
        .first<{ id: string }>();
  await publishCollaborationEvent(env, "space.updated", spaceId, id, {
    additionalRecipientUserIds: inviteeUserId
      ? [inviteeUserId]
      : recipient
        ? [recipient.id]
        : [],
  });

  const spaceRow = await env.SYNTILA_DB.prepare(
    `SELECT name FROM spaces WHERE id = ?1`,
  )
    .bind(spaceId)
    .first<{ name: string }>();
  const spaceName = spaceRow?.name ?? "Space";
  const appUrl = resolveAppUrl(request, env);
  const invitationLink = `${appUrl}/?invitation=${id}`;

  try {
    await sendSpaceInvitationEmail(env, {
      recipientEmail: email,
      inviterName:
        context.user.displayName || context.user.email || "A team member",
      spaceName,
      role,
      appUrl: invitationLink,
    });
  } catch (emailError) {
    const failure = classifyEmailDeliveryFailure(emailError);
    console.warn("Failed to dispatch invitation email", {
      status: failure.status,
      providerCode: failure.providerCode,
    });
  }

  return json({ invitation, token }, { status: 201 });
}

export async function handleChangeSpaceMemberRole(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  userId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeSpaceOwnerOrThrow(
    request,
    env,
    spaceId,
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const permissions =
    body.permissions === undefined
      ? null
      : validateMemberPermissions(body.permissions);
  const role = permissions
    ? SPACE_MEMBER_PERMISSION_KEYS.some((key) => permissions[key])
      ? "collaborator"
      : "viewer"
    : body.role === "viewer" || body.role === "collaborator"
      ? body.role
      : null;
  if (!role)
    throw new HttpError(400, "Space role or member permissions are required");
  const member = await env.SYNTILA_DB.prepare(
    "SELECT role FROM space_memberships WHERE space_id = ?1 AND user_id = ?2",
  )
    .bind(spaceId, userId)
    .first<{ role: string }>();
  if (!member) throw new HttpError(404, "Space member not found");
  if (member.role === "owner")
    throw new HttpError(403, "Owner permissions cannot be changed");
  await env.SYNTILA_DB.batch([
    env.SYNTILA_DB.prepare(
      "UPDATE space_memberships SET role = ?1, updated_at = ?2 WHERE space_id = ?3 AND user_id = ?4 AND role <> 'owner'",
    ).bind(role, new Date().toISOString(), spaceId, userId),
    env.SYNTILA_DB.prepare(
      "UPDATE spaces SET settings_json = json_set(settings_json, ?1, json(?2)), updated_at = ?3 WHERE id = ?4",
    ).bind(
      permissionJsonPath("memberPermissions", userId),
      JSON.stringify(permissions ?? defaultSpaceMemberPermissions(role)),
      new Date().toISOString(),
      spaceId,
    ),
  ]);
  await env.SYNTILA_DB.prepare(
    `INSERT INTO space_audit_log (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, 'space.member.role_changed', 'user', ?4, ?5, ?6)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      spaceId,
      context.userId,
      userId,
      JSON.stringify({ role, permissions }),
      new Date().toISOString(),
    )
    .run();
  await publishCollaborationEvent(env, "space.updated", spaceId, userId, {
    additionalRecipientUserIds: [userId],
  });
  return json({
    spaceId,
    userId,
    role,
    permissions: permissions ?? defaultSpaceMemberPermissions(role),
  });
}

export async function handleRemoveSpaceMember(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  userId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeSpaceOwnerOrThrow(
    request,
    env,
    spaceId,
    accessContext,
  );
  const result = await env.SYNTILA_DB.prepare(
    `DELETE FROM space_memberships WHERE space_id = ?1 AND user_id = ?2 AND role <> 'owner'`,
  )
    .bind(spaceId, userId)
    .run();
  if (!result.success || (result.meta?.changes ?? 0) === 0)
    throw new HttpError(404, "Space member not found");
  await env.SYNTILA_DB.prepare(
    "UPDATE spaces SET settings_json = json_remove(settings_json, ?1) WHERE id = ?2",
  )
    .bind(permissionJsonPath("memberPermissions", userId), spaceId)
    .run();
  // A contributed execution Workspace is owned by the departing user. Revoke
  // that user's Space Grants with the membership removal so the scheduler
  // cannot continue using infrastructure after collaboration ends.
  await env.SYNTILA_DB.prepare(
    `UPDATE workspace_space_grants
        SET status = 'revoked', updated_at = ?1
      WHERE space_id = ?2 AND granted_by_user_id = ?3
        AND status IN ('active', 'suspended')`,
  )
    .bind(new Date().toISOString(), spaceId, userId)
    .run();
  await env.SYNTILA_DB.prepare(
    `INSERT INTO space_audit_log (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, 'space.member.removed', 'user', ?4, '{}', ?5)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      spaceId,
      context.userId,
      userId,
      new Date().toISOString(),
    )
    .run();
  await publishCollaborationEvent(env, "space.updated", spaceId, userId, {
    additionalRecipientUserIds: [userId],
  });
  return json({ spaceId, userId, removed: true });
}

export async function handleExpireSpaceInvitation(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  invitationId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:read",
    spaceId,
    accessContext,
  );
  await requireSpaceOwner(env, context, spaceId);
  const existing = await env.SYNTILA_DB.prepare(
    `SELECT id, email, invitee_user_id AS inviteeUserId FROM space_invitations WHERE id = ?1 AND space_id = ?2 AND status = 'pending'`,
  )
    .bind(invitationId, spaceId)
    .first<{
      id: string;
      email: string;
      inviteeUserId: string | null;
    }>();
  if (!existing) throw new HttpError(404, "Pending invitation not found");

  const result = await env.SYNTILA_DB.prepare(
    `UPDATE space_invitations SET status = 'expired', updated_at = ?1 WHERE id = ?2 AND space_id = ?3 AND status = 'pending'`,
  )
    .bind(new Date().toISOString(), invitationId, spaceId)
    .run();
  if (!result.success || (result.meta?.changes ?? 0) === 0)
    throw new HttpError(404, "Pending invitation not found");
  await env.SYNTILA_DB.prepare(
    "UPDATE spaces SET settings_json = json_remove(settings_json, ?1) WHERE id = ?2",
  )
    .bind(permissionJsonPath("invitationPermissions", invitationId), spaceId)
    .run();
  await env.SYNTILA_DB.prepare(
    `INSERT INTO space_audit_log (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, 'space.invitation.expired', 'invitation', ?4, '{}', ?5)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      spaceId,
      context.userId,
      invitationId,
      new Date().toISOString(),
    )
    .run();
  const recipient = existing.inviteeUserId
    ? { id: existing.inviteeUserId }
    : await env.SYNTILA_DB.prepare(
        `SELECT id FROM users WHERE LOWER(email) = LOWER(?1) LIMIT 1`,
      )
        .bind(existing.email)
        .first<{ id: string }>();
  await publishCollaborationEvent(env, "space.updated", spaceId, invitationId, {
    additionalRecipientUserIds: existing.inviteeUserId
      ? [existing.inviteeUserId]
      : recipient
        ? [recipient.id]
        : [],
  });
  return json({ id: invitationId, status: "expired" });
}

export async function handleListCurrentUserInvitations(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const email = context.user.email.trim().toLowerCase();
  const now = new Date().toISOString();
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT 
       pi.id,
       pi.space_id AS spaceId,
       p.name AS spaceName,
       pi.email,
       pi.invitee_user_id AS inviteeUserId,
       pi.role,
       pi.status,
       pi.invited_by_user_id AS invitedByUserId,
       u.display_name AS invitedByUserName,
       u.email AS invitedByUserEmail,
       pi.expires_at AS expiresAt,
       pi.created_at AS createdAt
     FROM space_invitations pi
     JOIN spaces p ON p.id = pi.space_id
     JOIN users u ON u.id = pi.invited_by_user_id
     WHERE (pi.invitee_user_id = ?3 OR (pi.invitee_user_id IS NULL AND LOWER(pi.email) = ?1)) AND pi.status = 'pending' AND pi.expires_at > ?2
     ORDER BY pi.created_at DESC`,
  )
    .bind(email, now, context.userId)
    .all();
  return json({ invitations: rows.results ?? [] });
}

export async function handleAcceptSpaceInvitation(
  request: Request,
  env: SecurityEnv,
  invitationId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const invitation = await env.SYNTILA_DB.prepare(
    `SELECT id, space_id AS spaceId, email, invitee_user_id AS inviteeUserId, role, status, invited_by_user_id AS invitedByUserId, accepted_by_user_id AS acceptedByUserId, expires_at AS expiresAt
     FROM space_invitations WHERE id = ?1`,
  )
    .bind(invitationId)
    .first<{
      invitedByUserId: string;
      acceptedByUserId: string | null;
      id: string;
      spaceId: string;
      email: string;
      inviteeUserId: string | null;
      role: "collaborator" | "viewer";
      status: string;
      expiresAt: string;
    }>();
  // A retried accept by the same person repeats the first result.
  if (
    invitation?.status === "accepted" &&
    invitation.acceptedByUserId === context.userId
  )
    return json({
      id: invitation.id,
      spaceId: invitation.spaceId,
      role: invitation.role,
      status: "accepted",
      accepted: true,
    });
  if (!invitation || invitation.status !== "pending")
    throw new HttpError(404, "Space invitation not found");
  if (new Date(invitation.expiresAt).getTime() <= Date.now())
    throw new HttpError(410, "Space invitation expired");
  if (
    invitation.inviteeUserId !== null
      ? invitation.inviteeUserId !== context.userId
      : context.user.email.trim().toLowerCase() !==
        invitation.email.trim().toLowerCase()
  )
    throw new HttpError(
      403,
      "Invitation recipient does not match signed-in user",
    );
  const inviter = await loadSpacePermissions(
    env,
    invitation.invitedByUserId,
    invitation.spaceId,
  );
  if (inviter.role !== "owner")
    throw new HttpError(403, "The inviter can no longer invite members");
  const settings = parseSpaceSettings(inviter.settingsJson);
  const snapshot = parseSpaceSettings(
    parseSpaceSettings(settings.invitationPermissions)[invitation.id],
  );
  const defaults = defaultSpaceMemberPermissions(invitation.role);
  const permissions = Object.fromEntries(
    SPACE_MEMBER_PERMISSION_KEYS.map((key) => [
      key,
      (Object.keys(snapshot).length ? snapshot[key] === true : defaults[key]) &&
        inviter.rights[key],
    ]),
  );
  const existingMember = await env.SYNTILA_DB.prepare(
    "SELECT user_id FROM space_memberships WHERE space_id = ?1 AND user_id = ?2",
  )
    .bind(invitation.spaceId, context.userId)
    .first();
  if (existingMember)
    throw new HttpError(409, "You are already a member of this Space");
  // The invitation's own reservation becomes the membership, so it is not
  // counted against itself; an over-limit Free Space blocks acceptance.
  if (
    await spaceMemberCapacityRefused(
      env as unknown as Env,
      invitation.spaceId,
      invitation.id,
    )
  )
    throw new SpaceMemberLimitError("member");
  const membershipId = `pm-${crypto.randomUUID()}`;
  const now = new Date().toISOString();
  let acceptance;
  try {
    acceptance = await env.SYNTILA_DB.batch([
      env.SYNTILA_DB.prepare(
        `UPDATE space_invitations SET status = CASE WHEN ${spaceMemberAdmissionSql("?4", "?3")} THEN 'accepted' ELSE NULL END, invitee_user_id = COALESCE(invitee_user_id, ?1), accepted_by_user_id = ?1, accepted_at = ?2, updated_at = ?2 WHERE id = ?3 AND status = 'pending' AND expires_at > ?2`,
      ).bind(context.userId, now, invitation.id, invitation.spaceId),

      env.SYNTILA_DB.prepare(
        `INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) SELECT ?1, ?2, ?3, ?4, ?5, ?5 WHERE EXISTS (SELECT 1 FROM space_invitations WHERE id=?6 AND status='accepted' AND accepted_by_user_id=?3 AND accepted_at=?5) ON CONFLICT(space_id, user_id) DO NOTHING`,
      ).bind(
        membershipId,
        invitation.spaceId,
        context.userId,
        invitation.role,
        now,
        invitation.id,
      ),
      env.SYNTILA_DB.prepare(
        "UPDATE spaces SET settings_json = json_remove(json_set(settings_json, ?1, json(?2)), ?3), updated_at = ?4 WHERE id = ?5 AND EXISTS (SELECT 1 FROM space_memberships WHERE id = ?6)",
      ).bind(
        permissionJsonPath("memberPermissions", context.userId),
        JSON.stringify(permissions),
        permissionJsonPath("invitationPermissions", invitation.id),
        now,
        invitation.spaceId,
        membershipId,
      ),
      env.SYNTILA_DB.prepare(
        `INSERT INTO space_audit_log (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) SELECT ?1, ?2, 'user', ?3, 'space.invitation.accepted', 'invitation', ?4, '{}', ?5 WHERE EXISTS(SELECT 1 FROM space_memberships WHERE id=?6)`,
      ).bind(
        `pa-${crypto.randomUUID()}`,
        invitation.spaceId,
        context.userId,
        invitation.id,
        now,
        membershipId,
      ),
    ]);
  } catch (error) {
    if (
      error instanceof Error &&
      /NOT NULL constraint failed: space_invitations\.status/i.test(
        error.message,
      )
    )
      throw new SpaceMemberLimitError("member");
    throw error;
  }
  if (acceptance[0]?.meta?.changes === 0)
    throw new HttpError(409, "Invitation changed before acceptance");
  await publishCollaborationEvent(
    env,
    "space.updated",
    invitation.spaceId,
    invitation.id,
    {
      // The inviter also hears it on their own stream, outside the Space view.
      additionalRecipientUserIds: [context.userId, invitation.invitedByUserId],
    },
  );
  return json({
    id: invitation.id,
    spaceId: invitation.spaceId,
    role: invitation.role,
    status: "accepted",
    accepted: true,
  });
}

export async function handleDeclineSpaceInvitation(
  request: Request,
  env: SecurityEnv,
  invitationId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const invitation = await env.SYNTILA_DB.prepare(
    `SELECT id, space_id AS spaceId, email, invitee_user_id AS inviteeUserId, role, status, invited_by_user_id AS invitedByUserId, expires_at AS expiresAt
     FROM space_invitations WHERE id = ?1`,
  )
    .bind(invitationId)
    .first<{
      invitedByUserId: string;
      id: string;
      spaceId: string;
      email: string;
      inviteeUserId: string | null;
      role: "collaborator" | "viewer";
      status: string;
      expiresAt: string;
    }>();
  const isRecipient =
    !!invitation &&
    (invitation.inviteeUserId !== null
      ? invitation.inviteeUserId === context.userId
      : context.user.email.trim().toLowerCase() ===
        invitation.email.trim().toLowerCase());
  // A retried decline by the recipient repeats the first result.
  if (invitation?.status === "declined" && isRecipient)
    return json({
      id: invitation.id,
      spaceId: invitation.spaceId,
      status: "declined",
      declined: true,
    });
  if (!invitation || invitation.status !== "pending")
    throw new HttpError(404, "Space invitation not found");
  if (new Date(invitation.expiresAt).getTime() <= Date.now())
    throw new HttpError(410, "Space invitation expired");
  if (!isRecipient)
    throw new HttpError(
      403,
      "Invitation recipient does not match signed-in user",
    );
  const now = new Date().toISOString();
  await env.SYNTILA_DB.batch([
    env.SYNTILA_DB.prepare(
      "UPDATE spaces SET settings_json = json_remove(settings_json, ?1) WHERE id = ?2",
    ).bind(
      permissionJsonPath("invitationPermissions", invitation.id),
      invitation.spaceId,
    ),
    env.SYNTILA_DB.prepare(
      `UPDATE space_invitations SET status = 'declined', updated_at = ?1 WHERE id = ?2 AND status = 'pending'`,
    ).bind(now, invitation.id),
    env.SYNTILA_DB.prepare(
      `INSERT INTO space_audit_log (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, 'space.invitation.declined', 'invitation', ?4, '{}', ?5)`,
    ).bind(
      `pa-${crypto.randomUUID()}`,
      invitation.spaceId,
      context.userId,
      invitation.id,
      now,
    ),
  ]);
  await publishCollaborationEvent(
    env,
    "space.updated",
    invitation.spaceId,
    invitation.id,
    {
      additionalRecipientUserIds: [context.userId, invitation.invitedByUserId],
    },
  );
  return json({
    id: invitation.id,
    spaceId: invitation.spaceId,
    status: "declined",
    declined: true,
  });
}
