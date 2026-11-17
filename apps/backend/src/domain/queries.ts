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

/* ------------------------------------------------------------------------
 * Lookups that several modules repeated word for word. Each returns the row
 * shape the callers already used, so call sites read the same as before.
 * --------------------------------------------------------------------- */

/** Status of a Worker Assignment. */
export function assignmentStatus(db: D1Database, assignmentId: string) {
  return db.prepare("SELECT status FROM worker_assignments WHERE id = ?1").bind(assignmentId).first<{ status: string }>();
}

/** Status, task and attempt of a Worker Assignment. */
export function assignmentProgress(db: D1Database, assignmentId: string) {
  return db.prepare("SELECT status, task_id, attempt_id FROM worker_assignments WHERE id = ?1").bind(assignmentId).first<{ status: string; task_id: string; attempt_id: string }>();
}

/** The Space a Thread belongs to. */
export function threadSpace(db: D1Database, threadId: string) {
  return db.prepare("SELECT space_id AS spaceId FROM threads WHERE id = ?1").bind(threadId).first<{ spaceId: string }>();
}

/** Work Requests of a Thread that are queued, running or waiting. */
export function activeWorkCount(db: D1Database, threadId: string) {
  return db.prepare("SELECT COUNT(*) AS count FROM work_requests WHERE thread_id = ?1 AND status IN ('queued', 'running', 'waiting')").bind(threadId).first<{ count: number }>();
}

/** The Thread a Work Request belongs to. */
export function workRequestThread(db: D1Database, workRequestId: string) {
  return db.prepare("SELECT thread_id AS threadId FROM work_requests WHERE id = ?1").bind(workRequestId).first<{ threadId: string }>();
}

/** When cancellation of a Work Request was requested, if it was. */
export function workRequestCancelRequest(db: D1Database, workRequestId: string) {
  return db.prepare("SELECT cancel_requested_at AS cancelRequestedAt FROM work_requests WHERE id = ?1").bind(workRequestId).first<{ cancelRequestedAt: string | null }>();
}

/** The active Thread lease held for a Work Request. */
export function activeThreadLease(db: D1Database, workRequestId: string, threadId: string) {
  return db.prepare("SELECT id, fencing_token AS fencingToken FROM thread_runtime_leases WHERE work_request_id = ?1 AND thread_id = ?2 AND status = 'active' LIMIT 1").bind(workRequestId, threadId).first<{ id: string; fencingToken: number }>();
}

/** Owner of a Space. */
export function spaceOwnerOf(db: D1Database, spaceId: string) {
  return db.prepare("SELECT owner_user_id AS ownerUserId FROM spaces WHERE id = ?1").bind(spaceId).first<{ ownerUserId: string }>();
}

/** Name of a Space. */
export function spaceNameOf(db: D1Database, spaceId: string) {
  return db.prepare("SELECT name FROM spaces WHERE id = ?1").bind(spaceId).first<{ name: string }>();
}

/** A user by email address, ignoring case. */
export function userByEmail(db: D1Database, email: string) {
  return db.prepare("SELECT id FROM users WHERE LOWER(email) = LOWER(?1) LIMIT 1").bind(email).first<{ id: string }>();
}

/** The Direct Space of a pair of people (ids in low/high order). */
export function directSpaceOfPair(db: D1Database, userLowId: string, userHighId: string) {
  return db.prepare("SELECT space_id FROM direct_spaces WHERE user_low_id = ?1 AND user_high_id = ?2").bind(userLowId, userHighId).first<{ space_id: string }>();
}

/** The Direct Space whose General Thread this is. */
export function directSpaceOfGeneralThread(db: D1Database, threadId: string) {
  return db.prepare("SELECT space_id FROM direct_spaces WHERE general_thread_id = ?1").bind(threadId).first<{ space_id: string }>();
}

/** Runtime identities of a Workspace that are not revoked. */
export function activeRuntimeIdentityCount(db: D1Database, workspaceId: string) {
  return db.prepare("SELECT COUNT(*) AS count FROM workspace_runtime_identities WHERE workspace_id = ?1 AND revoked_at IS NULL").bind(workspaceId).first<{ count: number }>();
}

/** A user's plan row (missing row means Free). */
export function accountPlanRow<T = { tier: string; status: string; current_period_end: string | null }>(db: D1Database, userId: string) {
  return db.prepare("SELECT tier, status, current_period_end FROM account_plans WHERE user_id = ?1").bind(userId).first<T>();
}

/** The default Workflow a Space chose. */
export function spaceWorkflowDefault(db: D1Database, spaceId: string) {
  return db.prepare("SELECT workflow_id AS workflowId FROM space_workflow_defaults WHERE space_id = ?1").bind(spaceId).first<{ workflowId: string }>();
}

/** The default Workflow a user chose for a Workspace. */
export function userWorkflowDefault(db: D1Database, userId: string, workspaceId: string) {
  return db.prepare("SELECT workflow_id AS workflowId FROM user_workflow_defaults WHERE user_id = ?1 AND workspace_id = ?2").bind(userId, workspaceId).first<{ workflowId: string }>();
}

/* ------------------------------------------------------------------------
 * Work Request state changes shared by the request routes, the Thread
 * coordinator and the Workflow runner. They return statements so callers
 * can put them in one batch with their own writes.
 * --------------------------------------------------------------------- */

/** Cancels a Work Request's tasks that have not started. */
export function cancelPendingTasks(db: D1Database, workRequestId: string, now: string) {
  return db
    .prepare("UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status IN ('queued', 'waiting')")
    .bind(now, workRequestId);
}

/** Cancels a queued Work Request with its Run and its tasks. */
export function cancelQueuedWorkRequest(db: D1Database, workRequestId: string, now: string): D1PreparedStatement[] {
  return [
    db.prepare("UPDATE work_requests SET status = 'cancelled', updated_at = ?1 WHERE id = ?2 AND status = 'queued'").bind(now, workRequestId),
    db.prepare("UPDATE runs SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status = 'created'").bind(now, workRequestId),
    cancelPendingTasks(db, workRequestId, now),
  ];
}

/** Marks a queued Work Request and its Run as running. */
export function startQueuedWorkRequest(db: D1Database, workRequestId: string, now: string): D1PreparedStatement[] {
  return [
    db.prepare("UPDATE work_requests SET status = 'running', updated_at = ?1 WHERE id = ?2 AND status = 'queued'").bind(now, workRequestId),
    db.prepare("UPDATE runs SET status = 'running', updated_at = ?1 WHERE work_request_id = ?2 AND status = 'created'").bind(now, workRequestId),
  ];
}
