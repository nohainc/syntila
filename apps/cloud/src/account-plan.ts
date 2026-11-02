import { HttpError } from "./routes/http-security.js";
import { ACTIVE_ASSIGNMENT_STATUS_SQL } from "./assignment-transitions.js";

/**
 * Syntila has two account tiers. `paid` is the stable identifier; the product
 * name shown to people ("Syntila Plus") is presentation and lives in the app.
 */
export type AccountTier = "free" | "paid";
export type AccountPlanStatus = "active" | "trialing" | "past_due" | "canceled";

/**
 * Features available only on the paid tier. Gate features by name, never by
 * tier, so a feature can move between tiers without touching its call sites.
 */
export const PAID_FEATURES = ["workspace.sharing"] as const;
export type PaidFeature = (typeof PAID_FEATURES)[number];

const FEATURE_LABELS: Record<PaidFeature, string> = {
  "workspace.sharing": "Sharing a Workspace",
};

/**
 * Registered Workspaces a Free account may own. Plus has no subscription-based
 * count limit. Existing registrations are never removed when this is exceeded
 * (for example after a downgrade); only new registrations are refused.
 */
export const FREE_PERSONAL_WORKSPACE_LIMIT = 1;

export function personalWorkspaceLimit(tier: AccountTier): number | null {
  return tier === "paid" ? null : FREE_PERSONAL_WORKSPACE_LIMIT;
}

/**
 * SQL condition, for the WHERE of an INSERT ... SELECT, that `userParam` may
 * register one more Workspace: the owner is on Plus now, or owns fewer than the
 * Free allowance of non-removed registrations (offline ones included; Workspaces
 * shared with the owner are not owned and never counted). Evaluating it inside
 * the INSERT makes admission atomic with the write.
 */
export function personalWorkspaceAdmissionSql(userParam: string): string {
  return `(${paidOwnerSql(userParam)}
    OR (SELECT COUNT(*) FROM execution_workspaces ow
         WHERE ow.owner_user_id = ${userParam} AND ow.status != 'revoked')
       < ${FREE_PERSONAL_WORKSPACE_LIMIT})`;
}

export async function countOwnedWorkspaces(
  env: Env,
  userId: string,
): Promise<number> {
  const row = await env.SYNTILA_DB.prepare(
    "SELECT COUNT(*) AS count FROM execution_workspaces WHERE owner_user_id = ?1 AND status != 'revoked'",
  )
    .bind(userId)
    .first<{ count: number }>();
  return row?.count ?? 0;
}

/** Rejected because a Free account already owns its personal Workspace. */
export class PersonalWorkspaceLimitError extends HttpError {
  readonly code = "personal_workspace_limit_reached";
  constructor() {
    super(
      402,
      "Free includes one personal Workspace. Upgrade to Syntila Plus to connect more machines.",
    );
  }
}

/**
 * Concurrent AI executions a Free requester may have. Plus has no
 * subscription-based cap. An execution is one non-terminal Worker Assignment
 * attributed to the authenticated requester (never the Workspace owner): the
 * slot is taken by the assignment INSERT and freed only by a terminal status,
 * so a revocation that is not yet confirmed keeps holding it.
 */
export const FREE_CONCURRENT_EXECUTION_LIMIT = 1;

/** A waiter whose Workflow has not heartbeated in this long stops blocking others. */
export const EXECUTION_WAITER_STALE_MS = 2 * 60 * 1000;

export function concurrentExecutionLimit(tier: AccountTier): number | null {
  return tier === "paid" ? null : FREE_CONCURRENT_EXECUTION_LIMIT;
}

/**
 * SQL condition, for the WHERE of the assignment INSERT ... SELECT, that
 * `userParam` may start one more execution for `taskParam`: the requester is
 * on Plus now, or holds fewer than the Free limit of live assignments and no
 * earlier eligible request is waiting for the slot (`cutoffParam` is the
 * oldest heartbeat that still counts). Evaluated inside the INSERT, it makes
 * the check and the reservation one atomic write.
 */
export function executionSlotAdmissionSql(
  userParam: string,
  taskParam: string,
  cutoffParam: string,
): string {
  return `(${paidOwnerSql(userParam)}
    OR ((SELECT COUNT(*) FROM worker_assignments sa
          WHERE sa.requested_by_user_id = ${userParam}
            AND sa.status IN (${ACTIVE_ASSIGNMENT_STATUS_SQL}))
        < ${FREE_CONCURRENT_EXECUTION_LIMIT}
        AND NOT EXISTS (
          SELECT 1 FROM account_execution_waiters w
           WHERE w.requester_user_id = ${userParam}
             AND w.task_id != ${taskParam}
             AND w.reason = 'account_concurrency_limit'
             AND w.heartbeat_at >= ${cutoffParam}
             AND (NOT EXISTS (SELECT 1 FROM account_execution_waiters me
                               WHERE me.task_id = ${taskParam})
                  OR w.enqueued_at < (SELECT me.enqueued_at
                                        FROM account_execution_waiters me
                                       WHERE me.task_id = ${taskParam})
                  OR (w.enqueued_at = (SELECT me.enqueued_at
                                         FROM account_execution_waiters me
                                        WHERE me.task_id = ${taskParam})
                      AND w.task_id < ${taskParam})))))`;
}

export interface AccountPlan {
  /** The tier the person is entitled to right now. */
  readonly tier: AccountTier;
  /** Subscription status, or null when the person never had a paid plan. */
  readonly status: AccountPlanStatus | null;
  readonly currentPeriodEnd: string | null;
  readonly features: readonly PaidFeature[];
  /** Owned registrations against the allowance; `limit` null means unlimited. */
  readonly workspaces: {
    readonly owned: number;
    readonly limit: number | null;
  };
}

interface AccountPlanRow {
  tier: AccountTier;
  status: AccountPlanStatus;
  current_period_end: string | null;
}

const ENTITLED_STATUSES = new Set<AccountPlanStatus>([
  "active",
  "trialing",
  // The provider retries payment and cancels on final failure; access stays
  // until then so a declined card does not interrupt work mid-period.
  "past_due",
]);

/**
 * SQL condition that `ownerColumn` is on the paid tier now; it mirrors
 * [effectiveTier] for queries that join many owners. Lent Workspaces are
 * honored only while it holds, so a lapsed plan pauses sharing without
 * deleting grants, and renewing restores it.
 */
export function paidOwnerSql(ownerColumn: string): string {
  return `EXISTS (SELECT 1 FROM account_plans ap
    WHERE ap.user_id = ${ownerColumn} AND ap.tier = 'paid'
      AND ap.status IN ('active', 'trialing', 'past_due')
      AND (ap.current_period_end IS NULL
           OR julianday(ap.current_period_end) > julianday('now')))`;
}

export function effectiveTier(
  row: AccountPlanRow | null,
  now: Date = new Date(),
): AccountTier {
  if (!row || row.tier !== "paid" || !ENTITLED_STATUSES.has(row.status))
    return "free";
  // A missing period end is an open-ended manual grant.
  if (row.current_period_end && Date.parse(row.current_period_end) <= +now)
    return "free";
  return "paid";
}

export async function getAccountPlan(
  env: Env,
  userId: string,
  now: Date = new Date(),
): Promise<AccountPlan> {
  const row = await env.SYNTILA_DB.prepare(
    "SELECT tier, status, current_period_end FROM account_plans WHERE user_id = ?1",
  )
    .bind(userId)
    .first<AccountPlanRow>();
  const tier = effectiveTier(row, now);
  return {
    tier,
    status: row?.status ?? null,
    currentPeriodEnd: row?.current_period_end ?? null,
    features: tier === "paid" ? PAID_FEATURES : [],
    workspaces: {
      owned: await countOwnedWorkspaces(env, userId),
      limit: personalWorkspaceLimit(tier),
    },
  };
}

/** Rejected because the feature requires the paid tier. */
export class PaidPlanRequiredError extends HttpError {
  readonly code = "paid_plan_required";
  constructor(readonly feature: PaidFeature) {
    super(402, `${FEATURE_LABELS[feature]} requires a paid plan`);
  }
}

export async function hasPaidFeature(
  env: Env,
  userId: string,
  feature: PaidFeature,
): Promise<boolean> {
  return (await getAccountPlan(env, userId)).features.includes(feature);
}

/** Server-side gate for paid features. Call it in the handler that acts. */
export async function requirePaidFeature(
  env: Env,
  userId: string,
  feature: PaidFeature,
): Promise<void> {
  if (!(await hasPaidFeature(env, userId, feature)))
    throw new PaidPlanRequiredError(feature);
}
