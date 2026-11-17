import 'dart:convert';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:test/test.dart';

Map<String, Object?> validProfileMap({
  String profileDefinitionId = 'chatgpt-codex',
  int releaseVersion = 10,
  String logicalWorkerTypeId = 'chatgpt',
  String providerToolName = 'codex',
}) =>
    {
      'schemaVersion': 1,
      'profileDefinitionId': profileDefinitionId,
      'releaseVersion': releaseVersion,
      'logicalWorkerTypeId': logicalWorkerTypeId,
      'engineFamily': 'cli',
      'engineCompatibility': {'min': '1.0.0', 'maxExclusive': '2.0.0'},
      'providerTool': {
        'name': providerToolName,
        'executableCandidates': [providerToolName],
        'discovery': {'standardLocations': [], 'allowPathSearch': true},
        'versionProbe': {
          'arguments': ['--version'],
          'timeoutMs': 10000,
          'source': 'stdout',
          'extract': {'kind': 'regex_capture', 'patternId': 'semver'}
        },
        'supportedVersions': [
          {'min': '0.1.0', 'maxExclusive': '1.0.0'}
        ],
      },
      'environment': {
        'passthrough': ['PATH', 'HOME'],
        'set': {}
      },
      'probe': {
        'passive': {
          'checks': [
            {
              'id': 'auth',
              'arguments': ['probe'],
              'timeoutMs': 5000,
              'successExitCodes': [0],
              'failureIssueCode': 'provider_authentication_required'
            }
          ],
          'configChecks': []
        }
      },
      'execution': {
        'arguments': ['run', '{{prompt}}'],
        'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
        'output': {'mode': 'plain_text'},
        'events': []
      },
      'session': {
        'supported': false,
        'formatId': 'fixture-session-v1',
        'compatibleFormatIds': ['fixture-session-v1'],
        'resumeArguments': [],
        'requireObservedIdMatch': false
      },
      'model': {
        'supported': false,
        'arguments': [],
        'unknownModelPolicy': 'pass_through'
      },
      'timeout': {'providerArguments': [], 'providerReserveMs': 0},
      'sandbox': {
        'mappings': {
          'restricted': [],
          'provider_default': [],
          'full_access': []
        }
      },
      'progress': [],
      'errors': {
        'mappings': [
          {
            'evidence': {'kind': 'exit_code', 'value': 2},
            'issueCode': 'provider_failure'
          }
        ]
      },
      'compatibilityOverrides': []
    };

void main() {
  group('Tool Profile Release & Candidate Primitives', () {
    test('validates provider failure extraction selectors', () {
      final profile = validProfileMap();
      final execution = profile['execution'] as Map<String, Object?>;
      execution['failureExtraction'] = {
        'providerErrorText': r'$.result.error',
        'failedRunResponse': r'$.result.response',
        'source': 'structured_error',
      };
      expect(() => EngineProfile.parse(utf8.encode(canonicalJson(profile))),
          returnsNormally);
      execution['failureExtraction'] = {'nativeErrorCode': 'invalid'};
      expect(() => EngineProfile.parse(utf8.encode(canonicalJson(profile))),
          throwsFormatException);
    });
    test('Profiles omit CLI ranges without changing the candidate payload', () {
      final profile = validProfileMap();
      (profile['providerTool'] as Map).remove('supportedVersions');
      final parsed = EngineProfile.parse(utf8.encode(canonicalJson(profile)));
      expect(parsed.providerTool.containsKey('supportedVersions'), isFalse);
      expect(
          parsed
              .resolveForProviderVersion('99.0.0')
              .providerTool
              .containsKey('supportedVersions'),
          isFalse);
    });

    test('incomplete provider ranges are valid Draft state only', () async {
      final profile = validProfileMap();
      (profile['providerTool'] as Map<String, Object?>)['supportedVersions'] =
          <Map<String, String>>[];
      final parsed = EngineProfile.parse(
        utf8.encode(canonicalJson(profile)),
      );
      expect(parsed.providerTool['supportedVersions'], isEmpty);
      expect(
        ToolProfileCompatibility.recommendedProviderRange('0.187.2'),
        {'min': '0.187.2', 'maxExclusive': '0.188.0'},
      );
      expect(
        ToolProfileCompatibility.recommendedProviderRange('1.4.0-beta.1'),
        {'min': '1.4.0-beta.1', 'maxExclusive': '1.5.0'},
      );
    });

    test('legacy capability metadata is rejected', () {
      final profile = validProfileMap()..['capabilities'] = ['text'];
      expect(
        () => EngineProfile.parse(utf8.encode(canonicalJson(profile))),
        throwsA(isA<FormatException>()),
      );
    });

    test('legacy near-universal provider range is identified as placeholder',
        () {
      final profile = validProfileMap();
      (profile['providerTool'] as Map<String, Object?>)['supportedVersions'] = [
        {'min': '0.0.1', 'maxExclusive': '99.0.0'},
      ];
      expect(
        ToolProfileCompatibility.hasPlaceholderProviderRange(
          EngineProfile.parse(utf8.encode(canonicalJson(profile))),
        ),
        isTrue,
      );
    });

    test(
        'LocalDraftProfileCandidate computes canonical digest and identifies as unpublished',
        () {
      final sampleProfile = validProfileMap();

      final candidate =
          LocalDraftProfileCandidate.fromProfileMap(sampleProfile);
      expect(candidate.isPublished, isFalse);
      expect(candidate.profileDefinitionId, 'chatgpt-codex');
      expect(candidate.releaseVersion, 10);
      expect(candidate.logicalWorkerTypeId, 'chatgpt');
      expect(candidate.providerToolName, 'codex');
      expect(candidate.payloadDigest.length, 64);
    });

    test('ToolProfileReleaseIdentity equality and string representation', () {
      const id1 = ToolProfileReleaseIdentity(
        profileDefinitionId: 'chatgpt-codex',
        releaseVersion: 12,
      );
      const id2 = ToolProfileReleaseIdentity(
        profileDefinitionId: 'chatgpt-codex',
        releaseVersion: 12,
      );
      const id3 = ToolProfileReleaseIdentity(
        profileDefinitionId: 'chatgpt-codex',
        releaseVersion: 13,
      );

      expect(id1, equals(id2));
      expect(id1.hashCode, equals(id2.hashCode));
      expect(id1, isNot(equals(id3)));
      expect(id1.toString(), 'chatgpt-codex@12');
    });

    test('ToolProfileCompatibility checks engine version bounds', () {
      final sampleProfile = validProfileMap();

      final profile =
          EngineProfile.parse(utf8.encode(canonicalJson(sampleProfile)));

      expect(ToolProfileCompatibility.isEngineCompatible(profile, '1.2.0'),
          isTrue);
      expect(ToolProfileCompatibility.isEngineCompatible(profile, '2.0.0'),
          isFalse);
      expect(ToolProfileCompatibility.isEngineCompatible(profile, '0.9.0'),
          isFalse);
    });

    test('provider compatibility overrides resolve deterministically', () {
      final sampleProfile = validProfileMap();
      sampleProfile['compatibilityOverrides'] = [
        {
          'providerVersion': {'min': '0.4.0', 'maxExclusive': '0.6.0'},
          'executionArguments': ['override', '{{prompt}}'],
          'versionProbeArguments': ['--version', '--machine'],
          'progress': [],
          'errorMappings': (sampleProfile['errors'] as Map)['mappings'],
        }
      ];
      final profile = EngineProfile.parse(
        utf8.encode(canonicalJson(sampleProfile)),
      );
      final resolved = profile.resolveForProviderVersion('0.5.0');
      expect(resolved.execution['arguments'], ['override', '{{prompt}}']);
      expect(resolved.providerTool['versionProbe'],
          containsPair('arguments', ['--version', '--machine']));
      expect(resolved.json['compatibilityOverrides'], isEmpty);
      // A version outside every supported range uses the base Profile.
      final outside = profile.resolveForProviderVersion('1.0.0');
      expect(outside.execution['arguments'], isNot(['override', '{{prompt}}']));
      expect(identical(outside, profile), isTrue);
    });

    test('compatibility override unknown fields are rejected', () {
      final sampleProfile = validProfileMap();
      sampleProfile['compatibilityOverrides'] = [
        {
          'providerVersion': {'min': '0.4.0', 'maxExclusive': '0.6.0'},
          'unknown': true,
        }
      ];
      expect(
        () => EngineProfile.parse(utf8.encode(canonicalJson(sampleProfile))),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
