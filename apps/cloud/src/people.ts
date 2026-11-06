import {
  createEventPublisher,
  type EventPublisherEnv,
} from "./event-publisher.js";
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
