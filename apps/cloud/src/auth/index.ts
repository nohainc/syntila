export {
  buildBetterAuthOptions,
  copySetCookieHeaders,
  createBetterAuth,
  handleBetterAuthRequest,
  configuredAppOrigin,
  isSocialProviderConfigured,
  safeAuthReturnTo,
  type BetterAuthRuntimeEnv,
  type SocialProviderId,
} from "./better-auth.js";
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
