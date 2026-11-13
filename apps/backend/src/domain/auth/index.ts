/** Authentication runs in the Cloudflare auth Worker; the backend only rejects these routes. */
export async function handleBetterAuthRequest(_request: Request, _env?: unknown): Promise<Response> {
  return Response.json({ error: "Authentication is handled by the Syntila auth service", code: "auth_moved" }, { status: 404 });
}
export {
  IdentityService,
  identityService,
  type AuthenticatedIdentity,
} from "./identity-service.js";
export {
  provisionSyntilaUser,
  type ProvisioningDatabase,
} from "./provisioning-service.js";
export {
  SENSITIVE_OPERATIONS,
  STEP_UP_REQUIREMENTS,
  isStepUpSatisfied,
  type SensitiveOperation,
  type StepUpMethod,
  type StepUpRecord,
} from "./step-up.js";
export {
  recordAuthAuditEvent,
  recordAuthMetric,
  safeAuthProvider,
  safeAuthReason,
  type AuthAuditAction,
  type AuthAuditEvent,
  type AuthAuditOutcome,
} from "./observability.js";
