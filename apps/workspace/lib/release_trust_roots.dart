import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';

/// Build-injected public release roots. Empty or invalid configuration fails
/// closed because no signing key is trusted.
Map<String, Map<String, String>> workspaceReleaseTrustRoots() {
  const configured = String.fromEnvironment(
    'SYNTILA_RELEASE_TRUST_KEYS_JSON',
    defaultValue: '{}',
  );
  return ReleaseTrustRoots.parse(configured);
}

WorkerTrustPolicy workspaceReleaseTrustPolicy() =>
    ReleaseTrustRoots.createPolicy(const String.fromEnvironment(
      'SYNTILA_RELEASE_TRUST_KEYS_JSON',
      defaultValue: '{}',
    ));
