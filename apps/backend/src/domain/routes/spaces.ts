import { inTransaction, lockStatement } from "../../platform/tx-env.js";
import { afterCursorSql, cursorOrderSql, pageOf, pageRequest } from "./pagination.js";
import {
  CreateSpaceSchema,
  SpaceInvitationSchema,
  SpaceMemberRoleSchema,
  UpdateSpaceSchema,
} from "@syntila/protocol";
import { readBody } from "./validation.js";
import { isSpaceMember, spaceKind, spaceMembership, spaceNameOf, userByEmail } from "../queries.js";
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
  GRANTED_SPACE_RIGHT_KEYS,
  normalizeSpaceMemberSnapshot,
  storedSpaceMemberRights,
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
import { avatarUrlFor } from "./profile.js";
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
import { dataOf } from "../../platform/data.js";

async function findDirectSpacePeer(
  env: SpaceEnv,
  userId: string,
  spaceId: string,
) {
  return dataOf(env).read.row<{
    id: string;
    displayName: string;
    avatarUrl: string | null;
    personalName: string | null;
  }>`SELECT u.id, u.display_name AS "displayName", u.avatar_url AS "avatarUrl",
            state.personal_name AS "personalName"
       FROM direct_spaces ds
       JOIN users u ON u.id = (CASE WHEN ds.user_low_id = ${userId} THEN ds.user_high_id ELSE ds.user_low_id END)
       LEFT JOIN direct_space_user_state state ON state.space_id = ds.space_id AND state.user_id = ${userId}
      WHERE ds.space_id = ${spaceId}`;
}

const UPDATE_SPACES_SET_SETTINGS_JSON_BY_ID =
  "UPDATE spaces SET settings_json = syntila_json_set(settings_json, ?1, ?2), updated_at = ?3 WHERE id = ?4";

async function removeSpaceSetting(
  q: Pick<ReturnType<typeof dataOf>["read"], "run">,
  spaceId: string,
  path: string,
) {
  return q.run`UPDATE spaces SET settings_json = syntila_json_remove(settings_json, ${path}) WHERE id = ${spaceId}`;
}

async function setSpaceSetting(
  q: Pick<ReturnType<typeof dataOf>["read"], "run">,
  spaceId: string,
  path: string,
  valueJson: string,
  now = new Date().toISOString(),
) {
  await q.run`UPDATE spaces SET settings_json = syntila_json_set(settings_json, ${path}, ${valueJson}), updated_at = ${now} WHERE id = ${spaceId}`;
}

async function recordSpaceAudit(
  q: Pick<ReturnType<typeof dataOf>["read"], "run">,
  spaceId: string,
  actorId: string,
  action: string,
  targetType: string,
  targetId: string,
  detailsJson = "{}",
  now = new Date().toISOString(),
) {
  await q.run`INSERT INTO space_audit_log (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (${`pa-${crypto.randomUUID()}`}, ${spaceId}, 'user', ${actorId}, ${action}, ${targetType}, ${targetId}, ${detailsJson}, ${now})`;
}

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
    const read = dataOf(env).read;
    const rows = await read.rows<{
      id: string;
      name: string;
      description: string | null;
      role: string;
      kind: string;
      settingsJson: string;
      createdAt: string;
      updatedAt: string;
      peerUserId: string | null;
      peerDisplayName: string | null;
      personalName: string | null;
      peerAvatarUrl: string | null;
      hidden: number;
      isSupport: number;
      hasActiveWork: number;
      hasUnread: number;
      pinnedAt: string | null;
      pinPosition: number | null;
    }>`SELECT p.id, p.name, p.description, pm.role, COALESCE(p.kind, 'group') AS kind,
              p.settings_json AS "settingsJson", p.created_at AS "createdAt", ${read.raw(lastSpaceActivitySql("p"))} AS "updatedAt",
              peer_u.id AS "peerUserId",
              peer_u.display_name AS "peerDisplayName",
              dsus.personal_name AS "personalName",
              peer_u.avatar_url AS "peerAvatarUrl",
              COALESCE(dsus.hidden, FALSE) AS hidden,
              EXISTS (SELECT 1 FROM support_spaces ss WHERE ss.space_id = p.id) AS "isSupport",
              EXISTS (
                SELECT 1 FROM threads t
                 WHERE t.space_id = p.id AND ${read.raw(activeWorkSql("t"))}
              ) AS "hasActiveWork",
              EXISTS (
                SELECT 1 FROM threads t
                  LEFT JOIN thread_read_states rs
                    ON rs.thread_id = t.id AND rs.user_id = pm.user_id
                 WHERE t.space_id = p.id
                   AND ${read.raw(unreadSql("t", "pm.user_id", "COALESCE(rs.read_at, pm.created_at)"))}
              ) AS "hasUnread",
              (SELECT up.pinned_at FROM user_pins up
                WHERE up.user_id = pm.user_id AND up.kind = 'space'
                  AND up.target_id = p.id) AS "pinnedAt",
              (SELECT up.position FROM user_pins up
                WHERE up.user_id = pm.user_id AND up.kind = 'space'
                  AND up.target_id = p.id) AS "pinPosition"
       FROM spaces p
       JOIN space_memberships pm ON pm.space_id = p.id
       LEFT JOIN direct_spaces ds ON ds.space_id = p.id
       LEFT JOIN users peer_u ON peer_u.id = (CASE WHEN ds.user_low_id = pm.user_id THEN ds.user_high_id ELSE ds.user_low_id END)
       LEFT JOIN direct_space_user_state dsus ON dsus.space_id = p.id AND dsus.user_id = pm.user_id
       WHERE pm.user_id = ${context.userId}
         ${
           includeArchived
             ? read.raw("")
             : read.raw(`AND COALESCE((p.settings_json::jsonb ->> 'archived'), 'false') NOT IN ('true', '1')
                AND (
                  (p.kind != 'direct' AND NOT COALESCE(dsus.hidden, FALSE))
                  OR (
                    EXISTS (SELECT 1 FROM support_spaces ss WHERE ss.space_id = p.id AND ss.user_id = pm.user_id)
                    AND NOT COALESCE(dsus.hidden, TRUE)
                  )
                  OR (
                    NOT EXISTS (SELECT 1 FROM support_spaces ss WHERE ss.space_id = p.id AND ss.user_id = pm.user_id)
                    AND
                    NOT COALESCE(dsus.hidden, FALSE)
                    AND (
                      dsus.last_opened_at IS NOT NULL
                      OR EXISTS (
                        SELECT 1 FROM user_pins up
                        WHERE up.user_id = pm.user_id AND up.kind = 'space' AND up.target_id = p.id
                      )
                      OR EXISTS (
                        SELECT 1 FROM threads t
                        LEFT JOIN thread_read_states rs
                          ON rs.thread_id = t.id AND rs.user_id = pm.user_id
                        WHERE t.space_id = p.id
                          AND ${unreadSql("t", "pm.user_id", "COALESCE(rs.read_at, pm.created_at)")}
                      )
                      OR EXISTS (
                        SELECT 1 FROM threads t
                        WHERE t.space_id = p.id AND ${activeWorkSql("t")}
                      )
                      OR EXISTS (
                        SELECT 1 FROM discussion_messages dm
                        JOIN threads t ON t.id = dm.thread_id
                        WHERE t.space_id = p.id
                      )
                    )
                  )
                )`)
         }
       ORDER BY "updatedAt" DESC, p.id DESC`;

    const spaces = rows.map((row) => {
      const settings = publicSpaceSettings(row.settingsJson);
      const isDirect = row.kind === "direct";
      return {
        id: row.id,
        name: isDirect
          ? (row.personalName ?? row.peerDisplayName ?? row.name)
          : row.name,
        description: row.description,
        role: row.role,
        kind: row.kind ?? "group",
        isSupport: row.isSupport === 1,
        avatarUrl:
          isDirect && row.peerUserId
            ? avatarUrlFor(request, row.peerUserId, row.peerAvatarUrl)
            : null,
        permissions: spaceMemberPermissions(
          row.role,
          row.settingsJson,
          context.userId,
        ),
        instructions:
          typeof settings.instructions === "string"
            ? settings.instructions
            : "",
        settings: isDirect
          ? {
              ...settings,
              personalName: row.personalName,
              originalName: row.peerDisplayName,
            }
          : settings,
        archived: row.hidden === 1 || settings.archived === true,
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
  const body = await readBody(request, CreateSpaceSchema);
  const name = body.name;
  const description = body.description ?? null;
  const settings: Record<string, unknown> = { ...(body.settings ?? {}) };
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
  const workspaceId = body.workspaceId || null;
  const now = new Date().toISOString();
  const id = `space-${crypto.randomUUID()}`;

  // Per-owner lock: the duplicate-name check and the insert cannot interleave
  // with another create by the same person.
  return inTransaction(env, "space.create", async (env, tx) => {
    await tx.lock("syntila.spaces_of", context.userId);
    const duplicate = await dataOf(env).read.row<{ id: string }>`SELECT id FROM spaces
       WHERE owner_user_id = ${context.userId} AND LOWER(TRIM(name)) = LOWER(TRIM(${name}))
       LIMIT 1`;
    if (duplicate) {
      throw new HttpError(409, "You already have a Space with this name");
    }
    // Refused (403) when the chosen Workspace is not owned or lent to the
    // creator; nothing is created then.
    const applyGrant = workspaceId
      ? await prepareWorkflowWorkspaceGrant(
          env,
          context.userId,
          id,
          workspaceId,
          now,
        )
      : null;
    await publishCollaborationEvent(env, "space.created", id, id, {
      tx: async (tx) => {
        await tx.run`
          INSERT INTO spaces (id, owner_user_id, name, description, settings_json, created_at, updated_at, kind)
          VALUES (${id}, ${context.userId}, ${name}, ${description}, ${JSON.stringify(settings)}, ${now}, ${now}, 'group')
        `;
        await tx.run`
          INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at)
          VALUES (${`pm-${crypto.randomUUID()}`}, ${id}, ${context.userId}, 'owner', ${now}, ${now})
          ON CONFLICT(space_id, user_id) DO NOTHING
        `;
        await tx.run`
          INSERT INTO space_workflow_settings(space_id, workspace_id, updated_at) VALUES (${id}, ${workspaceId}, ${now})
        `;
        if (applyGrant) await applyGrant(tx);
      },
    });
    return json(
      {
        space: {
          id,
          name,
          description,
          kind: "group",
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
  });
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
  const row = await dataOf(env).read.row<{
      id: string;
      name: string;
      description: string | null;
      role: string;
      kind: string;
      settingsJson: string;
      createdAt: string;
      updatedAt: string;
      peerUserId: string | null;
      peerDisplayName: string | null;
      personalName: string | null;
      peerAvatarUrl: string | null;
      isSupport: number;
    }>`SELECT p.id, p.name, p.description, pm.role, COALESCE(p.kind, 'group') AS kind,
            EXISTS (SELECT 1 FROM support_spaces ss WHERE ss.space_id = p.id) AS "isSupport",
            p.settings_json AS "settingsJson", p.created_at AS "createdAt", p.updated_at AS "updatedAt",
            peer_u.id AS "peerUserId",
            peer_u.display_name AS "peerDisplayName",
            dsus.personal_name AS "personalName",
            peer_u.avatar_url AS "peerAvatarUrl"
     FROM spaces p
     JOIN space_memberships pm ON pm.space_id = p.id
     LEFT JOIN direct_spaces ds ON ds.space_id = p.id
     LEFT JOIN users peer_u ON peer_u.id = (CASE WHEN ds.user_low_id = ${context.userId} THEN ds.user_high_id ELSE ds.user_low_id END)
     LEFT JOIN direct_space_user_state dsus ON dsus.space_id = p.id AND dsus.user_id = ${context.userId}
     WHERE p.id = ${spaceId} AND pm.user_id = ${context.userId}`;
  if (!row) throw new HttpError(404, "Space not found");
  const settings = publicSpaceSettings(row.settingsJson);
  const isDirect = row.kind === "direct";
  if (isDirect) {
    const now = new Date().toISOString();
    // Opening a support Space must not change the user's sidebar preference.
    await dataOf(env).read.run`INSERT INTO direct_space_user_state (space_id, user_id, hidden, last_opened_at, created_at, updated_at)
       VALUES (${spaceId}, ${context.userId}, EXISTS (SELECT 1 FROM support_spaces WHERE space_id = ${spaceId} AND user_id = ${context.userId}), ${now}, ${now}, ${now})
       ON CONFLICT(space_id, user_id) DO UPDATE SET
         last_opened_at = excluded.last_opened_at,
         hidden = CASE WHEN EXISTS (SELECT 1 FROM support_spaces WHERE space_id = ${spaceId} AND user_id = ${context.userId}) THEN direct_space_user_state.hidden ELSE FALSE END,
         updated_at = excluded.updated_at`;
  }
  return conditionalJson(request, {
    space: {
      id: row.id,
      name: isDirect
        ? (row.personalName ?? row.peerDisplayName ?? row.name)
        : row.name,
      description: row.description,
      role: row.role,
      kind: row.kind ?? "group",
      isSupport: row.isSupport === 1,
      avatarUrl:
        isDirect && row.peerUserId
          ? avatarUrlFor(request, row.peerUserId, row.peerAvatarUrl)
          : null,
      permissions: spaceMemberPermissions(
        row.role,
        row.settingsJson,
        context.userId,
      ),
      instructions:
        typeof settings.instructions === "string" ? settings.instructions : "",
      settings: isDirect
        ? {
            ...settings,
            personalName: row.personalName,
            originalName: row.peerDisplayName,
          }
        : settings,
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
    "spaces:read",
    spaceId,
    accessContext,
  );
  const existing = await dataOf(env).read.row<{
      id: string;
      ownerUserId: string;
      name: string;
      description: string | null;
      kind: string;
      settingsJson: string;
      createdAt: string;
      updatedAt: string;
    }>`SELECT id, owner_user_id AS "ownerUserId", name, description,
            COALESCE(kind, 'group') AS kind,
            settings_json AS "settingsJson",
            created_at AS "createdAt", updated_at AS "updatedAt"
     FROM spaces WHERE id = ${spaceId}`;
  if (!existing) throw new HttpError(404, "Space not found");

  const body = await readBody(request, UpdateSpaceSchema);
  const personalSettings =
    body.settings &&
    typeof body.settings === "object" &&
    !Array.isArray(body.settings)
      ? (body.settings as Record<string, unknown>)
      : undefined;
  if (
    existing.kind === "direct" &&
    personalSettings &&
    Object.prototype.hasOwnProperty.call(personalSettings, "personalName")
  ) {
    if (
      Object.keys(body).some((key) => key !== "settings") ||
      Object.keys(personalSettings).some((key) => key !== "personalName")
    ) {
      throw new HttpError(400, "Personal name must be updated separately");
    }
    const input = personalSettings.personalName;
    if (
      input !== null &&
      (typeof input !== "string" || !input.trim() || input.trim().length > 120)
    ) {
      throw new HttpError(
        400,
        "Personal name must be between 1 and 120 characters",
      );
    }
    const personalName = typeof input === "string" ? input.trim() : null;
    const member = await dataOf(env).read.row<{ role: string; isSupport: number }>`SELECT role, EXISTS (SELECT 1 FROM support_spaces WHERE space_id = ${spaceId}) AS "isSupport" FROM space_memberships WHERE space_id = ${spaceId} AND user_id = ${context.userId}`;
    if (!member) throw new HttpError(403, "Forbidden");
    const peer = await dataOf(env).read.row<{ id: string; displayName: string; avatarUrl: string | null }>`SELECT u.id, u.display_name AS "displayName", u.avatar_url AS "avatarUrl"
       FROM direct_spaces ds JOIN users u
         ON u.id = CASE WHEN ds.user_low_id = ${context.userId} THEN ds.user_high_id ELSE ds.user_low_id END
       WHERE ds.space_id = ${spaceId}`;
    if (!peer) throw new HttpError(404, "Person not found");
    const now = new Date().toISOString();
    await dataOf(env).read.run`INSERT INTO direct_space_user_state (space_id, user_id, hidden, personal_name, created_at, updated_at)
       VALUES (${spaceId}, ${context.userId}, EXISTS (SELECT 1 FROM support_spaces WHERE space_id = ${spaceId} AND user_id = ${context.userId}), ${personalName}, ${now}, ${now})
       ON CONFLICT(space_id, user_id) DO UPDATE SET personal_name = excluded.personal_name, updated_at = excluded.updated_at`;
    await publishCollaborationEvent(env, "space.updated", spaceId, spaceId, {
      recipientUserIds: [context.userId],
    });
    const settings = publicSpaceSettings(existing.settingsJson);
    return json({
      space: {
        id: existing.id,
        name: personalName ?? peer.displayName,
        description: existing.description,
        role: member.role,
        kind: "direct",
        isSupport: member.isSupport === 1,
        avatarUrl: avatarUrlFor(request, peer.id, peer.avatarUrl),
        permissions: spaceMemberPermissions(
          member.role,
          existing.settingsJson,
          context.userId,
        ),
        instructions:
          typeof settings.instructions === "string"
            ? settings.instructions
            : "",
        settings: { ...settings, personalName, originalName: peer.displayName },
        createdAt: existing.createdAt,
        updatedAt: now,
      },
    });
  }
  if (body.kind !== undefined && body.kind !== existing.kind) {
    throw new HttpError(400, "Space kind cannot be changed");
  }
  if (
    body.ownerUserId !== undefined &&
    body.ownerUserId !== existing.ownerUserId
  ) {
    throw new HttpError(400, "Space ownership cannot be transferred");
  }
  if (
    existing.kind === "direct" &&
    body.name !== undefined &&
    body.name !== existing.name
  ) {
    throw new HttpError(400, "Direct Space name cannot be modified");
  }
  // A personal Space is named after the other person, so the name is fixed.
  if (existing.kind === "direct") delete body.name;

  const isDirect = existing.kind === "direct";
  // Direct Spaces and shared Spaces are archived for the caller only.
  const requestedSettings =
    body.settings && typeof body.settings === "object"
      ? (body.settings as Record<string, unknown>)
      : undefined;
  const archiveFlag = [
    body.hidden,
    body.archived,
    requestedSettings?.archived,
  ].find((value) => typeof value === "boolean") as boolean | undefined;
  const targetHidden =
    isDirect || context.userId !== existing.ownerUserId
      ? archiveFlag
      : undefined;

  if (targetHidden !== undefined) {
    const allowedKeys = new Set(["archived", "hidden", "settings"]);
    if (
      Object.keys(body).some((key) => !allowedKeys.has(key)) ||
      (requestedSettings &&
        Object.keys(requestedSettings).some((key) => key !== "archived"))
    ) {
      throw new HttpError(403, "Only personal archive state can be changed");
    }
    const membership = await spaceMembership(env, spaceId, context.userId);
    if (!membership) throw new HttpError(403, "Forbidden");
    const now = new Date().toISOString();
    // This existing per-user state table also stores shared Space visibility;
    // last_opened_at remains specific to Direct Space discovery.
    await dataOf(env).read.run`INSERT INTO direct_space_user_state (space_id, user_id, hidden, created_at, updated_at)
       VALUES (${spaceId}, ${context.userId}, ${targetHidden ? 1 : 0}::int::boolean, ${now}, ${now})
       ON CONFLICT(space_id, user_id) DO UPDATE SET
         hidden = excluded.hidden,
         updated_at = excluded.updated_at`;

    await publishCollaborationEvent(
      env,
      targetHidden ? "space.archived" : "space.updated",
      spaceId,
      spaceId,
      {
        recipientUserIds: [context.userId],
        additionalRecipientUserIds: [context.userId],
      },
    );

    let dynamicName = existing.name;
    let avatarUrl: string | null = null;
    const peer = isDirect
      ? await findDirectSpacePeer(env, context.userId, spaceId)
      : null;
    if (peer) {
      dynamicName = peer.personalName ?? peer.displayName;
      avatarUrl = avatarUrlFor(request, peer.id, peer.avatarUrl);
    }

    const settings = publicSpaceSettings(existing.settingsJson);
    return json({
      space: {
        id: existing.id,
        name: dynamicName,
        description: existing.description,
        role: membership.role,
        kind: existing.kind,
        ...(avatarUrl !== null ? { avatarUrl } : {}),
        permissions: spaceMemberPermissions(
          membership.role,
          existing.settingsJson,
          context.userId,
        ),
        instructions:
          typeof settings.instructions === "string"
            ? settings.instructions
            : "",
        settings: isDirect
          ? {
              ...settings,
              personalName: peer?.personalName ?? null,
              originalName: peer?.displayName ?? null,
            }
          : settings,
        archived: targetHidden,
        createdAt: existing.createdAt,
        updatedAt: now,
      },
    });
  }

  await authorizeRequest(request, env, "spaces:write", spaceId, accessContext);
  if (isDirect) {
    const membership = await spaceMembership(env, spaceId, context.userId);
    if (!membership) throw new HttpError(403, "Forbidden");
  } else if (context.userId !== existing.ownerUserId) {
    throw new HttpError(403, "Only the Space owner can update Space settings");
  }

  if (
    body.settings &&
    typeof body.settings === "object" &&
    Object.prototype.hasOwnProperty.call(body.settings, "threadOrder")
  ) {
    if (
      existing.kind !== "direct" &&
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
    const duplicate = await dataOf(env).read.row<{ id: string }>`SELECT id FROM spaces
       WHERE owner_user_id = ${existing.ownerUserId} AND id <> ${spaceId}
         AND LOWER(TRIM(name)) = LOWER(TRIM(${space.name}))
       LIMIT 1`;
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
  await publishCollaborationEvent(
    env,
    settings.archived === true &&
      spaceSettings(existing.settingsJson).archived !== true
      ? "space.archived"
      : "space.updated",
    spaceId,
    spaceId,
    {
      tx: async (tx) => {
        await tx.run`
          UPDATE spaces SET name = ${space.name}, description = ${space.description},
             settings_json = syntila_json_patch(settings_json, ${JSON.stringify(settingsPatch)}), updated_at = ${now}
           WHERE id = ${spaceId}
        `;
      },
    },
  );
  let dynamicName = space.name;
  let avatarUrl: string | null = null;
  let personalName: string | null = null;
  let originalName: string | null = null;
  if (existing.kind === "direct") {
    const peer = await findDirectSpacePeer(env, context.userId, spaceId);
    if (peer) {
      personalName = peer.personalName;
      originalName = peer.displayName;
      dynamicName = peer.personalName ?? peer.displayName;
      avatarUrl = avatarUrlFor(request, peer.id, peer.avatarUrl);
    }
  }

  return json({
    space: {
      ...space,
      name: dynamicName,
      ...(avatarUrl !== null ? { avatarUrl } : {}),
      kind: existing.kind ?? "group",
      settings:
        existing.kind === "direct"
          ? {
              ...publicSpaceSettings(JSON.stringify(space.settings)),
              personalName,
              originalName,
            }
          : publicSpaceSettings(JSON.stringify(space.settings)),
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
    const space = await spaceKind(env, spaceId);
    if (space?.kind === "direct") {
      // Either participant may delete a personal Space; the connection stays
      // and messaging again creates a fresh one.
      const member = await isSpaceMember(env, spaceId, context.userId);
      if (!member) throw new HttpError(403, "Forbidden");
    } else {
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
    }
    const audience = await dataOf(env).read.rows<{ user_id: string }>`SELECT user_id FROM space_memberships WHERE space_id = ${spaceId}`;
    // Every row that belongs to the Space (Threads with their Work history,
    // members, invitations, grants, audit, artifacts) is removed by cascade,
    // committed together with the deletion event.
    await publishCollaborationEvent(env, "space.deleted", spaceId, spaceId, {
      recipientUserIds: audience.map((row) => row.user_id),
      tx: async (tx) => {
        await tx.run`DELETE FROM spaces WHERE id = ${spaceId}`;
      },
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
  const rows = await dataOf(env).read.rows`SELECT pm.user_id AS "userId", u.display_name AS "displayName", u.email, pm.role, pm.created_at AS "createdAt"
     FROM space_memberships pm JOIN users u ON u.id = pm.user_id
     WHERE pm.space_id = ${spaceId} ORDER BY CASE pm.role WHEN 'owner' THEN 0 WHEN 'collaborator' THEN 1 ELSE 2 END, u.display_name`;
  const space = await dataOf(env).read.row<{ settingsJson: string }>`SELECT settings_json AS "settingsJson" FROM spaces WHERE id = ${spaceId}`;
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
  const rows = await dataOf(env).read.rows`SELECT id, email, invitee_user_id AS "inviteeUserId", role, status, expires_at AS "expiresAt", created_at AS "createdAt"
     FROM space_invitations WHERE space_id = ${spaceId} AND status = 'pending' ORDER BY created_at DESC`;
  const snapshots = parseSpaceSettings(
    parseSpaceSettings(policy.settingsJson).invitationPermissions,
  );
  return json({
    invitations: (rows.results ?? []).map((row) => ({
      ...row,
      permissions: normalizeSpaceMemberSnapshot(
        String(row.role),
        snapshots[String(row.id)],
      ),
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
  const { limit, after } = pageRequest(new URL(request.url), { defaultLimit: 100, maxLimit: 200 });
  const read = dataOf(env).read;
  const rows = await read.rows<Record<string, unknown>>`
    SELECT id, action, target_type AS "targetType", target_id AS "targetId", created_at AS "createdAt"
      FROM space_audit_log
     WHERE space_id = ${spaceId}
       ${after ? read.frag`AND (created_at, id) < (${after.at}, ${after.id})` : read.raw("")}
     ORDER BY ${read.raw(cursorOrderSql("created_at", "id"))} LIMIT ${limit + 1}`;
  const page = pageOf(rows, limit, (row) => ({ at: String(row.createdAt), id: String(row.id) }));
  return json({ entries: page.items, nextCursor: page.nextCursor });
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
  const space = await spaceKind(env, spaceId);
  if (space?.kind === "direct") {
    throw new HttpError(403, "Direct Spaces cannot have additional members");
  }
  const policy = await requireSpaceOwner(env, context, spaceId);
  const body = await readBody(request, SpaceInvitationSchema);
  // A retried send with the same Idempotency-Key returns the first result
  // instead of "already pending".
  const receipt = await MutationIdempotency.from(
    request,
    dataOf(env).read,
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
    const person = await dataOf(env).read.row<{ email: string }>`SELECT u.email FROM people_relationships p JOIN users u ON u.id=${userId} AND u.status='active'
      WHERE p.user_low_id=LEAST(${context.userId}::text,${userId}::text) AND p.user_high_id=GREATEST(${context.userId}::text,${userId}::text)`;
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
  const permissions = storedSpaceMemberRights({
    chat: requestedPermissions.chat && policy.rights.chat,
    work: requestedPermissions.work && policy.rights.work,
    manageOwnThreads:
      requestedPermissions.manageOwnThreads && policy.rights.manageOwnThreads,
  });
  if (
    body.permissions !== undefined &&
    GRANTED_SPACE_RIGHT_KEYS.some(
      (key) => requestedPermissions[key] && !policy.rights[key],
    )
  )
    throw new HttpError(
      403,
      "You cannot invite a member with rights you do not hold",
    );
  const existingMember = await dataOf(env).read.row<{ user_id: string }>`SELECT pm.user_id FROM space_memberships pm
     JOIN users u ON u.id = pm.user_id
     WHERE pm.space_id = ${spaceId} AND (pm.user_id = ${inviteeUserId} OR LOWER(u.email) = LOWER(${email}))
     LIMIT 1`;
  if (existingMember) {
    throw new HttpError(409, "This user is already a Space member");
  }
  await dataOf(env).read.run`UPDATE space_invitations SET status='expired',updated_at=${new Date().toISOString()} WHERE space_id=${spaceId} AND (LOWER(email)=${email} OR invitee_user_id=${inviteeUserId}) AND status='pending' AND expires_at<=${new Date().toISOString()}`;
  const existingInvitation = await dataOf(env).read.row<{ id: string }>`SELECT id FROM space_invitations
     WHERE space_id = ${spaceId} AND status = 'pending' AND (LOWER(email) = LOWER(${email}) OR invitee_user_id = ${inviteeUserId})
     LIMIT 1`;
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
    await dataOf(env).tx("space.invitation.create", async (tx) => {
      await tx.lock("syntila.space_members", spaceId);
      if (await spaceMemberCapacityRefused(env as unknown as Env, spaceId)) {
        throw new SpaceMemberLimitError("owner");
      }
      if (receipt) await receipt.record(tx, { invitation }, 201);
      await tx.run`INSERT INTO space_invitations (id, space_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at, invitee_user_id)
        VALUES (${id}, ${spaceId}, ${email}, ${role}, ${tokenHash}, ${context.userId}, 'pending', ${new Date(now.getTime() + 7 * 86400000).toISOString()}, ${now.toISOString()}, ${now.toISOString()}, ${inviteeUserId})`;
      await setSpaceSetting(tx, spaceId, permissionJsonPath("invitationPermissions", id), JSON.stringify(permissions), now.toISOString());
    });
  } catch (error) {
    if (
      error instanceof Error &&
      /NOT NULL constraint failed: space_invitations\.token_hash/i.test(
        error.message,
      )
    )
      throw new SpaceMemberLimitError("owner");
    // PostgreSQL names the violated index (the pending e-mail and pending
    // user indexes); the router would answer the same text from
    // CONSTRAINT_MESSAGES, this keeps the handler's own contract.
    if (
      error instanceof Error &&
      /^idx_space_invitations_pending_(email|user)$/.test(
        String((error as { constraint?: string }).constraint ?? ""),
      )
    )
      throw new HttpError(
        409,
        "A pending invitation already exists for this user",
      );
    throw error;
  }
  await dataOf(env).read.run`INSERT INTO space_audit_log (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
     VALUES (${`pa-${crypto.randomUUID()}`}, ${spaceId}, 'user', ${context.userId}, 'space.invitation.created', 'invitation', ${id}, ${JSON.stringify({ email, role })}, ${now.toISOString()})`;
  const recipient = inviteeUserId
    ? { id: inviteeUserId }
    : await userByEmail(env, email);
  await publishCollaborationEvent(env, "space.updated", spaceId, id, {
    additionalRecipientUserIds: inviteeUserId
      ? [inviteeUserId]
      : recipient
        ? [recipient.id]
        : [],
  });

  const spaceRow = await spaceNameOf(env, spaceId);
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
  const space = await spaceKind(env, spaceId);
  if (space?.kind === "direct") {
    throw new HttpError(
      403,
      "Direct Space members cannot be modified or removed",
    );
  }
  const body = await readBody(request, SpaceMemberRoleSchema);
  const permissions =
    body.permissions === undefined
      ? null
      : validateMemberPermissions(body.permissions);
  const role = permissions
    ? GRANTED_SPACE_RIGHT_KEYS.some((key) => permissions[key])
      ? "collaborator"
      : "viewer"
    : body.role === "viewer" || body.role === "collaborator"
      ? body.role
      : null;
  if (!role)
    throw new HttpError(400, "Space role or member permissions are required");
  const member = await spaceMembership(env, spaceId, userId);
  if (!member) throw new HttpError(404, "Space member not found");
  if (member.role === "owner")
    throw new HttpError(403, "Owner permissions cannot be changed");
  await dataOf(env).tx("space.member.role", async (tx) => {
    const now = new Date().toISOString();
    await tx.run`UPDATE space_memberships SET role = ${role}, updated_at = ${now} WHERE space_id = ${spaceId} AND user_id = ${userId} AND role <> 'owner'`;
    await setSpaceSetting(tx, spaceId, permissionJsonPath("memberPermissions", userId), JSON.stringify(storedSpaceMemberRights(permissions ?? defaultSpaceMemberPermissions(role))), now);
  });
  await recordSpaceAudit(dataOf(env).read, spaceId, context.userId, "space.member.role_changed", "user", userId, JSON.stringify({ role, permissions }));
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
  const space = await spaceKind(env, spaceId);
  if (space?.kind === "direct") {
    throw new HttpError(
      403,
      "Direct Space members cannot be modified or removed",
    );
  }
  const result = await dataOf(env).read.run`DELETE FROM space_memberships WHERE space_id = ${spaceId} AND user_id = ${userId} AND role <> 'owner'`;
  if (result.count === 0)
    throw new HttpError(404, "Space member not found");
  await removeSpaceSetting(dataOf(env).read, spaceId, permissionJsonPath("memberPermissions", userId));
  // A contributed execution Workspace is owned by the departing user. Revoke
  // that user's Space Grants with the membership removal so the scheduler
  // cannot continue using infrastructure after collaboration ends.
  await dataOf(env).read.run`UPDATE workspace_space_grants
        SET status = 'revoked', updated_at = ${new Date().toISOString()}
      WHERE space_id = ${spaceId} AND granted_by_user_id = ${userId}
        AND status IN ('active', 'suspended')`;
  await recordSpaceAudit(dataOf(env).read, spaceId, context.userId, "space.member.removed", "user", userId);
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
  const existing = await dataOf(env).read.row<{
      id: string;
      email: string;
      inviteeUserId: string | null;
    }>`SELECT id, email, invitee_user_id AS "inviteeUserId" FROM space_invitations WHERE id = ${invitationId} AND space_id = ${spaceId} AND status = 'pending'`;
  if (!existing) throw new HttpError(404, "Pending invitation not found");

  const result = await dataOf(env).read.run`UPDATE space_invitations SET status = 'expired', updated_at = ${new Date().toISOString()} WHERE id = ${invitationId} AND space_id = ${spaceId} AND status = 'pending'`;
  if (result.count === 0)
    throw new HttpError(404, "Pending invitation not found");
  await removeSpaceSetting(dataOf(env).read, spaceId, permissionJsonPath("invitationPermissions", invitationId));
  await recordSpaceAudit(dataOf(env).read, spaceId, context.userId, "space.invitation.expired", "invitation", invitationId);
  const recipient = existing.inviteeUserId
    ? { id: existing.inviteeUserId }
    : await userByEmail(env, existing.email);
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
  const rows = await dataOf(env).read.rows`SELECT 
       pi.id,
       pi.space_id AS "spaceId",
       p.name AS "spaceName",
       pi.email,
       pi.invitee_user_id AS "inviteeUserId",
       pi.role,
       pi.status,
       pi.invited_by_user_id AS "invitedByUserId",
       u.display_name AS "invitedByUserName",
       u.email AS "invitedByUserEmail",
       pi.expires_at AS "expiresAt",
       pi.created_at AS "createdAt"
     FROM space_invitations pi
     JOIN spaces p ON p.id = pi.space_id
     JOIN users u ON u.id = pi.invited_by_user_id
     WHERE (pi.invitee_user_id = ${context.userId} OR (pi.invitee_user_id IS NULL AND LOWER(pi.email) = ${email})) AND pi.status = 'pending' AND pi.expires_at > ${now}
     ORDER BY pi.created_at DESC`;
  return json({ invitations: rows });
}

export async function handleAcceptSpaceInvitation(
  request: Request,
  env: SecurityEnv,
  invitationId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const invitation = await dataOf(env).read.row<{
      invitedByUserId: string;
      acceptedByUserId: string | null;
      id: string;
      spaceId: string;
      email: string;
      inviteeUserId: string | null;
      role: "collaborator" | "viewer";
      status: string;
      expiresAt: string;
    }>`SELECT id, space_id AS "spaceId", email, invitee_user_id AS "inviteeUserId", role, status, invited_by_user_id AS "invitedByUserId", accepted_by_user_id AS "acceptedByUserId", expires_at AS "expiresAt"
     FROM space_invitations WHERE id = ${invitationId}`;
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
  const snapshot = normalizeSpaceMemberSnapshot(
    invitation.role,
    parseSpaceSettings(settings.invitationPermissions)[invitation.id],
  );
  const permissions = storedSpaceMemberRights({
    chat: snapshot.chat && inviter.rights.chat,
    work: snapshot.work && inviter.rights.work,
    manageOwnThreads:
      snapshot.manageOwnThreads && inviter.rights.manageOwnThreads,
  });
  const existingMember = await dataOf(env).read.row`SELECT user_id FROM space_memberships WHERE space_id = ${invitation.spaceId} AND user_id = ${context.userId}`;
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
    acceptance = await dataOf(env).tx("space.invitation.accept", async (tx) => {
      await tx.lock("syntila.space_members", invitation.spaceId);
      if (await spaceMemberCapacityRefused(env as unknown as Env, invitation.spaceId, invitation.id)) {
        throw new SpaceMemberLimitError("member");
      }
      const invUpdate = await tx.run`UPDATE space_invitations SET status = 'accepted', invitee_user_id = COALESCE(invitee_user_id, ${context.userId}), accepted_by_user_id = ${context.userId}, accepted_at = ${now}, updated_at = ${now} WHERE id = ${invitation.id} AND status = 'pending' AND expires_at > ${now}`;
      if (invUpdate.count === 0) return { accepted: 0 };
      await tx.run`INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES (${membershipId}, ${invitation.spaceId}, ${context.userId}, ${invitation.role}, ${now}, ${now})`;
      await tx.run`UPDATE spaces SET settings_json = syntila_json_remove(syntila_json_set(settings_json, ${permissionJsonPath("memberPermissions", context.userId)}, ${JSON.stringify(permissions)}), ${permissionJsonPath("invitationPermissions", invitation.id)}), updated_at = ${now} WHERE id = ${invitation.spaceId}`;
      await recordSpaceAudit(tx, invitation.spaceId, context.userId, "space.invitation.accepted", "invitation", invitation.id, "{}", now);
      return { accepted: invUpdate.count };
    });
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
  if (acceptance.accepted === 0)
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
  const invitation = await dataOf(env).read.row<{
      invitedByUserId: string;
      id: string;
      spaceId: string;
      email: string;
      inviteeUserId: string | null;
      role: "collaborator" | "viewer";
      status: string;
      expiresAt: string;
    }>`SELECT id, space_id AS "spaceId", email, invitee_user_id AS "inviteeUserId", role, status, invited_by_user_id AS "invitedByUserId", expires_at AS "expiresAt"
     FROM space_invitations WHERE id = ${invitationId}`;
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
  await dataOf(env).tx("space.invitation.decline", async (tx) => {
    await removeSpaceSetting(tx, invitation.spaceId, permissionJsonPath("invitationPermissions", invitation.id));
    await tx.run`UPDATE space_invitations SET status = 'declined', updated_at = ${now} WHERE id = ${invitation.id} AND status = 'pending'`;
    await recordSpaceAudit(tx, invitation.spaceId, context.userId, "space.invitation.declined", "invitation", invitation.id, "{}", now);
  });
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
