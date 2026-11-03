import 'dart:convert';

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

/// Build-injected public keys for plugin entitlement leases (ADR-027). They are
/// separate from release keys. Empty or invalid configuration trusts nothing.
Map<String, Map<String, String>> workspaceEntitlementTrustKeys() {
  const configured = String.fromEnvironment(
    'SYNTILA_ENTITLEMENT_TRUST_KEYS_JSON',
    defaultValue: '{}',
  );
  try {
    final decoded = jsonDecode(configured);
    if (decoded is! Map) return const {};
    return {
      for (final entry in decoded.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: {
            for (final key in (entry.value as Map).entries)
              if (key.key is String && key.value is String)
                key.key as String: key.value as String,
          },
    };
  } on Object {
    return const {};
  }
}
