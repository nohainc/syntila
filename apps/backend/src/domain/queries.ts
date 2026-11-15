/**
 * Small lookups that many handlers need. One definition each, so the SQL
 * lives in one place instead of being repeated in every route file.
 */

/** True when either user has blocked the other. */
export async function usersBlocked(db: D1Database, userA: string, userB: string): Promise<boolean> {
  const row = await db
    .prepare(
      `SELECT 1 FROM user_blocks
        WHERE (blocker_user_id = ?1 AND blocked_user_id = ?2) OR (blocker_user_id = ?2 AND blocked_user_id = ?1)`,
    )
    .bind(userA, userB)
    .first();
  return row !== null;
}

/** The user's membership in a Space, or null when they are not a member. */
export async function spaceMembership(db: D1Database, spaceId: string, userId: string): Promise<{ role: string } | null> {
  return db
    .prepare("SELECT role FROM space_memberships WHERE space_id = ?1 AND user_id = ?2")
    .bind(spaceId, userId)
    .first<{ role: string }>();
}

/** True when the user is a member of the Space. */
export async function isSpaceMember(db: D1Database, spaceId: string, userId: string): Promise<boolean> {
  return (await spaceMembership(db, spaceId, userId)) !== null;
}

/** True when the user owns the Workspace and it has not been revoked. */
export async function ownsActiveWorkspace(db: D1Database, workspaceId: string, userId: string): Promise<boolean> {
  const row = await db
    .prepare("SELECT 1 FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2 AND status != 'revoked'")
    .bind(workspaceId, userId)
    .first();
  return row !== null;
}

/** The account status of a user, or null when the user does not exist. */
export async function userAccount(db: D1Database, userId: string): Promise<{ status: string } | null> {
  return db.prepare("SELECT status FROM users WHERE id = ?1").bind(userId).first<{ status: string }>();
}

/** The kind of a Space ("group" or "direct"), or null when it does not exist. */
export async function spaceKind(db: D1Database, spaceId: string): Promise<{ kind: string } | null> {
  return db.prepare("SELECT kind FROM spaces WHERE id = ?1").bind(spaceId).first<{ kind: string }>();
}
