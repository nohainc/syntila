import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

const profileLabProductionCloudOrigin = 'https://app.syntila.app';
const profileLabLocalCloudOrigin = 'http://localhost:8787';

/// Environment-derived Cloud default and the origin policy shared by clients.
class ProfileLabCloudConfig {
  static const _environmentOrigin = String.fromEnvironment(
    'SYNTILA_CLOUD_URL',
    defaultValue: profileLabProductionCloudOrigin,
  );

  /// Build-time target, set by the build scripts with
  /// `--dart-define=SYNTILA_PROFILE_LAB_ENVIRONMENT=local|production`.
  /// A build talks to exactly one Cloud; local builds are pinned to the local
  /// API and ignore any saved override or `SYNTILA_CLOUD_URL`.
  static const environment = String.fromEnvironment(
    'SYNTILA_PROFILE_LAB_ENVIRONMENT',
    defaultValue: 'production',
  );
  static const isLocalBuild = environment == 'local';

  static String get buildDefaultOrigin => normalizeOrigin(
        isLocalBuild ? profileLabLocalCloudOrigin : _environmentOrigin,
      );

  static String normalizeOrigin(String value, {bool? allowInsecureLoopback}) {
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null ||
        !const {'http', 'https'}.contains(parsed.scheme.toLowerCase()) ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        (parsed.path.isNotEmpty && parsed.path != '/') ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      throw ArgumentError('Cloud URL must be an origin without a path.');
    }

    final secure = parsed.scheme.toLowerCase() == 'https';
    final loopback = const {'localhost', '127.0.0.1', '::1'}
        .contains(parsed.host.toLowerCase());
    // Local builds are release-mode bundles that talk to the local API, so
    // they may use loopback HTTP. Production builds never can.
    final allowLocalHttp =
        allowInsecureLoopback ?? (!kReleaseMode || isLocalBuild);
    if (!secure && (!loopback || !allowLocalHttp)) {
      throw ArgumentError(
        'Cloud must use HTTPS. HTTP is allowed only for loopback in development builds.',
      );
    }

    return Uri(
      scheme: parsed.scheme.toLowerCase(),
      host: parsed.host.toLowerCase(),
      port: parsed.hasPort ? parsed.port : null,
    ).origin;
  }
}

/// Stores a non-secret Cloud origin override in Profile Lab application data.
class ProfileLabCloudSettingsStore {
  ProfileLabCloudSettingsStore(this.file);

  final File file;

  Future<String?> loadOverride() async {
    if (!await file.exists()) return null;
    try {
      if (await file.length() > 4096) throw const FormatException();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          decoded['schemaVersion'] != 1 ||
          decoded['cloudOrigin'] is! String) {
        throw const FormatException();
      }
      return ProfileLabCloudConfig.normalizeOrigin(
        decoded['cloudOrigin'] as String,
      );
    } on Object {
      await clearOverride();
      return null;
    }
  }

  Future<void> saveOverride(String origin) async {
    final normalized = ProfileLabCloudConfig.normalizeOrigin(origin);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'schemaVersion': 1, 'cloudOrigin': normalized}),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<void> clearOverride() async {
    if (await file.exists()) await file.delete();
  }
}
