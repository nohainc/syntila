import {
  spaceMemberPermissions,
  type SpaceMemberPermissions,
} from "@syntila/security";
import { normalizeUserPair } from "@syntila/core";
import {
  securityContext,
  HttpError,
  json,
  type SecurityEnv,
} from "./http-security.js";
import { avatarUrlFor } from "./profile.js";
import {
  resolveAppUrl,
  sendPersonInvitationEmail,
} from "../invitation-email.js";
import { publishCollaborationEvent } from "../collaboration-events.js";
import { createEventPublisher } from "../event-publisher.js";
import { ensureSupportSpace, SupportSpaceError } from "../people.js";

export interface PeopleSpace {
  readonly id: string;
  readonly name: string;
}
export interface InvitablePeopleSpace extends PeopleSpace {
  readonly permissions: SpaceMemberPermissions;
  readonly canInvite: boolean;
}
export interface Person {
  readonly userId: string;
  readonly displayName: string;
  readonly email: string;
  readonly avatarUrl: string | null;
  readonly establishedAt: string;
  readonly sharedSpaceCount: number;
  readonly sharedSpaces: readonly PeopleSpace[];
  readonly pendingInvitationSpaceIds: readonly string[];
  readonly invitableSpaces: readonly InvitablePeopleSpace[];
  readonly connectionStatus:
    | "connected"
    | "disconnected"
    | "blocked"
    | "invitation_sent"
    | "invitation_received"
    | "collaborator";
  readonly directSpaceId: string | null;
  readonly generalThreadId: string | null;
  readonly invitationId: string | null;
}
export async function handleListPeople(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method !== "GET")
    throw new HttpError(405, "People is maintained automatically");
  if ([...new URL(request.url).searchParams.keys()].length)
    throw new HttpError(
      400,
      "People does not support global search or ownership parameters",
    );
  const now = new Date().toISOString();
  const callerEmail = context.user.email.toLowerCase();
  const supportEmail = env.SYNTILA_SUPPORT_ACCOUNT_EMAIL?.trim().toLowerCase();

  const [rows, emailPendingRows, personInvs, spaces, shared, pending] =
    await Promise.all([
      env.SYNTILA_DB.prepare(
        `WITH peer_users AS (
          SELECT user_high_id AS user_id, established_at FROM people_relationships WHERE user_low_id = ?1
          UNION ALL
          SELECT user_low_id AS user_id, established_at FROM people_relationships WHERE user_high_id = ?1
          UNION ALL
          SELECT CASE WHEN user_low_id = ?1 THEN user_high_id ELSE user_low_id END AS user_id, established_at
          FROM person_connections WHERE user_low_id = ?1 OR user_high_id = ?1
          UNION ALL
          SELECT invitee_user_id AS user_id, created_at AS established_at
          FROM person_invitations WHERE inviter_user_id = ?1 AND status = 'pending' AND expires_at > ?2 AND invitee_user_id IS NOT NULL
          UNION ALL
          SELECT inviter_user_id AS user_id, created_at AS established_at
          FROM person_invitations WHERE (invitee_user_id = ?1 OR (invitee_user_id IS NULL AND LOWER(email) = ?3)) AND status = 'pending' AND expires_at > ?2
        ),
        unique_peers AS (
          SELECT user_id, MIN(established_at) AS established_at FROM peer_users WHERE user_id <> ?1 GROUP BY user_id
        )
        SELECT u.id AS userId, u.display_name AS displayName, u.email, u.avatar_url AS avatarUrl, p.established_at AS establishedAt,
          (SELECT COUNT(*) FROM space_memberships mine
           JOIN space_memberships theirs ON theirs.space_id=mine.space_id
           JOIN spaces s ON s.id = mine.space_id
           WHERE mine.user_id=?1 AND theirs.user_id=u.id AND COALESCE(s.kind, 'group') = 'group') AS sharedSpaceCount,
          pc.status AS rawConnectionStatus,
          ds.space_id AS directSpaceId,
          ds.general_thread_id AS generalThreadId,
          EXISTS (
            SELECT 1 FROM user_blocks ub
            WHERE ub.blocker_user_id = ?1 AND ub.blocked_user_id = u.id
          ) AS isBlocked
        FROM unique_peers p
        JOIN users u ON u.id = p.user_id
        LEFT JOIN person_connections pc ON pc.user_low_id = MIN(?1, u.id) AND pc.user_high_id = MAX(?1, u.id)
        LEFT JOIN direct_spaces ds ON ds.space_id = pc.direct_space_id
        WHERE u.status = 'active'
        ORDER BY LOWER(u.display_name), u.id`,
      )
        .bind(context.userId, now, callerEmail)
        .all<{
          userId: string;
          displayName: string;
          email: string;
          avatarUrl: string | null;
          establishedAt: string;
          sharedSpaceCount: number;
          rawConnectionStatus: string | null;
          directSpaceId: string | null;
          generalThreadId: string | null;
          isBlocked: number;
        }>(),
      env.SYNTILA_DB.prepare(
        `SELECT id, email, created_at AS createdAt
         FROM person_invitations
         WHERE inviter_user_id = ?1 AND status = 'pending' AND expires_at > ?2 AND invitee_user_id IS NULL
         ORDER BY created_at DESC`,
      )
        .bind(context.userId, now)
        .all<{ id: string; email: string; createdAt: string }>(),
      env.SYNTILA_DB.prepare(
        `SELECT id, inviter_user_id AS inviterUserId, invitee_user_id AS inviteeUserId, LOWER(email) AS email, status
         FROM person_invitations
         WHERE status = 'pending' AND expires_at > ?1
           AND (inviter_user_id = ?2 OR invitee_user_id = ?2 OR (invitee_user_id IS NULL AND LOWER(email) = ?3))`,
      )
        .bind(now, context.userId, callerEmail)
        .all<{
          id: string;
          inviterUserId: string;
          inviteeUserId: string | null;
          email: string | null;
          status: string;
        }>(),
      env.SYNTILA_DB.prepare(
        `SELECT s.id,s.name,COALESCE(s.kind, 'group') AS kind,COALESCE(json_extract(s.settings_json, '$.archived'), 0) AS archived,s.settings_json AS settingsJson,m.role
        FROM spaces s JOIN space_memberships m ON m.space_id=s.id WHERE m.user_id=?1 ORDER BY LOWER(s.name),s.id`,
      )
        .bind(context.userId)
        .all<
          PeopleSpace & {
            kind: string;
            archived: number;
            settingsJson: string;
            role: string;
          }
        >(),
      env.SYNTILA_DB.prepare(
        `SELECT theirs.user_id AS userId,mine.space_id AS spaceId
        FROM space_memberships mine JOIN space_memberships theirs ON theirs.space_id=mine.space_id
        JOIN people_relationships p ON p.user_low_id=MIN(?1,theirs.user_id) AND p.user_high_id=MAX(?1,theirs.user_id)
        WHERE mine.user_id=?1`,
      )
        .bind(context.userId)
        .all<{ userId: string; spaceId: string }>(),
      env.SYNTILA_DB.prepare(
        `SELECT i.space_id AS spaceId,LOWER(i.email) AS email,i.invitee_user_id AS inviteeUserId FROM space_invitations i
        JOIN space_memberships m ON m.space_id=i.space_id AND m.user_id=?1
        WHERE i.status='pending' AND i.expires_at>?2`,
      )
        .bind(context.userId, now)
        .all<{ spaceId: string; email: string; inviteeUserId: string | null }>(),
    ]);

  const permissions = new Map(
    spaces.results.map((space) => [
      space.id,
      spaceMemberPermissions(space.role, space.settingsJson, context.userId),
    ]),
  );
  const sharedByUser = new Map<string, Set<string>>();
  for (const row of shared.results) {
    const ids = sharedByUser.get(row.userId) ?? new Set<string>();
    ids.add(row.spaceId);
    sharedByUser.set(row.userId, ids);
  }
  const pendingByUser = new Map<string, Set<string>>();
  const pendingByEmail = new Map<string, Set<string>>();
  for (const row of pending.results) {
    if (row.inviteeUserId !== null) {
      const ids = pendingByUser.get(row.inviteeUserId) ?? new Set<string>();
      ids.add(row.spaceId);
      pendingByUser.set(row.inviteeUserId, ids);
      continue;
    }
    const ids = pendingByEmail.get(row.email) ?? new Set<string>();
    ids.add(row.spaceId);
    pendingByEmail.set(row.email, ids);
  }

  const peopleList: Person[] = rows.results.filter(
    (person) => person.email.trim().toLowerCase() !== supportEmail,
  ).map((person) => {
    const membership = sharedByUser.get(person.userId) ?? new Set<string>();
    const invitations = new Set([
      ...(pendingByUser.get(person.userId) ?? []),
      ...(pendingByEmail.get(person.email.trim().toLowerCase()) ?? []),
    ]);

    // Check personal invitations with this user
    let connectionStatus: Person["connectionStatus"] = "collaborator";
    let invitationId: string | null = null;

    const matchingInv = personInvs.results.find(
      (inv) =>
        (inv.inviterUserId === person.userId &&
          (inv.inviteeUserId === context.userId ||
            inv.email === callerEmail)) ||
        (inv.inviterUserId === context.userId &&
          (inv.inviteeUserId === person.userId ||
            inv.email === person.email.trim().toLowerCase())),
    );

    if (person.isBlocked === 1) {
      connectionStatus = "blocked";
    } else if (matchingInv) {
      if (matchingInv.inviterUserId === context.userId) {
        connectionStatus = "invitation_sent";
      } else {
        connectionStatus = "invitation_received";
      }
      invitationId = matchingInv.id;
    } else if (person.rawConnectionStatus === "connected") {
      connectionStatus = "connected";
    } else if (person.rawConnectionStatus === "disconnected") {
      connectionStatus = "disconnected";
    } else {
      connectionStatus = "collaborator";
    }

    return {
      userId: person.userId,
      displayName: person.displayName,
      email: person.email,
      avatarUrl: avatarUrlFor(request, person.userId, person.avatarUrl),
      establishedAt: person.establishedAt,
      sharedSpaceCount: person.sharedSpaceCount,
      connectionStatus,
      directSpaceId: person.directSpaceId,
      generalThreadId: person.generalThreadId,
      invitationId,
      pendingInvitationSpaceIds: [...invitations].filter((id) =>
        spaces.results.some(
          (space) => space.id === id && space.role === "owner",
        ),
      ),
      sharedSpaces: spaces.results
        .filter((space) => space.kind === "group" && membership.has(space.id))
        .map(({ id, name }): PeopleSpace => ({ id, name })),
      invitableSpaces: spaces.results
        .filter(
          (space) =>
            space.kind === "group" &&
            space.role === "owner" &&
            space.archived === 0 &&
            !membership.has(space.id) &&
            !invitations.has(space.id),
        )
        .map(({ id, name, role }): InvitablePeopleSpace => ({
          id,
          name,
          permissions: permissions.get(id)!,
          canInvite: role === "owner",
        })),
    };
  });

  // Append pending email invitations sent by caller to unknown accounts
  const knownEmails = new Set(rows.results.map((r) => r.email.toLowerCase()));
  for (const emailInv of emailPendingRows.results) {
    if (emailInv.email.trim().toLowerCase() === supportEmail) continue;
    if (!knownEmails.has(emailInv.email.toLowerCase())) {
      peopleList.push({
        userId: `email:${emailInv.email}`,
        displayName: emailInv.email,
        email: emailInv.email,
        avatarUrl: null,
        establishedAt: emailInv.createdAt,
        sharedSpaceCount: 0,
        sharedSpaces: [],
        pendingInvitationSpaceIds: [],
        invitableSpaces: [],
        connectionStatus: "invitation_sent",
        directSpaceId: null,
        generalThreadId: null,
        invitationId: emailInv.id,
      });
    }
  }

  return json({
    schemaVersion: 1,
    people: peopleList,
  });
}

const PERSONAL_INVITATION_RATE_LIMIT_PER_HOUR = 20;

async function provisionDirectConnection(
  env: SecurityEnv,
  inviterUserId: string,
  recipientUserId: string,
  invitationId: string | null,
): Promise<{ directSpaceId: string; userLowId: string; userHighId: string }> {
  const isBlocked = await env.SYNTILA_DB.prepare(
    `SELECT 1 FROM user_blocks
     WHERE (blocker_user_id = ?1 AND blocked_user_id = ?2)
        OR (blocker_user_id = ?2 AND blocked_user_id = ?1)`,
  )
    .bind(inviterUserId, recipientUserId)
    .first();
  if (isBlocked) {
    throw new HttpError(403, "Cannot accept invitation from a blocked user");
  }

  const { userLowId, userHighId } = normalizeUserPair(
    inviterUserId,
    recipientUserId,
  );
  const now = new Date().toISOString();

  const existing = await env.SYNTILA_DB.prepare(
    "SELECT space_id FROM direct_spaces WHERE user_low_id = ?1 AND user_high_id = ?2",
  )
    .bind(userLowId, userHighId)
    .first<{ space_id: string }>();

  let directSpaceId = existing?.space_id;
  const isNewSpace = !directSpaceId;
  const statements: D1PreparedStatement[] = [];

  if (!directSpaceId) {
    directSpaceId = `space-direct-${crypto.randomUUID()}`;
    statements.push(
      env.SYNTILA_DB.prepare(
        "INSERT INTO spaces (id, owner_user_id, name, kind, settings_json, created_at, updated_at) VALUES (?1, ?2, 'Direct Space', 'direct', '{}', ?3, ?3)",
      ).bind(directSpaceId, inviterUserId, now),
      env.SYNTILA_DB.prepare(
        "INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES (?1, ?2, ?3, 'owner', ?4, ?4) ON CONFLICT(space_id, user_id) DO NOTHING",
      ).bind(`pm-${crypto.randomUUID()}`, directSpaceId, inviterUserId, now),
      env.SYNTILA_DB.prepare(
        "INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES (?1, ?2, ?3, 'collaborator', ?4, ?4) ON CONFLICT(space_id, user_id) DO NOTHING",
      ).bind(`pm-${crypto.randomUUID()}`, directSpaceId, recipientUserId, now),
      env.SYNTILA_DB.prepare(
        "INSERT INTO direct_spaces (space_id, user_low_id, user_high_id, general_thread_id, created_at) VALUES (?1, ?2, ?3, NULL, ?4)",
      ).bind(directSpaceId, userLowId, userHighId, now),
      env.SYNTILA_DB.prepare(
        "INSERT INTO direct_space_user_state (space_id, user_id, hidden, created_at, updated_at) VALUES (?1, ?2, 0, ?3, ?3) ON CONFLICT(space_id, user_id) DO NOTHING",
      ).bind(directSpaceId, inviterUserId, now),
      env.SYNTILA_DB.prepare(
        "INSERT INTO direct_space_user_state (space_id, user_id, hidden, created_at, updated_at) VALUES (?1, ?2, 0, ?3, ?3) ON CONFLICT(space_id, user_id) DO NOTHING",
      ).bind(directSpaceId, recipientUserId, now),
    );
  }

  if (invitationId) statements.push(
    env.SYNTILA_DB.prepare(
      `INSERT INTO person_connections (user_low_id, user_high_id, status, established_at, direct_space_id)
       VALUES (?1, ?2, 'connected', ?3, ?4)
       ON CONFLICT(user_low_id, user_high_id) DO UPDATE SET
         status = 'connected', established_at = ?3, disconnected_at = NULL, direct_space_id = ?4`,
    ).bind(userLowId, userHighId, now, directSpaceId),
    env.SYNTILA_DB.prepare(
      `INSERT INTO people_relationships (user_low_id, user_high_id, established_at)
       VALUES (?1, ?2, ?3) ON CONFLICT(user_low_id, user_high_id) DO NOTHING`,
    ).bind(userLowId, userHighId, now),
    env.SYNTILA_DB.prepare(
      `UPDATE person_invitations SET status = 'accepted', accepted_by_user_id = ?1, updated_at = ?2 WHERE id = ?3`,
    ).bind(recipientUserId, now, invitationId),
    env.SYNTILA_DB.prepare(
      `UPDATE person_invitations SET status = 'accepted', accepted_by_user_id = ?1, updated_at = ?2
       WHERE id <> ?3 AND status = 'pending'
         AND ((inviter_user_id = ?4 AND invitee_user_id = ?5) OR (inviter_user_id = ?5 AND invitee_user_id = ?4))`,
    ).bind(recipientUserId, now, invitationId, userLowId, userHighId),
  );

  if (!invitationId) statements.push(env.SYNTILA_DB.prepare(
    "UPDATE person_connections SET direct_space_id = ?1 WHERE user_low_id = ?2 AND user_high_id = ?3 AND status = 'connected'",
  ).bind(directSpaceId, userLowId, userHighId));

  try {
    if (isNewSpace) {
      await publishCollaborationEvent(
        env,
        "space.created",
        directSpaceId,
        directSpaceId,
        {
          recipientUserIds: [userLowId, userHighId],
          additionalRecipientUserIds: [userLowId, userHighId],
          mutations: statements,
        },
      );
    } else {
      await env.SYNTILA_DB.batch(statements);
    }
  } catch (error) {
    const rechecked = await env.SYNTILA_DB.prepare(
      "SELECT space_id FROM direct_spaces WHERE user_low_id = ?1 AND user_high_id = ?2",
    )
      .bind(userLowId, userHighId)
      .first<{ space_id: string }>();
    if (rechecked) {
      directSpaceId = rechecked.space_id;
      if (invitationId) await env.SYNTILA_DB.prepare(
        "UPDATE person_invitations SET status = 'accepted', accepted_by_user_id = ?1, updated_at = ?2 WHERE id = ?3",
      )
        .bind(recipientUserId, now, invitationId)
        .run();
      else await env.SYNTILA_DB.prepare(
        "UPDATE person_connections SET direct_space_id = ?1 WHERE user_low_id = ?2 AND user_high_id = ?3 AND status = 'connected'",
      ).bind(directSpaceId, userLowId, userHighId).run();
    } else {
      throw error;
    }
  }

  const publisher = createEventPublisher(env);
  await publisher.publish({
    type: "people.updated",
    stream: { kind: "user", id: inviterUserId },
    payload: { entityId: recipientUserId },
  });
  await publisher.publish({
    type: "people.updated",
    stream: { kind: "user", id: recipientUserId },
    payload: { entityId: inviterUserId },
  });
  return { directSpaceId, userLowId, userHighId };
}

export async function handleOpenPersonalSpace(
  request: Request, env: SecurityEnv, peerId: string, ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method !== "POST") throw new HttpError(405, "Method not allowed");
  if (peerId === context.userId) throw new HttpError(400, "Invalid person");
  const { userLowId, userHighId } = normalizeUserPair(context.userId, peerId);
  const connection = await env.SYNTILA_DB.prepare(
    `SELECT 1 FROM person_connections pc JOIN users u ON u.id = ?3 AND u.status = 'active'
     WHERE pc.user_low_id = ?1 AND pc.user_high_id = ?2 AND pc.status = 'connected'`,
  ).bind(userLowId, userHighId, peerId).first();
  if (!connection) throw new HttpError(403, "Person is not connected");
  const result = await provisionDirectConnection(env, context.userId, peerId, null);
  return json({ spaceId: result.directSpaceId });
}

export async function handleCreatePersonInvitation(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (context.user.status !== "active") {
    throw new HttpError(403, "Account is not active");
  }

  // Rate limiting check
  const recent = await env.SYNTILA_DB.prepare(
    `SELECT COUNT(*) AS count FROM person_invitations
     WHERE inviter_user_id = ?1 AND created_at >= ?2`,
  )
    .bind(
      context.userId,
      new Date(Date.now() - 60 * 60 * 1000).toISOString(),
    )
    .first<{ count: number }>();
  if (Number(recent?.count ?? 0) >= PERSONAL_INVITATION_RATE_LIMIT_PER_HOUR) {
    throw new HttpError(429, "Too many invitations sent. Please try again later.");
  }

  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const rawEmail = typeof body.email === "string" ? body.email.trim() : null;
  const rawUserId =
    typeof body.userId === "string" ? body.userId.trim() : null;

  if ((!rawEmail && !rawUserId) || (rawEmail && rawUserId)) {
    throw new HttpError(
      400,
      "Exactly one of 'email' or 'userId' must be provided",
    );
  }

  const now = new Date().toISOString();
  let inviteeUserId: string | null = null;
  let targetEmail: string;

  if (rawUserId) {
    if (rawUserId === context.userId) {
      throw new HttpError(400, "Cannot invite yourself");
    }
    const isPeer = await env.SYNTILA_DB.prepare(
      `SELECT 1 FROM people_relationships
       WHERE user_low_id = MIN(?1, ?2) AND user_high_id = MAX(?1, ?2)`,
    )
      .bind(context.userId, rawUserId)
      .first();
    if (!isPeer) {
      throw new HttpError(404, "Recipient not found in your contacts");
    }
    const target = await env.SYNTILA_DB.prepare(
      "SELECT id, email, display_name, status FROM users WHERE id = ?1",
    )
      .bind(rawUserId)
      .first<{
        id: string;
        email: string;
        display_name: string;
        status: string;
      }>();
    if (!target || target.status !== "active") {
      throw new HttpError(404, "Recipient not found or inactive");
    }
    inviteeUserId = target.id;
    targetEmail = target.email;
  } else {
    const normalizedEmail = rawEmail!.toLowerCase();
    if (!normalizedEmail.includes("@") || !normalizedEmail.includes(".")) {
      throw new HttpError(400, "Invalid email address");
    }
    if (normalizedEmail === context.user.email.toLowerCase()) {
      throw new HttpError(400, "Cannot invite yourself");
    }
    const existing = await env.SYNTILA_DB.prepare(
      "SELECT id, email, display_name, status FROM users WHERE LOWER(email) = ?1",
    )
      .bind(normalizedEmail)
      .first<{
        id: string;
        email: string;
        display_name: string;
        status: string;
      }>();
    if (existing) {
      if (existing.id === context.userId) {
        throw new HttpError(400, "Cannot invite yourself");
      }
      if (existing.status !== "active") {
        throw new HttpError(400, "Cannot send invitation to this recipient");
      }
      inviteeUserId = existing.id;
      targetEmail = existing.email;
    } else {
      inviteeUserId = null;
      targetEmail = normalizedEmail;
    }
  }

  // Check if blocked
  if (inviteeUserId) {
    const isBlocked = await env.SYNTILA_DB.prepare(
      `SELECT 1 FROM user_blocks
       WHERE (blocker_user_id = ?1 AND blocked_user_id = ?2)
          OR (blocker_user_id = ?2 AND blocked_user_id = ?1)`,
    )
      .bind(context.userId, inviteeUserId)
      .first();
    if (isBlocked) {
      throw new HttpError(403, "Cannot send invitation to a blocked user");
    }
  }

  // Check if already connected
  if (inviteeUserId) {
    const { userLowId, userHighId } = normalizeUserPair(
      context.userId,
      inviteeUserId,
    );
    const existingConn = await env.SYNTILA_DB.prepare(
      `SELECT status, direct_space_id FROM person_connections
       WHERE user_low_id = ?1 AND user_high_id = ?2 AND status = 'connected'`,
    )
      .bind(userLowId, userHighId)
      .first<{ status: string; direct_space_id: string | null }>();
    if (existingConn) {
      // The personal Space was deleted: connecting again creates a new one.
      const directSpaceId =
        existingConn.direct_space_id ??
        (
          await provisionDirectConnection(
            env,
            context.userId,
            inviteeUserId,
            `restore-${crypto.randomUUID()}`,
          )
        ).directSpaceId;
      return json({
        status: "already_connected",
        directSpaceId,
      });
    }

    // Check for existing pending invitation between them
    const pendingInv = await env.SYNTILA_DB.prepare(
      `SELECT id, inviter_user_id, invitee_user_id, status, expires_at, created_at
       FROM person_invitations
       WHERE status = 'pending' AND expires_at > ?1
         AND ((inviter_user_id = ?2 AND invitee_user_id = ?3) OR (inviter_user_id = ?3 AND invitee_user_id = ?2))`,
    )
      .bind(now, context.userId, inviteeUserId)
      .first<{
        id: string;
        inviter_user_id: string;
        invitee_user_id: string;
        status: string;
        expires_at: string;
        created_at: string;
      }>();

    if (pendingInv) {
      if (pendingInv.inviter_user_id === context.userId) {
        // Caller retry
        return json({
          status: "pending",
          invitation: {
            id: pendingInv.id,
            inviterUserId: pendingInv.inviter_user_id,
            inviteeUserId: pendingInv.invitee_user_id,
            email: targetEmail,
            status: "pending",
            createdAt: pendingInv.created_at,
            expiresAt: pendingInv.expires_at,
          },
          emailDelivered: true,
        });
      } else {
        // Reciprocal simultaneous invitation: auto-accept and connect immediately
        const provisioned = await provisionDirectConnection(
          env,
          pendingInv.inviter_user_id,
          context.userId,
          pendingInv.id,
        );
        return json(
          {
            status: "connected",
            directSpaceId: provisioned.directSpaceId,
            invitation: {
              id: pendingInv.id,
              inviterUserId: pendingInv.inviter_user_id,
              inviteeUserId: context.userId,
              email: targetEmail,
              status: "accepted",
              createdAt: pendingInv.created_at,
              expiresAt: pendingInv.expires_at,
            },
            connection: {
              userLowId: provisioned.userLowId,
              userHighId: provisioned.userHighId,
              status: "connected",
            },
          },
        );
      }
    }
  } else {
    // Check pending email invitation
    const pendingEmail = await env.SYNTILA_DB.prepare(
      `SELECT id, inviter_user_id, email, status, expires_at, created_at
       FROM person_invitations
       WHERE inviter_user_id = ?1 AND LOWER(email) = ?2 AND status = 'pending' AND expires_at > ?3`,
    )
      .bind(context.userId, targetEmail.toLowerCase(), now)
      .first<{
        id: string;
        inviter_user_id: string;
        email: string;
        status: string;
        expires_at: string;
        created_at: string;
      }>();
    if (pendingEmail) {
      return json({
        status: "pending",
        invitation: {
          id: pendingEmail.id,
          inviterUserId: pendingEmail.inviter_user_id,
          inviteeUserId: null,
          email: pendingEmail.email,
          status: "pending",
          createdAt: pendingEmail.created_at,
          expiresAt: pendingEmail.expires_at,
        },
        emailDelivered: true,
      });
    }
  }

  const invitationId = `pinv-${crypto.randomUUID()}`;
  const expiresAt = new Date(
    Date.now() + 14 * 24 * 60 * 60 * 1000,
  ).toISOString();

  try {
    await env.SYNTILA_DB.prepare(
      `INSERT INTO person_invitations (id, inviter_user_id, invitee_user_id, email, status, created_at, expires_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, 'pending', ?5, ?6, ?5)`,
    )
      .bind(
        invitationId,
        context.userId,
        inviteeUserId,
        targetEmail,
        now,
        expiresAt,
      )
      .run();
  } catch (err: unknown) {
    if (inviteeUserId) {
      const racingInv = await env.SYNTILA_DB.prepare(
        `SELECT id, inviter_user_id, invitee_user_id, status, expires_at, created_at
         FROM person_invitations
         WHERE status = 'pending' AND expires_at > ?1
           AND ((inviter_user_id = ?2 AND invitee_user_id = ?3) OR (inviter_user_id = ?3 AND invitee_user_id = ?2))`,
      )
        .bind(now, context.userId, inviteeUserId)
        .first<{
          id: string;
          inviter_user_id: string;
          invitee_user_id: string;
          status: string;
          expires_at: string;
          created_at: string;
        }>();

      if (racingInv) {
        if (racingInv.inviter_user_id === context.userId) {
          return json(
            {
              status: "pending",
              invitation: {
                id: racingInv.id,
                inviterUserId: racingInv.inviter_user_id,
                inviteeUserId: racingInv.invitee_user_id,
                email: targetEmail,
                status: "pending",
                createdAt: racingInv.created_at,
                expiresAt: racingInv.expires_at,
              },
              emailDelivered: true,
            },
            { status: 201 },
          );
        } else {
          // Simultaneous mutual invitations indicate mutual consent: auto-accept!
          const provisioned = await provisionDirectConnection(
            env,
            racingInv.inviter_user_id,
            context.userId,
            racingInv.id,
          );
          return json(
            {
              status: "connected",
              directSpaceId: provisioned.directSpaceId,
              invitation: {
                id: racingInv.id,
                inviterUserId: racingInv.inviter_user_id,
                inviteeUserId: context.userId,
                email: targetEmail,
                status: "accepted",
                createdAt: racingInv.created_at,
                expiresAt: racingInv.expires_at,
              },
              connection: {
                userLowId: provisioned.userLowId,
                userHighId: provisioned.userHighId,
                status: "connected",
              },
            },
          );
        }
      }

      // Check if already connected (e.g. provisioned concurrently)
      const { userLowId, userHighId } = normalizeUserPair(
        context.userId,
        inviteeUserId,
      );
      const conn = await env.SYNTILA_DB.prepare(
        "SELECT direct_space_id FROM person_connections WHERE user_low_id = ?1 AND user_high_id = ?2 AND status = 'connected'",
      )
        .bind(userLowId, userHighId)
        .first<{ direct_space_id: string }>();
      if (conn) {
        return json(
          {
            status: "already_connected",
            directSpaceId: conn.direct_space_id,
            invitation: {
              id: invitationId,
              inviterUserId: context.userId,
              inviteeUserId,
              email: targetEmail,
              status: "accepted",
              createdAt: now,
              expiresAt,
            },
          },
          { status: 201 },
        );
      }
    }
    throw err;
  }

  const emailDelivered = await sendPersonInvitationEmail(env, {
    recipientEmail: targetEmail,
    inviterName: context.user.displayName || "A Syntila user",
    appUrl: `${resolveAppUrl(request, env)}/people`,
  }).catch(() => false);

  const publisher = createEventPublisher(env);
  await publisher.publish({
    type: "people.updated",
    stream: { kind: "user", id: context.userId },
    payload: { entityId: invitationId },
  });
  if (inviteeUserId) {
    await publisher.publish({
      type: "people.updated",
      stream: { kind: "user", id: inviteeUserId },
      payload: { entityId: invitationId },
    });
  }

  return json(
    {
      status: "pending",
      invitation: {
        id: invitationId,
        inviterUserId: context.userId,
        inviteeUserId,
        email: targetEmail,
        status: "pending",
        createdAt: now,
        expiresAt,
      },
      emailDelivered,
    },
    { status: 201 },
  );
}

export async function handleListPersonInvitations(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const now = new Date().toISOString();
  const callerEmail = context.user.email.toLowerCase();

  const [incoming, outgoing] = await Promise.all([
    env.SYNTILA_DB.prepare(
      `SELECT pi.id, pi.inviter_user_id AS inviterUserId, u.display_name AS inviterName,
              u.avatar_url AS inviterAvatarUrl, pi.created_at AS createdAt,
              pi.expires_at AS expiresAt, pi.status
       FROM person_invitations pi
       JOIN users u ON u.id = pi.inviter_user_id
       WHERE pi.status = 'pending' AND pi.expires_at > ?1
         AND ((pi.invitee_user_id = ?2) OR (pi.invitee_user_id IS NULL AND LOWER(pi.email) = ?3))
       ORDER BY pi.created_at DESC`,
    )
      .bind(now, context.userId, callerEmail)
      .all<{
        id: string;
        inviterUserId: string;
        inviterName: string;
        inviterAvatarUrl: string | null;
        createdAt: string;
        expiresAt: string;
        status: string;
      }>(),
    env.SYNTILA_DB.prepare(
      `SELECT pi.id, pi.invitee_user_id AS inviteeUserId, pi.email,
              COALESCE(u.display_name, pi.email) AS recipientName,
              u.avatar_url AS recipientAvatarUrl, pi.created_at AS createdAt,
              pi.expires_at AS expiresAt, pi.status
       FROM person_invitations pi
       LEFT JOIN users u ON u.id = pi.invitee_user_id
       WHERE pi.inviter_user_id = ?1 AND pi.status = 'pending' AND pi.expires_at > ?2
       ORDER BY pi.created_at DESC`,
    )
      .bind(context.userId, now)
      .all<{
        id: string;
        inviteeUserId: string | null;
        email: string | null;
        recipientName: string;
        recipientAvatarUrl: string | null;
        createdAt: string;
        expiresAt: string;
        status: string;
      }>(),
  ]);

  return json({
    schemaVersion: 1,
    incoming: (incoming.results ?? []).map((row) => ({
      ...row,
      inviterAvatarUrl: avatarUrlFor(
        request,
        row.inviterUserId,
        row.inviterAvatarUrl,
      ),
    })),
    outgoing: (outgoing.results ?? []).map((row) => ({
      ...row,
      recipientAvatarUrl: row.inviteeUserId
        ? avatarUrlFor(request, row.inviteeUserId, row.recipientAvatarUrl)
        : null,
    })),
  });
}

export async function handleAcceptPersonInvitation(
  request: Request,
  env: SecurityEnv,
  invitationId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (context.user.status !== "active") {
    throw new HttpError(403, "Account is not active");
  }

  const inv = await env.SYNTILA_DB.prepare(
    "SELECT * FROM person_invitations WHERE id = ?1",
  )
    .bind(invitationId)
    .first<{
      id: string;
      inviter_user_id: string;
      invitee_user_id: string | null;
      email: string | null;
      status: string;
      expires_at: string;
      accepted_by_user_id: string | null;
    }>();

  if (!inv) {
    throw new HttpError(404, "Invitation not found");
  }

  // Idempotent acceptance
  if (inv.status === "accepted") {
    if (
      inv.accepted_by_user_id === context.userId ||
      inv.invitee_user_id === context.userId ||
      inv.inviter_user_id === context.userId
    ) {
      const partnerUserId =
        inv.inviter_user_id === context.userId
          ? (inv.accepted_by_user_id ?? inv.invitee_user_id ?? context.userId)
          : inv.inviter_user_id;
      const { userLowId, userHighId } = normalizeUserPair(
        context.userId,
        partnerUserId,
      );
      const ds = await env.SYNTILA_DB.prepare(
        "SELECT direct_space_id FROM person_connections WHERE user_low_id = ?1 AND user_high_id = ?2",
      )
        .bind(userLowId, userHighId)
        .first<{ direct_space_id: string }>();
      return json({
        status: "accepted",
        directSpaceId: ds?.direct_space_id ?? null,
        connection: {
          userLowId,
          userHighId,
          status: "connected",
        },
      });
    }
    throw new HttpError(400, "Invitation was already accepted by another user");
  }

  if (inv.status === "declined" || inv.status === "cancelled") {
    throw new HttpError(400, "Invitation is no longer valid");
  }

  const now = new Date().toISOString();
  if (inv.status === "expired" || inv.expires_at <= now) {
    throw new HttpError(400, "Invitation has expired");
  }

  if (inv.inviter_user_id === context.userId) {
    throw new HttpError(400, "Cannot accept your own invitation");
  }

  // Recipient validation
  if (inv.invitee_user_id !== null) {
    if (inv.invitee_user_id !== context.userId) {
      throw new HttpError(
        403,
        "You are not the intended recipient of this invitation",
      );
    }
  } else if (inv.email) {
    if (inv.email.toLowerCase() !== context.user.email.toLowerCase()) {
      throw new HttpError(
        403,
        "This invitation was sent to a different email address",
      );
    }
  }

  // Check inviter is active
  const inviter = await env.SYNTILA_DB.prepare(
    "SELECT id, status FROM users WHERE id = ?1",
  )
    .bind(inv.inviter_user_id)
    .first<{ id: string; status: string }>();
  if (!inviter || inviter.status !== "active") {
    throw new HttpError(
      400,
      "The user who sent this invitation is no longer active",
    );
  }

  const provisioned = await provisionDirectConnection(
    env,
    inv.inviter_user_id,
    context.userId,
    inv.id,
  );

  return json({
    status: "accepted",
    directSpaceId: provisioned.directSpaceId,
    connection: {
      userLowId: provisioned.userLowId,
      userHighId: provisioned.userHighId,
      status: "connected",
    },
  });
}

export async function handleDeclinePersonInvitation(
  request: Request,
  env: SecurityEnv,
  invitationId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const inv = await env.SYNTILA_DB.prepare(
    "SELECT * FROM person_invitations WHERE id = ?1",
  )
    .bind(invitationId)
    .first<{
      id: string;
      inviter_user_id: string;
      invitee_user_id: string | null;
      email: string | null;
      status: string;
    }>();

  if (!inv) {
    throw new HttpError(404, "Invitation not found");
  }

  if (inv.status === "declined") {
    return json({ status: "declined" });
  }

  if (inv.status === "accepted" || inv.status === "cancelled") {
    throw new HttpError(400, "Invitation is no longer valid");
  }

  if (inv.inviter_user_id === context.userId) {
    throw new HttpError(400, "Cannot decline your own invitation");
  }

  const isIntended =
    inv.invitee_user_id === context.userId ||
    (inv.email && inv.email.toLowerCase() === context.user.email.toLowerCase());

  if (!isIntended) {
    throw new HttpError(
      403,
      "You are not the intended recipient of this invitation",
    );
  }

  const now = new Date().toISOString();
  await env.SYNTILA_DB.prepare(
    "UPDATE person_invitations SET status = 'declined', updated_at = ?1 WHERE id = ?2",
  )
    .bind(now, invitationId)
    .run();

  const publisher = createEventPublisher(env);
  await publisher.publish({
    type: "people.updated",
    stream: { kind: "user", id: inv.inviter_user_id },
    payload: { entityId: invitationId },
  });
  await publisher.publish({
    type: "people.updated",
    stream: { kind: "user", id: context.userId },
    payload: { entityId: invitationId },
  });

  return json({ status: "declined" });
}

export async function handleCancelPersonInvitation(
  request: Request,
  env: SecurityEnv,
  invitationId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const inv = await env.SYNTILA_DB.prepare(
    "SELECT * FROM person_invitations WHERE id = ?1",
  )
    .bind(invitationId)
    .first<{
      id: string;
      inviter_user_id: string;
      invitee_user_id: string | null;
      status: string;
    }>();

  if (!inv) {
    throw new HttpError(404, "Invitation not found");
  }

  if (inv.inviter_user_id !== context.userId) {
    throw new HttpError(
      403,
      "Only the inviter can cancel this invitation",
    );
  }

  if (inv.status === "cancelled") {
    return json({ status: "cancelled" });
  }

  if (inv.status === "accepted") {
    throw new HttpError(400, "Cannot cancel an accepted invitation");
  }

  const now = new Date().toISOString();
  await env.SYNTILA_DB.prepare(
    "UPDATE person_invitations SET status = 'cancelled', updated_at = ?1 WHERE id = ?2",
  )
    .bind(now, invitationId)
    .run();

  const publisher = createEventPublisher(env);
  await publisher.publish({
    type: "people.updated",
    stream: { kind: "user", id: context.userId },
    payload: { entityId: invitationId },
  });
  if (inv.invitee_user_id) {
    await publisher.publish({
      type: "people.updated",
      stream: { kind: "user", id: inv.invitee_user_id },
      payload: { entityId: invitationId },
    });
  }

  return json({ status: "cancelled" });
}

export async function handleDisconnectPersonConnection(
  request: Request,
  env: SecurityEnv,
  targetUserId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const { userLowId, userHighId } = normalizeUserPair(
    context.userId,
    targetUserId,
  );
  const now = new Date().toISOString();
  await env.SYNTILA_DB.prepare(
    `UPDATE person_connections SET status = 'disconnected', disconnected_at = ?1
     WHERE user_low_id = ?2 AND user_high_id = ?3 AND status = 'connected'`,
  )
    .bind(now, userLowId, userHighId)
    .run();

  const publisher = createEventPublisher(env);
  await publisher.publish({
    type: "people.updated",
    stream: { kind: "user", id: userLowId },
    payload: { entityId: userHighId },
  });
  await publisher.publish({
    type: "people.updated",
    stream: { kind: "user", id: userHighId },
    payload: { entityId: userLowId },
  });

  return json({ status: "disconnected" });
}

export async function handleBlockPerson(
  request: Request,
  env: SecurityEnv,
  targetUserId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (context.userId === targetUserId) {
    throw new HttpError(400, "Cannot block yourself");
  }
  const now = new Date().toISOString();
  const { userLowId, userHighId } = normalizeUserPair(
    context.userId,
    targetUserId,
  );

  // 1. Insert into user_blocks
  await env.SYNTILA_DB.prepare(
    `INSERT INTO user_blocks (blocker_user_id, blocked_user_id, created_at)
     VALUES (?1, ?2, ?3)
     ON CONFLICT(blocker_user_id, blocked_user_id) DO NOTHING`,
  )
    .bind(context.userId, targetUserId, now)
    .run();

  // 2. Disconnect connection if connected
  await env.SYNTILA_DB.prepare(
    `UPDATE person_connections SET status = 'disconnected', disconnected_at = ?1
     WHERE user_low_id = ?2 AND user_high_id = ?3 AND status = 'connected'`,
  )
    .bind(now, userLowId, userHighId)
    .run();

  // 3. Cancel pending invitations in either direction
  await env.SYNTILA_DB.prepare(
    `UPDATE person_invitations SET status = 'cancelled', updated_at = ?1
     WHERE status = 'pending'
       AND ((inviter_user_id = ?2 AND invitee_user_id = ?3) OR (inviter_user_id = ?3 AND invitee_user_id = ?2))`,
  )
    .bind(now, context.userId, targetUserId)
    .run();

  // 4. Publish people.updated event to both users
  const publisher = createEventPublisher(env);
  await publisher.publish({
    type: "people.updated",
    stream: { kind: "user", id: context.userId },
    payload: { entityId: targetUserId },
  });
  await publisher.publish({
    type: "people.updated",
    stream: { kind: "user", id: targetUserId },
    payload: { entityId: context.userId },
  });

  return json({ status: "blocked" });
}

export async function handleUnblockPerson(
  request: Request,
  env: SecurityEnv,
  targetUserId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await env.SYNTILA_DB.prepare(
    "DELETE FROM user_blocks WHERE blocker_user_id = ?1 AND blocked_user_id = ?2",
  )
    .bind(context.userId, targetUserId)
    .run();

  const publisher = createEventPublisher(env);
  await publisher.publish({
    type: "people.updated",
    stream: { kind: "user", id: context.userId },
    payload: { entityId: targetUserId },
  });
  await publisher.publish({
    type: "people.updated",
    stream: { kind: "user", id: targetUserId },
    payload: { entityId: context.userId },
  });

  return json({ status: "unblocked" });
}



/**
 * GET /api/people/support: the caller's support Space and sidebar visibility
 * without provisioning. POST /api/people/support gets or creates the Space.
 */
export async function handleEnsureSupportSpace(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (request.method === "GET") {
    const row = await env.SYNTILA_DB.prepare(
      `SELECT ss.space_id AS spaceId, COALESCE(dsus.hidden, 1) AS hidden
       FROM support_spaces ss
       JOIN space_memberships pm ON pm.space_id = ss.space_id AND pm.user_id = ss.user_id
       LEFT JOIN direct_space_user_state dsus
         ON dsus.space_id = ss.space_id AND dsus.user_id = ss.user_id
       WHERE ss.user_id = ?1
       ORDER BY ss.created_at DESC LIMIT 1`,
    )
      .bind(context.userId)
      .first<{ spaceId: string; hidden: number }>();
    return json({
      spaceId: row?.spaceId ?? null,
      hidden: row ? row.hidden === 1 : true,
    });
  }
  if (request.method !== "POST")
    throw new HttpError(405, "Method not allowed");
  try {
    const result = await ensureSupportSpace(env, context.userId);
    const state = await env.SYNTILA_DB.prepare(
      "SELECT hidden FROM direct_space_user_state WHERE space_id = ?1 AND user_id = ?2",
    )
      .bind(result.spaceId, context.userId)
      .first<{ hidden: number }>();
    return json(
      { spaceId: result.spaceId, hidden: (state?.hidden ?? 1) === 1 },
      { status: result.created ? 201 : 200 },
    );
  } catch (error) {
    if (error instanceof SupportSpaceError)
      throw new HttpError(error.status, error.message);
    throw error;
  }
}
