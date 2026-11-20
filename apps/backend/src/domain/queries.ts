/**
 * Small lookups that many handlers need. One definition each, so the SQL
 * lives in one place instead of being repeated in every route file.
 */
import type { Query } from "../platform/data.js";
import { recordAiOutcome } from "./ai-timeline.js";

/** True when either user has blocked the other. */
export async function usersBlocked(q: Query, userA: string, userB: string): Promise<boolean> {
  const row = await q.row`SELECT 1 FROM user_blocks
        WHERE (blocker_user_id = ${userA} AND blocked_user_id = ${userB}) OR (blocker_user_id = ${userB} AND blocked_user_id = ${userA})`;
  return row !== null;
}

/** The user's membership in a Space, or null when they are not a member. */
export async function spaceMembership(q: Query, spaceId: string, userId: string): Promise<{ role: string } | null> {
  return q.row<{ role: string }>`SELECT role FROM space_memberships WHERE space_id = ${spaceId} AND user_id = ${userId}`;
}

/** True when the user is a member of the Space. */
export async function isSpaceMember(q: Query, spaceId: string, userId: string): Promise<boolean> {
  return (await spaceMembership(q, spaceId, userId)) !== null;
}

/** True when the user owns the Workspace and it has not been revoked. */
export async function ownsActiveWorkspace(q: Query, workspaceId: string, userId: string): Promise<boolean> {
  const row = await q.row`SELECT 1 FROM execution_workspaces WHERE id = ${workspaceId} AND owner_user_id = ${userId} AND status != 'revoked'`;
  return row !== null;
}

/** The account status of a user, or null when the user does not exist. */
export async function userAccount(q: Query, userId: string): Promise<{ status: string } | null> {
  return q.row<{ status: string }>`SELECT status FROM users WHERE id = ${userId}`;
}

/** The kind of a Space ("group" or "direct"), or null when it does not exist. */
export async function spaceKind(q: Query, spaceId: string): Promise<{ kind: string } | null> {
  return q.row<{ kind: string }>`SELECT kind FROM spaces WHERE id = ${spaceId}`;
}

/* ------------------------------------------------------------------------
 * Lookups that several modules repeated word for word. Each returns the row
 * shape the callers already used, so call sites read the same as before.
 * --------------------------------------------------------------------- */

/** Status of a Worker Assignment. */
export function assignmentStatus(q: Query, assignmentId: string) {
  return q.row<{ status: string }>`SELECT status FROM worker_assignments WHERE id = ${assignmentId}`;
}

/** Status, task and attempt of a Worker Assignment. */
export function assignmentProgress(q: Query, assignmentId: string) {
  return q.row<{ status: string; task_id: string; attempt_id: string }>`SELECT status, task_id, attempt_id FROM worker_assignments WHERE id = ${assignmentId}`;
}

/** The Space a Thread belongs to. */
export function threadSpace(q: Query, threadId: string) {
  return q.row<{ spaceId: string }>`SELECT space_id AS "spaceId" FROM threads WHERE id = ${threadId}`;
}

/** Work Requests of a Thread that are queued, running or waiting. */
export function activeWorkCount(q: Query, threadId: string) {
  return q.row<{ count: number }>`SELECT COUNT(*) AS count FROM work_requests WHERE thread_id = ${threadId} AND status IN ('queued', 'running', 'waiting')`;
}

/** The Thread a Work Request belongs to. */
export function workRequestThread(q: Query, workRequestId: string) {
  return q.row<{ threadId: string }>`SELECT thread_id AS "threadId" FROM work_requests WHERE id = ${workRequestId}`;
}

/** When cancellation of a Work Request was requested, if it was. */
export function workRequestCancelRequest(q: Query, workRequestId: string) {
  return q.row<{ cancelRequestedAt: string | null }>`SELECT cancel_requested_at AS "cancelRequestedAt" FROM work_requests WHERE id = ${workRequestId}`;
}

/** The active Thread lease held for a Work Request. */
export function activeThreadLease(q: Query, workRequestId: string, threadId: string) {
  return q.row<{ id: string; fencingToken: number }>`SELECT id, fencing_token AS "fencingToken" FROM thread_runtime_leases WHERE work_request_id = ${workRequestId} AND thread_id = ${threadId} AND status = 'active' LIMIT 1`;
}

/** Owner of a Space. */
export function spaceOwnerOf(q: Query, spaceId: string) {
  return q.row<{ ownerUserId: string }>`SELECT owner_user_id AS "ownerUserId" FROM spaces WHERE id = ${spaceId}`;
}

/** Name of a Space. */
export function spaceNameOf(q: Query, spaceId: string) {
  return q.row<{ name: string }>`SELECT name FROM spaces WHERE id = ${spaceId}`;
}

/** A user by email address, ignoring case. */
export function userByEmail(q: Query, email: string) {
  return q.row<{ id: string }>`SELECT id FROM users WHERE LOWER(email) = LOWER(${email}) LIMIT 1`;
}

/** The Direct Space of a pair of people (ids in low/high order). */
export function directSpaceOfPair(q: Query, userLowId: string, userHighId: string) {
  return q.row<{ space_id: string }>`SELECT space_id FROM direct_spaces WHERE user_low_id = ${userLowId} AND user_high_id = ${userHighId}`;
}

/** The Direct Space whose General Thread this is. */
export function directSpaceOfGeneralThread(q: Query, threadId: string) {
  return q.row<{ space_id: string }>`SELECT space_id FROM direct_spaces WHERE general_thread_id = ${threadId}`;
}

/** Runtime identities of a Workspace that are not revoked. */
export function activeRuntimeIdentityCount(q: Query, workspaceId: string) {
  return q.row<{ count: number }>`SELECT COUNT(*) AS count FROM workspace_runtime_identities WHERE workspace_id = ${workspaceId} AND revoked_at IS NULL`;
}

/** A user's plan row (missing row means Free). */
export function accountPlanRow<T = { tier: string; status: string; current_period_end: string | null }>(q: Query, userId: string) {
  return q.row<T>`SELECT tier, status, current_period_end FROM account_plans WHERE user_id = ${userId}`;
}

/** The default Workflow a Space chose. */
export function spaceWorkflowDefault(q: Query, spaceId: string) {
  return q.row<{ workflowId: string }>`SELECT workflow_id AS "workflowId" FROM space_workflow_defaults WHERE space_id = ${spaceId}`;
}

/** The default Workflow a user chose for a Workspace. */
export function userWorkflowDefault(q: Query, userId: string, workspaceId: string) {
  return q.row<{ workflowId: string }>`SELECT workflow_id AS "workflowId" FROM user_workflow_defaults WHERE user_id = ${userId} AND workspace_id = ${workspaceId}`;
}

/* ------------------------------------------------------------------------
 * Work Request state changes shared by the request routes, the Thread
 * coordinator and the Workflow runner. They run on the caller's
 * Query, so callers can put them in one transaction with their own writes.
 * --------------------------------------------------------------------- */

type Runner = Pick<Query, "run">;

/** Cancels a Work Request's tasks that have not started. */
export async function cancelPendingTasks(q: Runner, workRequestId: string, now: string): Promise<void> {
  await q.run`UPDATE workflow_tasks SET status = 'cancelled', finished_at = ${now}, updated_at = ${now} WHERE work_request_id = ${workRequestId} AND status IN ('queued', 'waiting')`;
}

/** Cancels a queued Work Request with its Run and its tasks. */
export async function cancelQueuedWorkRequest(q: Runner, workRequestId: string, now: string): Promise<void> {
  await q.run`UPDATE work_requests SET status = 'cancelled', updated_at = ${now} WHERE id = ${workRequestId} AND status = 'queued'`;
  await recordAiOutcome(q, workRequestId);
  await q.run`UPDATE runs SET status = 'cancelled', finished_at = ${now}, updated_at = ${now} WHERE work_request_id = ${workRequestId} AND status = 'created'`;
  await cancelPendingTasks(q, workRequestId, now);
}

/** Marks a queued Work Request and its Run as running. */
export async function startQueuedWorkRequest(q: Runner, workRequestId: string, now: string): Promise<void> {
  await q.run`UPDATE work_requests SET status = 'running', updated_at = ${now} WHERE id = ${workRequestId} AND status = 'queued'`;
  await q.run`UPDATE runs SET status = 'running', updated_at = ${now} WHERE work_request_id = ${workRequestId} AND status = 'created'`;
}
