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
export const PAID_FEATURES = [
  "workspace.sharing",
  "workflow.research",
  "workflow.implement",
  "workers.custom_plugins",
] as const;
export type PaidFeature = (typeof PAID_FEATURES)[number];

const FEATURE_LABELS: Record<PaidFeature, string> = {
  "workspace.sharing": "Sharing a Workspace",
  "workflow.research": "Research",
  "workflow.implement": "Implement",
  "workers.custom_plugins": "Custom Worker plugins",
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

/**
 * People a Free-owned Space allows, the owner included. The Space *owner's*
 * effective plan decides: Plus-owned Spaces have no subscription-based cap, and
 * a Free person may join a larger Plus-owned Space. Each Space is counted on
 * its own. Existing members and invitations are never removed when a Space
 * exceeds the allowance (for example after a downgrade); only additions stop.
 */
export const FREE_SPACE_MEMBER_LIMIT = 4;

export function spaceMemberLimit(tier: AccountTier): number | null {
  return tier === "paid" ? null : FREE_SPACE_MEMBER_LIMIT;
}

/** Accepted human members plus valid pending invitations, which reserve a slot. */
export function spaceMemberUsageSql(
  spaceParam: string,
  excludeInvitationParam: string | null = null,
): string {
  const exclude = excludeInvitationParam
    ? ` AND pi.id != ${excludeInvitationParam}`
    : "";
  return `((SELECT COUNT(*) FROM space_memberships sm WHERE sm.space_id = ${spaceParam})
    + (SELECT COUNT(*) FROM space_invitations pi
        WHERE pi.space_id = ${spaceParam} AND pi.status = 'pending'
          AND pi.expires_at > now()${exclude}))`;
}

/**
 * SQL condition that one more person (a new invitation, or the acceptance of
 * `excludeInvitationParam`, whose own reservation is not counted twice) fits in
 * the Space: its owner is on Plus now, or members plus reservations are below
 * the Free allowance.
 */
export function spaceMemberAdmissionSql(
  spaceParam: string,
  excludeInvitationParam: string | null = null,
): string {
  return `(${paidOwnerSql(`(SELECT so.owner_user_id FROM spaces so WHERE so.id = ${spaceParam})`)}
    OR ${spaceMemberUsageSql(spaceParam, excludeInvitationParam)} < ${FREE_SPACE_MEMBER_LIMIT})`;
}

/** Rejected because a Free-owned Space has no free person slot. */
export class SpaceMemberLimitError extends HttpError {
  readonly code = "space_member_limit_reached";
  constructor(audience: "owner" | "member" = "owner") {
    super(
      402,
      `Free includes up to ${FREE_SPACE_MEMBER_LIMIT} people in each Space, including the owner. ${
        audience === "owner"
          ? "Upgrade to Syntila Plus to allow larger Spaces, or remove a member or invitation."
          : "The Space owner needs to upgrade or free a slot."
      }`,
    );
  }
}

/** True when the admission rule would currently refuse one more person. */
export async function spaceMemberCapacityRefused(
  env: Env,
  spaceId: string,
  excludeInvitationId: string | null = null,
): Promise<boolean> {
  const row = await env.SYNTILA_DB.prepare(
    `SELECT CASE WHEN ${spaceMemberAdmissionSql("?1", excludeInvitationId ? "?2" : null)}
                 THEN 0 ELSE 1 END AS refused`,
  )
    .bind(...(excludeInvitationId ? [spaceId, excludeInvitationId] : [spaceId]))
    .first<{ refused: number }>();
  return row?.refused === 1;
}

export interface SpaceMemberUsage {
  readonly members: number;
  readonly pendingInvitations: number;
  /** People allowed including the owner; null means no subscription-based cap. */
  readonly limit: number | null;
}

export async function getSpaceMemberUsage(
  env: Env,
  spaceId: string,
  now: Date = new Date(),
): Promise<SpaceMemberUsage> {
  const row = await env.SYNTILA_DB.prepare(
    `SELECT (SELECT COUNT(*) FROM space_memberships WHERE space_id = ?1) AS members,
            (SELECT COUNT(*) FROM space_invitations
              WHERE space_id = ?1 AND status = 'pending'
                AND expires_at > ?2::timestamptz) AS pending,
            ap.tier AS tier, ap.status AS status,
            ap.current_period_end AS current_period_end
       FROM spaces s LEFT JOIN account_plans ap ON ap.user_id = s.owner_user_id
      WHERE s.id = ?1`,
  )
    .bind(spaceId, now.toISOString())
    .first<{
      members: number;
      pending: number;
      tier: AccountTier | null;
      status: AccountPlanStatus | null;
      current_period_end: string | null;
    }>();
  const tier = effectiveTier(
    row?.tier && row.status
      ? {
          tier: row.tier,
          status: row.status,
          current_period_end: row.current_period_end,
        }
      : null,
    now,
  );
  return {
    members: row?.members ?? 0,
    pendingInvitations: row?.pending ?? 0,
    limit: spaceMemberLimit(tier),
  };
}

/**
 * Uploaded-file allowances, in decimal bytes (1 GB = 1,000,000,000; 1 MB =
 * 1,000,000). They replace the earlier binary 1 GiB total and 10 MiB per file.
 * Storage is charged to the *uploader's* plan, whatever plan owns the Space,
 * and the 10-attachments-per-submission cap is a separate, plan-free limit.
 */
export const ATTACHMENT_LIMITS = {
  free: { storageBytes: 1_000_000_000, fileBytes: 25_000_000 },
  paid: { storageBytes: 25_000_000_000, fileBytes: 100_000_000 },
} as const satisfies Record<
  AccountTier,
  { storageBytes: number; fileBytes: number }
>;

/** Attachments one message or request may carry (not plan based). */
export const MAX_ATTACHMENTS_PER_SUBMISSION = 10;

export interface AttachmentLimits {
  readonly tier: AccountTier;
  readonly storageBytes: number;
  readonly fileBytes: number;
}

export function attachmentLimits(tier: AccountTier): AttachmentLimits {
  return { tier, ...ATTACHMENT_LIMITS[tier] };
}

/** "25 MB", "1 GB": decimal, matching the byte limits above. */
export function formatDecimalBytes(bytes: number): string {
  if (bytes >= 1_000_000_000)
    return `${+(bytes / 1_000_000_000).toFixed(1)} GB`;
  if (bytes >= 1_000_000) return `${+(bytes / 1_000_000).toFixed(1)} MB`;
  if (bytes >= 1_000) return `${+(bytes / 1_000).toFixed(1)} kB`;
  return `${bytes} bytes`;
}

/** SQL for the uploader's total-storage allowance (decimal bytes). */
export function attachmentStorageQuotaSql(userParam: string): string {
  return `(CASE WHEN ${paidOwnerSql(userParam)}
    THEN ${ATTACHMENT_LIMITS.paid.storageBytes}
    ELSE ${ATTACHMENT_LIMITS.free.storageBytes} END)`;
}

/** SQL for the uploader's individual-file allowance (decimal bytes). */
export function attachmentFileLimitSql(userParam: string): string {
  return `(CASE WHEN ${paidOwnerSql(userParam)}
    THEN ${ATTACHMENT_LIMITS.paid.fileBytes}
    ELSE ${ATTACHMENT_LIMITS.free.fileBytes} END)`;
}

export async function getAttachmentLimits(
  env: Env,
  userId: string,
  now: Date = new Date(),
): Promise<AttachmentLimits> {
  const row = await env.SYNTILA_DB.prepare(
    "SELECT tier, status, current_period_end FROM account_plans WHERE user_id = ?1",
  )
    .bind(userId)
    .first<AccountPlanRow>();
  return attachmentLimits(effectiveTier(row, now));
}

/** The file itself is over the uploader's plan limit (not a full account). */
export class FileTooLargeError extends HttpError {
  readonly code = "file_too_large";
  constructor(limits: AttachmentLimits) {
    super(
      413,
      `This file is larger than the ${formatDecimalBytes(limits.fileBytes)} limit for your plan.`,
    );
  }
}

/** The uploader's total storage allowance has no room for this file. */
export class StorageQuotaExceededError extends HttpError {
  readonly code = "storage_quota_exceeded";
  constructor(limits: AttachmentLimits) {
    super(
      413,
      `Storage is full (${formatDecimalBytes(limits.storageBytes)} on your plan). Delete files in My Files to free space.`,
    );
  }
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
  /** Authoritative upload limits for this account (decimal bytes). */
  readonly attachments: {
    readonly maxFiles: number;
    readonly maxFileBytes: number;
    readonly storageBytes: number;
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
           OR ap.current_period_end > now()))`;
}

/**
 * SQL condition that the Workspace owner column currently holds the custom
 * plugin entitlement (ADR-027). It is `paidOwnerSql`, named for its purpose so
 * every plugin call site reads the same and a feature split later changes one
 * place. Evaluated live, so a lapse by `current_period_end` needs no event.
 */
export function pluginOwnerEntitledSql(ownerColumn: string): string {
  return paidOwnerSql(ownerColumn);
}

/**
 * Admission condition for an assignment INSERT: the Worker is not a plugin, or
 * its Workspace owner holds the plugin entitlement right now. Evaluated in the
 * same statement as the write, so a plan that expires between scheduling and
 * admission admits nothing.
 */
export function pluginAssignmentAdmissionSql(
  workerTypeParam: string,
  workspaceParam: string,
): string {
  return `(NOT EXISTS (SELECT 1 FROM worker_catalog wc
                        WHERE wc.worker_type_id = ${workerTypeParam}
                          AND wc.origin = 'plugin')
    OR ${pluginOwnerEntitledSql(
      `(SELECT pw.owner_user_id FROM execution_workspaces pw WHERE pw.id = ${workspaceParam})`,
    )})`;
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
    attachments: {
      maxFiles: MAX_ATTACHMENTS_PER_SUBMISSION,
      maxFileBytes: ATTACHMENT_LIMITS[tier].fileBytes,
      storageBytes: ATTACHMENT_LIMITS[tier].storageBytes,
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
