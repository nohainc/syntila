import 'dart:convert';

import '../tool_profile_v1.dart';

enum ToolProfileResolutionSource {
  active,
  stable,
  lastKnownGood,
  draft,
  unavailable,
}

enum ToolProfileUnavailableReason {
  noEligibleRelease,
  incompatibleEngineVersion,
}

class ToolProfileResolution<T extends ToolProfileCandidate> {
  const ToolProfileResolution._({
    required this.source,
    this.release,
    this.reason,
  });

  const ToolProfileResolution.selected({
    required ToolProfileResolutionSource source,
    required T release,
  }) : this._(source: source, release: release);

  const ToolProfileResolution.unavailable(ToolProfileUnavailableReason reason)
      : this._(source: ToolProfileResolutionSource.unavailable, reason: reason);

  final ToolProfileResolutionSource source;
  final T? release;
  final ToolProfileUnavailableReason? reason;

  bool get isAvailable => release != null;
}

/// Common resolution and compatibility matcher used by Connect and Profile Lab.
abstract final class ToolProfileCompatibility {
  /// Selects and materializes the single matching provider-version override.
  /// The structural validator rejects overlap before this method is called.
  static EngineProfile resolveForProviderVersion(
    EngineProfile profile,
    String providerCliVersion,
  ) =>
      profile.resolveForProviderVersion(providerCliVersion);

  /// Recommends a narrow minor-line range starting at the version actually
  /// discovered and tested. Older versions are never inferred as compatible.
  static Map<String, String>? recommendedProviderRange(String testedVersion) {
    if (!isSemanticVersion(testedVersion)) return null;
    final match = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)',
    ).firstMatch(testedVersion);
    if (match == null) return null;
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    if (minor == 999999999) return null;
    return {'min': testedVersion, 'maxExclusive': '$major.${minor + 1}.0'};
  }

  /// Identifies the legacy near-universal range used as a placeholder.
  static bool hasPlaceholderProviderRange(EngineProfile profile) {
    final ranges = profile.providerTool['supportedVersions'];
    if (ranges is! List) return false;
    return ranges.any((value) {
      if (value is! Map ||
          value['min'] is! String ||
          value['maxExclusive'] is! String) {
        return false;
      }
      try {
        return compareSemanticVersions(value['min'] as String, '1.0.0') <= 0 &&
            compareSemanticVersions(
                  value['maxExclusive'] as String,
                  '50.0.0',
                ) >=
                0;
      } on FormatException {
        return false;
      }
    });
  }

  static bool isEngineCompatible(EngineProfile profile, String engineVersion) {
    try {
      return engineVersionCompatible(profile, engineVersion);
    } on Object {
      return false;
    }
  }

  static bool isCandidateCompatible({
    required ToolProfileCandidate candidate,
    required String logicalWorkerTypeId,
    required String profileDefinitionId,
    required String engineVersion,
  }) {
    if (candidate.logicalWorkerTypeId != logicalWorkerTypeId ||
        candidate.profileDefinitionId != profileDefinitionId) {
      return false;
    }
    try {
      final profile = EngineProfile.parse(
        utf8.encode(canonicalJson(candidate.profile)),
      );
      // Provider CLI versions are not a compatibility gate: a Profile supports
      // every CLI version. Overrides use their own providerVersion ranges.
      return isEngineCompatible(profile, engineVersion);
    } on Object {
      return false;
    }
  }
}
