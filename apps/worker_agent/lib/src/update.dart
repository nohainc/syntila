import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'identity.dart';

class UpdateRejectedException implements Exception {
  UpdateRejectedException(this.reason);
  final String reason;

  @override
  String toString() => 'update rejected: $reason';
}

class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.channel,
    required this.url,
    required this.sha256,
    required this.signature,
  });

  final String version;
  final String channel;
  final String url;
  final String sha256;
  final String signature;

  /// The signed text. A domain prefix keeps this signature from being valid
  /// for any other purpose.
  String get signedText =>
      'syntila-worker-update/v1\n$version\n$channel\n$sha256\n$url';

  factory UpdateManifest.fromJson(Map<String, Object?> json) {
    for (final key in ['version', 'channel', 'url', 'sha256', 'signature']) {
      if (json[key] is! String || (json[key] as String).isEmpty) {
        throw UpdateRejectedException('the manifest has no $key');
      }
    }
    return UpdateManifest(
      version: json['version'] as String,
      channel: json['channel'] as String,
      url: json['url'] as String,
      sha256: json['sha256'] as String,
      signature: json['signature'] as String,
    );
  }
}

/// Release public keys compiled in with `--define=SYNTILA_UPDATE_KEYS=k1,k2`.
/// With none configured every update is refused.
List<String> compiledUpdateKeys() => const String.fromEnvironment(
  'SYNTILA_UPDATE_KEYS',
).split(',').where((k) => k.isNotEmpty).toList();

int _part(String text) => int.tryParse(text) ?? -1;

/// True when [candidate] is a higher dotted version than [current].
bool isNewerVersion(String current, String candidate) {
  final a = current.split('.').map(_part).toList();
  final b = candidate.split('.').map(_part).toList();
  if (b.any((v) => v < 0)) return false;
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (y != x) return y > x;
  }
  return false;
}

/// Verifies signed updates before anything is written. It refuses an
/// unsigned or wrongly signed manifest, a download whose hash differs and any
/// version that is not newer (no downgrade).
class UpdateVerifier {
  UpdateVerifier(this.trustedKeys);

  final List<String> trustedKeys;

  Future<void> verifyManifest(
    UpdateManifest manifest, {
    required String currentVersion,
  }) async {
    if (trustedKeys.isEmpty) {
      throw UpdateRejectedException('no release key is configured');
    }
    var signed = false;
    for (final key in trustedKeys) {
      if (await verifyMessage(key, manifest.signedText, manifest.signature)) {
        signed = true;
        break;
      }
    }
    if (!signed) throw UpdateRejectedException('the signature is not valid');
    if (!isNewerVersion(currentVersion, manifest.version)) {
      throw UpdateRejectedException('the version is not newer');
    }
    if (!manifest.url.startsWith('https://')) {
      throw UpdateRejectedException('the download must use https');
    }
  }

  void verifyArtifact(UpdateManifest manifest, List<int> bytes) {
    if (sha256.convert(bytes).toString() != manifest.sha256.toLowerCase()) {
      throw UpdateRejectedException('the download does not match its hash');
    }
  }

  /// Verifies, then writes the artifact atomically into [directory]. The
  /// running executable is not replaced here; the service manager restarts the
  /// Agent from the staged file.
  Future<File> stage(
    UpdateManifest manifest,
    List<int> bytes,
    Directory directory, {
    required String currentVersion,
  }) async {
    await verifyManifest(manifest, currentVersion: currentVersion);
    verifyArtifact(manifest, bytes);
    await directory.create(recursive: true);
    final target = File('${directory.path}/syntila-worker-${manifest.version}');
    final temp = File('${target.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
    await File('${directory.path}/pending-update.json').writeAsString(
      jsonEncode({'version': manifest.version, 'file': target.path}),
      flush: true,
    );
    return target;
  }
}
