import 'dart:async';

import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';

import 'cli_command_runner.dart';

final class ProfileVersionProbeResult {
  const ProfileVersionProbeResult({
    required this.exitCode,
    required this.version,
    this.output = '',
  });

  final int exitCode;
  final String? version;

  /// The probe's configured output stream, trimmed and capped at 200
  /// characters. Profile Lab only checks that the CLI answered.
  final String output;
}

/// Executes and interprets a provider version probe using its Tool Profile.
///
/// This is shared by the CLI Worker Engine and Profile Lab so local
/// qualification and Connect readiness apply the same command, timeout,
/// output-source, and extraction rules. The detected version is informational
/// and selects version-specific overrides; it never rejects a CLI.
abstract final class ProfileVersionProbe {
  static Map<String, String> buildContext({
    required EngineProfile profile,
    required String workingDirectory,
    required String homeDirectory,
    required String workerStateDirectory,
  }) {
    final probe = _map(profile.providerTool['versionProbe']);
    final timeoutMs = _int(probe['timeoutMs']);
    final providerReserveMs = _int(profile.timeout['providerReserveMs']);
    final providerTimeoutMs = (timeoutMs - providerReserveMs).clamp(
      1,
      timeoutMs,
    );
    return {
      'prompt': 'version probe',
      'workingDirectory': workingDirectory,
      'home': homeDirectory,
      'workerStateDirectory': workerStateDirectory,
      'timeoutMs': '$providerTimeoutMs',
      'timeoutSeconds': '${(providerTimeoutMs / 1000).ceil()}',
    };
  }

  static Future<ProfileVersionProbeResult> run({
    required EngineProfile profile,
    required String executable,
    required CliCommandRunner commandRunner,
    required Map<String, String> environment,
    required String workingDirectory,
    required Map<String, String> context,
    Duration deadline = const Duration(seconds: 30),
  }) async {
    final spec = _map(profile.providerTool['versionProbe']);
    final configuredTimeout = Duration(milliseconds: _int(spec['timeoutMs']));
    if (deadline < const Duration(milliseconds: 1)) {
      throw TimeoutException('Version probe exceeded its deadline', deadline);
    }
    final timeout = deadline < configuredTimeout ? deadline : configuredTimeout;
    final result = await commandRunner.run(
      executable,
      _strings(spec['arguments'])
          .map((argument) => _resolveTemplate(argument, context))
          .toList(growable: false),
      environment: environment,
      workingDirectory: workingDirectory,
      timeout: timeout,
    );

    final source = switch (spec['source']) {
      'stdout' => result.stdout,
      'stderr' => result.stderr,
      _ => throw const FormatException('unsupported version probe source'),
    };
    final extract = _map(spec['extract']);
    final version = result.exitCode == 0
        ? _extractVersion(source, extract)
        : null;
    return ProfileVersionProbeResult(
      exitCode: result.exitCode,
      version: version,
      output: () {
        final trimmed = source.trim();
        return trimmed.length > 200 ? trimmed.substring(0, 200) : trimmed;
      }(),
    );
  }

  static String? _extractVersion(String output, Map<String, Object?> extract) {
    if (extract['kind'] != 'regex_capture' ||
        extract['patternId'] != 'semver') {
      throw const FormatException('unsupported version extraction rule');
    }
    final match = RegExp(
      r'(?<![A-Za-z0-9])v?((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)(?![A-Za-z0-9])',
    ).firstMatch(output);
    final version = match?.group(1);
    return version != null && isSemanticVersion(version) ? version : null;
  }

  static String _resolveTemplate(String value, Map<String, String> context) {
    final placeholders = RegExp(r'\{\{([^{}]+)\}\}');
    final scrubbed = value.replaceAll(placeholders, '');
    if (RegExp(r'\{\{|\}\}').hasMatch(scrubbed)) {
      throw const FormatException('malformed Profile placeholder');
    }
    return value.replaceAllMapped(placeholders, (match) {
      final key = match.group(1)!;
      final result = context[key];
      if (result == null) {
        throw FormatException('Profile placeholder is unavailable: $key');
      }
      return result;
    });
  }

  static Map<String, Object?> _map(Object? value) => value is Map
      ? Map<String, Object?>.from(value)
      : throw const FormatException('expected Profile object');

  static List<String> _strings(Object? value) => value is List
      ? value
            .map(
              (item) => item is String
                  ? item
                  : throw const FormatException('expected Profile string'),
            )
            .toList()
      : throw const FormatException('expected Profile array');

  static int _int(Object? value) => value is int
      ? value
      : throw const FormatException('expected Profile integer');
}
