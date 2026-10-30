/// Stable, provider-neutral issue codes carried by Worker protocol frames.
abstract final class WorkerIssueCode {
  static const malformedFrame = 'malformed_frame';
  static const protocolVersionUnsupported = 'protocol_version_unsupported';
  static const workerTypeMismatch = 'worker_type_mismatch';
  @Deprecated('Migration-only Worker Runtime v2 issue code')
  static const workerVersionMismatch = 'worker_version_mismatch';
  @Deprecated('Migration-only Worker Runtime v2 issue code')
  static const stateSchemaIncompatible = 'state_schema_incompatible';
  static const engineVersionMismatch = 'engine_version_mismatch';
  static const profileIdentityMismatch = 'profile_identity_mismatch';
  static const profileSchemaIncompatible = 'profile_schema_incompatible';
  static const deadlineExceeded = 'deadline_exceeded';
  static const cancelled = 'cancelled';
  static const providerToolUnavailable = 'provider_tool_unavailable';
  static const providerAuthenticationRequired =
      'provider_authentication_required';
  static const unsupportedProviderToolVersion =
      'unsupported_provider_tool_version';
  static const modelNotSupported = 'model_not_supported';
  static const quotaExhausted = 'quota_exhausted';
  static const providerUnavailable = 'provider_unavailable';
  static const sessionResumeFailed = 'session_resume_failed';
  static const contextLimitExceeded = 'context_limit_exceeded';
  static const permissionDenied = 'permission_denied';
  static const providerFailure = 'provider_failure';
  static const workerInternalFailure = 'worker_internal_failure';

  static const known = {
    malformedFrame,
    protocolVersionUnsupported,
    workerTypeMismatch,
    workerVersionMismatch,
    stateSchemaIncompatible,
    engineVersionMismatch,
    profileIdentityMismatch,
    profileSchemaIncompatible,
    deadlineExceeded,
    cancelled,
    providerToolUnavailable,
    providerAuthenticationRequired,
    unsupportedProviderToolVersion,
    modelNotSupported,
    quotaExhausted,
    providerUnavailable,
    sessionResumeFailed,
    contextLimitExceeded,
    permissionDenied,
    providerFailure,
    workerInternalFailure,
  };

  static bool isKnown(String value) => known.contains(value);
}
