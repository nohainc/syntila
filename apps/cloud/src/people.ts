import {
  createEventPublisher,
  type EventPublisherEnv,
} from "./event-publisher.js";
import { publishCollaborationEvent } from "./collaboration-events.js";
import { normalizeUserPair } from "@syntila/core";
export { normalizeUserPair, type NormalizedUserPair } from "@syntila/core";

/** Read IDs only from the authenticated user's established graph, never a global directory. */
export async function peoplePeers(
  env: Pick<EventPublisherEnv, "SYNTILA_DB">,
  userId: string,
) {
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT user_high_id AS userId FROM people_relationships WHERE user_low_id=?1
    UNION SELECT user_low_id AS userId FROM people_relationships WHERE user_high_id=?1
    UNION SELECT user_high_id AS userId FROM person_connections WHERE user_low_id=?1 AND status='connected'
    UNION SELECT user_low_id AS userId FROM person_connections WHERE user_high_id=?1 AND status='connected'`,
  )
    .bind(userId)
    .all<{ userId: string }>();
  return rows.results.map((row) => row.userId);
}

/** Read IDs only from the authenticated user's approved 1:1 connections. */
export async function connectedPeers(
  env: Pick<EventPublisherEnv, "SYNTILA_DB">,
  userId: string,
) {
  const rows = await env.SYNTILA_DB.prepare(
    `SELECT user_high_id AS userId FROM person_connections WHERE user_low_id=?1 AND status='connected'
    UNION ALL SELECT user_low_id AS userId FROM person_connections WHERE user_high_id=?1 AND status='connected'`,
  )
    .bind(userId)
    .all<{ userId: string }>();
  return rows.results.map((row) => row.userId);
}

export async function publishPeopleProfileChanged(
  env: EventPublisherEnv,
  userId: string,
) {
  const publisher = createEventPublisher(env);
  for (const peer of await peoplePeers(env, userId)) {
    await publisher.publish({
      type: "people.updated",
      stream: { kind: "user", id: peer },
      payload: { entityId: userId },
    });
  }
}

export class SupportSpaceError extends Error {
  constructor(
    readonly status: 403 | 409 | 503,
    message: string,
  ) {
    super(message);
  }
}

export interface SupportSpaceEnv extends EventPublisherEnv {
  readonly SYNTILA_SUPPORT_ACCOUNT_EMAIL?: string;
}

/**
 * Get or create the user's personal support Space with the configured support
 * account. The Space is a Direct Space (unique per user pair), so concurrent
 * requests converge on one row; a pre-existing Direct Space with the support
 * account is adopted rather than duplicated, preserving its history.
 */
export async function ensureSupportSpace(
  env: SupportSpaceEnv,
  userId: string,
): Promise<{ spaceId: string; supportUserId: string; created: boolean }> {
  const email = env.SYNTILA_SUPPORT_ACCOUNT_EMAIL?.trim().toLowerCase();
  if (!email) throw new SupportSpaceError(503, "Support is not configured");
  const support = await env.SYNTILA_DB.prepare(
    "SELECT id FROM users WHERE LOWER(email) = ?1 AND status = 'active'",
  )
    .bind(email)
    .first<{ id: string }>();
  if (!support)
    throw new SupportSpaceError(503, "Support account is unavailable");
  if (support.id === userId)
    throw new SupportSpaceError(409, "The support account has no support Space");

  const blocked = await env.SYNTILA_DB.prepare(
    `SELECT 1 FROM user_blocks
     WHERE (blocker_user_id = ?1 AND blocked_user_id = ?2)
        OR (blocker_user_id = ?2 AND blocked_user_id = ?1)`,
  )
    .bind(userId, support.id)
    .first();
  if (blocked) throw new SupportSpaceError(403, "Support is unavailable");

  const lookup = async () => {
    const marked = await env.SYNTILA_DB.prepare(
      "SELECT space_id AS spaceId FROM support_spaces WHERE user_id = ?1 AND support_user_id = ?2",
    )
      .bind(userId, support.id)
      .first<{ spaceId: string }>();
    if (marked) return marked.spaceId;
    const { userLowId, userHighId } = normalizeUserPair(userId, support.id);
    const direct = await env.SYNTILA_DB.prepare(
      "SELECT space_id AS spaceId FROM direct_spaces WHERE user_low_id = ?1 AND user_high_id = ?2",
    )
      .bind(userLowId, userHighId)
      .first<{ spaceId: string }>();
    return direct?.spaceId ?? null;
  };
  const adopt = (spaceId: string, now: string) =>
    env.SYNTILA_DB.prepare(
      `INSERT INTO support_spaces (user_id, support_user_id, space_id, created_at)
       VALUES (?1, ?2, ?3, ?4) ON CONFLICT DO NOTHING`,
    ).bind(userId, support.id, spaceId, now);

  const existing = await lookup();
  if (existing) {
    await adopt(existing, new Date().toISOString()).run();
    return { spaceId: existing, supportUserId: support.id, created: false };
  }

  const { userLowId, userHighId } = normalizeUserPair(userId, support.id);
  const now = new Date().toISOString();
  const spaceId = `space-direct-${crypto.randomUUID()}`;
  const db = env.SYNTILA_DB;
  const mutations = [
    db
      .prepare(
        "INSERT INTO spaces (id, owner_user_id, name, kind, settings_json, created_at, updated_at) VALUES (?1, ?2, 'Syntila Support', 'direct', '{}', ?3, ?3)",
      )
      .bind(spaceId, userId, now),
    db
      .prepare(
        "INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES (?1, ?2, ?3, 'owner', ?4, ?4)",
      )
      .bind(`pm-${crypto.randomUUID()}`, spaceId, userId, now),
    db
      .prepare(
        "INSERT INTO space_memberships (id, space_id, user_id, role, created_at, updated_at) VALUES (?1, ?2, ?3, 'collaborator', ?4, ?4)",
      )
      .bind(`pm-${crypto.randomUUID()}`, spaceId, support.id, now),
    db
      .prepare(
        "INSERT INTO direct_spaces (space_id, user_low_id, user_high_id, general_thread_id, created_at) VALUES (?1, ?2, ?3, NULL, ?4)",
      )
      .bind(spaceId, userLowId, userHighId, now),
    db
      .prepare(
        "INSERT INTO direct_space_user_state (space_id, user_id, hidden, created_at, updated_at) VALUES (?1, ?2, 1, ?3, ?3)",
      )
      .bind(spaceId, userId, now),
    db
      .prepare(
        "INSERT INTO direct_space_user_state (space_id, user_id, hidden, created_at, updated_at) VALUES (?1, ?2, 0, ?3, ?3)",
      )
      .bind(spaceId, support.id, now),
    db
      .prepare(
        "INSERT INTO support_spaces (user_id, support_user_id, space_id, created_at) VALUES (?1, ?2, ?3, ?4)",
      )
      .bind(userId, support.id, spaceId, now),
  ];
  try {
    await publishCollaborationEvent(env, "space.created", spaceId, spaceId, {
      recipientUserIds: [userId, support.id],
      additionalRecipientUserIds: [userId, support.id],
      mutations,
    });
  } catch (error) {
    // The batch is atomic: a concurrent winner leaves no partial rows here.
    const winner = await lookup();
    if (!winner) throw error;
    await adopt(winner, now).run();
    return { spaceId: winner, supportUserId: support.id, created: false };
  }
  return { spaceId, supportUserId: support.id, created: true };
}
