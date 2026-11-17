export type AuthAuditOutcome = "success" | "failure" | "denied";

export type AuthAuditAction =
  | "auth.sign_in"
  | "auth.sign_in_failure"
  | "auth.logout"
  | "auth.session.revoked"
  | "auth.provider.linked"
  | "auth.provider.unlinked"
  | "auth.passkey.enrolled"
  | "auth.passkey.removed"
  | "auth.step_up.completed"
  | "auth.authorization.denied"
  | "auth.invitation.accepted"
  | "auth.email.changed";

const PROVIDERS = new Set(["github", "google", "passkey", "totp"]);
const REASONS = new Set([
  "invalid_credentials",
  "invalid_callback",
  "expired_session",
  "revoked_session",
  "csrf_rejected",
  "not_authenticated",
  "not_authorized",
  "suspended_user",
  "removed_member",
  "invalid_workspace",
  "invalid_space",
  "unknown",
]);

export function safeAuthProvider(value: unknown): string | undefined {
  return typeof value === "string" && PROVIDERS.has(value) ? value : undefined;
}

export function safeAuthReason(value: unknown): string {
  return typeof value === "string" && REASONS.has(value) ? value : "unknown";
}

export type AuthAuditEvent = {
  action: AuthAuditAction;
  outcome: AuthAuditOutcome;
  userId?: string | null;
  sessionId?: string | null;
  workspaceId?: string | null;
  provider?: string;
  reason?: string;
  operation?: string;
};

/**
 * Authentication events may occur before a Workspace is selected. Keep them
 * in a separate, globally queryable table and only persist an allow-listed
 * metadata shape. Tokens, cookies, OAuth responses and credential material
 * never enter this record.
 */
export async function recordAuthAuditEvent(
  db: D1Database,
  event: AuthAuditEvent,
): Promise<void> {
  const details: Record<string, string> = {};
  const provider = safeAuthProvider(event.provider);
  if (provider) details.provider = provider;
  if (event.reason) details.reason = safeAuthReason(event.reason);
  if (event.operation && /^[a-z0-9._-]{1,80}$/.test(event.operation)) {
    details.operation = event.operation;
  }
  if (event.workspaceId && /^[a-zA-Z0-9._:-]{1,120}$/.test(event.workspaceId)) {
    details.workspaceId = event.workspaceId;
  }
  await db
    .prepare(
      `INSERT INTO auth_audit_events
         (id, user_id, session_id, action, outcome, details_json, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
    )
    .bind(
      `auth-audit-${crypto.randomUUID()}`,
      event.userId ?? null,
      event.sessionId ?? null,
      event.action,
      event.outcome,
      JSON.stringify(details),
      new Date().toISOString(),
    )
    .run();
}

/** Structured edge log suitable for metrics aggregation; never include identity or token data. */
export function recordAuthMetric(
  provider: unknown,
  outcome: "success" | "failure",
  reason?: unknown,
): void {
  const payload = {
    metric: "syntila.auth.sign_in",
    provider: safeAuthProvider(provider) ?? "unknown",
    outcome,
    ...(outcome === "failure" ? { reason: safeAuthReason(reason) } : {}),
  };
  (outcome === "failure" ? console.warn : console.info)(
    JSON.stringify(payload),
  );
}
