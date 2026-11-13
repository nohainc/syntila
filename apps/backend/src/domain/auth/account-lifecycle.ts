/**
 * Account lifecycle effects owned by the backend. The auth Worker owns the
 * Better Auth account itself and notifies the backend (internal endpoint)
 * before deleting an account and after a profile update.
 */
import { deleteAccountAvatars } from "../avatar-storage.js";
import { publishPeopleProfileChanged } from "../people.js";

type LifecycleEnv = { SYNTILA_DB: D1Database; SYNTILA_ARTIFACTS?: R2Bucket };

/** Runs everything Better Auth's `beforeDelete` hook used to run. */
export async function prepareAccountDeletion(env: LifecycleEnv, userId: string) {
  if (env.SYNTILA_ARTIFACTS) await deleteAccountAvatars(env.SYNTILA_ARTIFACTS, userId);
  await handleAccountDeletionCleanup(env.SYNTILA_DB, userId);
}

/** Runs what Better Auth's `user.update.after` hook used to run. */
export async function handleAccountProfileUpdated(env: LifecycleEnv, userId: string) {
  await publishPeopleProfileChanged(env as never, userId);
}

export async function handleAccountDeletionCleanup(
  db: D1Database,
  userId: string,
) {
  const now = new Date().toISOString();

  // 1. Direct Spaces where deleting user is the technical owner:
  // Transfer ownership to the remaining participant if active.
  const ownedDirectSpaces = await db
    .prepare(
      `SELECT ds.space_id,
              CASE WHEN ds.user_low_id = ?1 THEN ds.user_high_id ELSE ds.user_low_id END AS peer_user_id
       FROM direct_spaces ds
       JOIN spaces s ON s.id = ds.space_id
       WHERE s.owner_user_id = ?1`,
    )
    .bind(userId)
    .all<{ space_id: string; peer_user_id: string }>();

  for (const row of ownedDirectSpaces.results ?? []) {
    const peer = await db
      .prepare("SELECT status FROM users WHERE id = ?1")
      .bind(row.peer_user_id)
      .first<{ status: string }>();

    if (peer && peer.status === "active") {
      await db
        .prepare(
          "DELETE FROM space_memberships WHERE space_id = ?1 AND user_id = ?2",
        )
        .bind(row.space_id, userId)
        .run();
      await db
        .prepare(
          "UPDATE spaces SET owner_user_id = ?1, updated_at = ?2 WHERE id = ?3",
        )
        .bind(row.peer_user_id, now, row.space_id)
        .run();
      await db
        .prepare(
          "UPDATE space_memberships SET role = 'owner', updated_at = ?1 WHERE space_id = ?2 AND user_id = ?3",
        )
        .bind(now, row.space_id, row.peer_user_id)
        .run();
    } else {
      await db
        .prepare("DELETE FROM direct_spaces WHERE space_id = ?1")
        .bind(row.space_id)
        .run();
      await db
        .prepare("DELETE FROM spaces WHERE id = ?1")
        .bind(row.space_id)
        .run();
    }
  }

  // 2. Direct Spaces where deleting user is a participant but not owner:
  await db
    .prepare(
      `DELETE FROM space_memberships
       WHERE user_id = ?1 AND space_id IN (SELECT space_id FROM direct_spaces)`,
    )
    .bind(userId)
    .run();

  // 3. Disconnect all personal connections
  await db
    .prepare(
      `UPDATE person_connections SET status = 'disconnected', disconnected_at = ?1
       WHERE (user_low_id = ?2 OR user_high_id = ?2) AND status = 'connected'`,
    )
    .bind(now, userId)
    .run();

  // 4. Cancel pending personal invitations
  await db
    .prepare(
      `UPDATE person_invitations SET status = 'cancelled', updated_at = ?1
       WHERE (inviter_user_id = ?2 OR invitee_user_id = ?2) AND status = 'pending'`,
    )
    .bind(now, userId)
    .run();

  // 5. Group Spaces owned by deleting user: transfer to next member or delete if empty
  const ownedGroupSpaces = await db
    .prepare(
      "SELECT id FROM spaces WHERE owner_user_id = ?1 AND COALESCE(kind, 'group') = 'group'",
    )
    .bind(userId)
    .all<{ id: string }>();

  for (const space of ownedGroupSpaces.results ?? []) {
    const nextMember = await db
      .prepare(
        "SELECT user_id FROM space_memberships WHERE space_id = ?1 AND user_id <> ?2 ORDER BY created_at ASC LIMIT 1",
      )
      .bind(space.id, userId)
      .first<{ user_id: string }>();

    if (nextMember) {
      await db
        .prepare(
          "DELETE FROM space_memberships WHERE space_id = ?1 AND user_id = ?2",
        )
        .bind(space.id, userId)
        .run();
      await db
        .prepare(
          "UPDATE spaces SET owner_user_id = ?1, updated_at = ?2 WHERE id = ?3",
        )
        .bind(nextMember.user_id, now, space.id)
        .run();
      await db
        .prepare(
          "UPDATE space_memberships SET role = 'owner', updated_at = ?1 WHERE space_id = ?2 AND user_id = ?3",
        )
        .bind(now, space.id, nextMember.user_id)
        .run();
    } else {
      await db.prepare("DELETE FROM spaces WHERE id = ?1").bind(space.id).run();
    }
  }

  // 6. Lead user on threads
  await db
    .prepare(
      `UPDATE threads
       SET lead_user_id = (SELECT owner_user_id FROM spaces WHERE id = threads.space_id)
       WHERE lead_user_id = ?1`,
    )
    .bind(userId)
    .run();
}
