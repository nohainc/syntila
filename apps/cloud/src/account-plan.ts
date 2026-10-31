import { HttpError } from "./routes/http-security.js";

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

export interface AccountPlan {
  /** The tier the person is entitled to right now. */
  readonly tier: AccountTier;
  /** Subscription status, or null when the person never had a paid plan. */
  readonly status: AccountPlanStatus | null;
  readonly currentPeriodEnd: string | null;
  readonly features: readonly PaidFeature[];
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
