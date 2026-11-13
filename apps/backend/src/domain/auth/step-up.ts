export const SENSITIVE_OPERATIONS = {
  workspaceOwnershipTransfer: "workspace.ownership.transfer",
  billingSecurityChange: "billing.security.change",
  toolProfileStablePromotion: "tool_profile.stable_promotion",
  toolProfileRollback: "tool_profile.rollback",
} as const;

export type SensitiveOperation =
  (typeof SENSITIVE_OPERATIONS)[keyof typeof SENSITIVE_OPERATIONS];

export type StepUpMethod = "passkey" | "totp";

export interface StepUpRecord {
  readonly user_id: string;
  readonly session_id: string;
  readonly method: StepUpMethod;
  readonly authenticated_at: string;
  readonly expires_at: string;
}

export interface StepUpRequirement {
  readonly maxAgeMs: number;
  readonly methods: readonly StepUpMethod[];
}

export const STEP_UP_REQUIREMENTS: Record<
  SensitiveOperation,
  StepUpRequirement
> = {
  [SENSITIVE_OPERATIONS.workspaceOwnershipTransfer]: {
    maxAgeMs: 10 * 60 * 1000,
    methods: ["passkey", "totp"],
  },
  [SENSITIVE_OPERATIONS.billingSecurityChange]: {
    maxAgeMs: 5 * 60 * 1000,
    methods: ["passkey", "totp"],
  },
  [SENSITIVE_OPERATIONS.toolProfileStablePromotion]: {
    maxAgeMs: 5 * 60 * 1000,
    methods: ["passkey"],
  },
  [SENSITIVE_OPERATIONS.toolProfileRollback]: {
    maxAgeMs: 5 * 60 * 1000,
    methods: ["passkey"],
  },
};

export function isStepUpSatisfied(
  record: StepUpRecord | null,
  operation: SensitiveOperation,
  now = new Date(),
): boolean {
  if (!record) return false;
  const requirement = STEP_UP_REQUIREMENTS[operation];
  if (!requirement.methods.includes(record.method)) return false;
  const authenticatedAt = Date.parse(record.authenticated_at);
  const expiresAt = Date.parse(record.expires_at);
  const current = now.getTime();
  return (
    Number.isFinite(authenticatedAt) &&
    Number.isFinite(expiresAt) &&
    authenticatedAt <= current &&
    current - authenticatedAt <= requirement.maxAgeMs &&
    current < expiresAt
  );
}

export async function hasRecentStepUp(
  db: {
    prepare(query: string): {
      bind(...values: unknown[]): {
        first<T>(): Promise<T | null>;
      };
    };
  },
  userId: string,
  sessionId: string,
  operation: SensitiveOperation,
  now = new Date(),
): Promise<boolean> {
  const record = await db
    .prepare(
      `SELECT user_id, session_id, method, authenticated_at, expires_at
       FROM auth_step_up_sessions
       WHERE user_id = ?1 AND session_id = ?2
       ORDER BY authenticated_at DESC LIMIT 1`,
    )
    .bind(userId, sessionId)
    .first<StepUpRecord>();
  return isStepUpSatisfied(record, operation, now);
}
