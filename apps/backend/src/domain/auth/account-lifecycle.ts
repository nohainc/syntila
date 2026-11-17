import { atomically, type Db } from "../../platform/data.js";
/**
 * Account lifecycle effects owned by the backend. The auth Worker owns the
 * Better Auth account itself and notifies the backend (internal endpoint)
 * before deleting an account and after a profile update.
 */
import { deleteAccountAvatars } from "../avatar-storage.js";
import { publishPeopleProfileChanged } from "../people.js";

type LifecycleEnv = { SYNTILA_DB: Db; SYNTILA_ARTIFACTS?: R2Bucket };

/** Runs everything Better Auth's `beforeDelete` hook used to run. */
export async function prepareAccountDeletion(env: LifecycleEnv, userId: string) {
  if (env.SYNTILA_ARTIFACTS) await deleteAccountAvatars(env.SYNTILA_ARTIFACTS, userId);
  await handleAccountDeletionCleanup(env.SYNTILA_DB, userId);
}

/** Runs what Better Auth's `user.update.after` hook used to run. */
export async function handleAccountProfileUpdated(env: LifecycleEnv, userId: string) {
  await publishPeopleProfileChanged(env as never, userId);
}

/**
 * Detaches a user who is deleting their account from shared state, in one
 * transaction (it used to run statement by statement, per Space, and could
 * stop half way):
 *  1. Spaces the user owns are handed over: a Direct Space to its other
 *     participant when that account is active, a group Space to its earliest
 *     other member. The new owner's membership becomes "owner" and the
 *     user's own membership is removed.
 *  2. Owned Spaces nobody can take over are deleted (their content cascades).
 *  3. The user leaves every Direct Space, their personal connections are
 *     disconnected and their pending personal invitations cancelled.
 *  4. Threads they led are led by the Space owner.
 */
export async function handleAccountDeletionCleanup(
  db: Db,
  userId: string,
) {
  const now = new Date().toISOString();
  await atomically(db, "account-lifecycle.batch40", async (q) => {
    await q.run`WITH direct_handover AS (
         SELECT ds.space_id, peer.id AS new_owner
           FROM direct_spaces ds
           JOIN spaces s ON s.id = ds.space_id AND s.owner_user_id = ${userId}
           JOIN users peer ON peer.id = CASE WHEN ds.user_low_id = ${userId} THEN ds.user_high_id ELSE ds.user_low_id END
                          AND peer.status = 'active'
       ), group_handover AS (
         SELECT DISTINCT ON (m.space_id) m.space_id, m.user_id AS new_owner
           FROM spaces s
           JOIN space_memberships m ON m.space_id = s.id AND m.user_id <> ${userId}
          WHERE s.owner_user_id = ${userId} AND COALESCE(s.kind, 'group') = 'group'
          ORDER BY m.space_id, m.created_at, m.id
       ), handover AS (
         SELECT * FROM direct_handover UNION ALL SELECT * FROM group_handover
       ), moved AS (
         UPDATE spaces s SET owner_user_id = h.new_owner, updated_at = ${now}
           FROM handover h WHERE s.id = h.space_id
         RETURNING s.id, h.new_owner
       ), promoted AS (
         UPDATE space_memberships m SET role = 'owner', updated_at = ${now}
           FROM moved WHERE m.space_id = moved.id AND m.user_id = moved.new_owner
         RETURNING m.id
       )
       DELETE FROM space_memberships m USING moved
        WHERE m.space_id = moved.id AND m.user_id = ${userId}`;
    await q.run`DELETE FROM spaces
        WHERE owner_user_id = ${userId}
          AND (COALESCE(kind, 'group') = 'group' OR id IN (SELECT space_id FROM direct_spaces))`;
    await q.run`DELETE FROM space_memberships
        WHERE user_id = ${userId} AND space_id IN (SELECT space_id FROM direct_spaces)`;
    await q.run`UPDATE person_connections SET status = 'disconnected', disconnected_at = ${now}
        WHERE (user_low_id = ${userId} OR user_high_id = ${userId}) AND status = 'connected'`;
    await q.run`UPDATE person_invitations SET status = 'cancelled', updated_at = ${now}
        WHERE (inviter_user_id = ${userId} OR invitee_user_id = ${userId}) AND status = 'pending'`;
    await q.run`UPDATE threads
          SET lead_user_id = (SELECT owner_user_id FROM spaces WHERE id = threads.space_id)
        WHERE lead_user_id = ${userId}`;
  });
}
