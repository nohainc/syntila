/// Wire and runtime limits from `WORKER_PLUGIN_PROTOCOL_V1.md`. Values that
/// also exist in the Local Worker Protocol equal `WorkerProtocolLimits`.
abstract final class ExternalWorkerLimits {
  static const protocolVersion = '1.2';
  static const supportedProtocolVersions = <String>{'1.2', '1.1', '1.0'};

  static const maxFrameBytes = 1024 * 1024;
  static const maxPromptBytes = 512 * 1024;
  static const maxOutputBytes = 768 * 1024;
  static const maxProgressMessageLength = 2048;
  static const maxErrorMessageLength = 2048;
  static const maxCheckMessageLength = 1024;
  static const maxChecks = 32;
  static const maxArtifacts = 64;
  static const maxPathLength = 256;
  static const maxModelLength = 128;
  static const maxModels = 128;
  static const maxProbeTimeoutMs = 30 * 1000;

  static const handshakeTimeout = Duration(seconds: 10);
  static const cancelGrace = Duration(seconds: 5);
  static const shutdownGrace = Duration(seconds: 3);
}

/// Error codes a plugin may send. Others normalize to `internal`.
const externalWorkerErrorCodes = <String>{
  'invalid_request',
  'context_limit_exceeded',
  'cancelled',
  'timeout',
  'not_ready',
  'sign_in_required',
  'unsupported_policy',
  'session_not_found',
  'model_unavailable',
  'session_commit_failed',
  'rate_limited',
  'output_too_large',
  'unsupported_frame',
  'unsupported_protocol',
  'internal',
};

/// Host-side failure codes (never sent by a plugin).
abstract final class ExternalWorkerHostFailure {
  static const protocolViolation = 'plugin_protocol_violation';
  static const protocolUnsupported = 'plugin_protocol_unsupported';
  static const identityMismatch = 'plugin_identity_mismatch';
  static const crashed = 'plugin_crashed';
  static const artifactPathInvalid = 'plugin_artifact_path_invalid';
  static const digestMismatch = 'plugin_digest_mismatch';
}
