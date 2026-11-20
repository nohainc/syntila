import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'identity.dart';
import 'paths.dart';

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
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(current) ||
      !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(candidate)) {
    return false;
  }
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
    final uri = Uri.tryParse(manifest.url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw UpdateRejectedException('the download must use https');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(manifest.sha256)) {
      throw UpdateRejectedException('the artifact digest is invalid');
    }
  }

  void verifyArtifact(UpdateManifest manifest, List<int> bytes) {
    if (sha256.convert(bytes).toString() != manifest.sha256.toLowerCase()) {
      throw UpdateRejectedException('the download does not match its hash');
    }
  }

  /// Revalidates both the release signature and staged bytes immediately
  /// before a future activation; the stored path is never trusted as input.
  Future<({UpdateManifest manifest, List<int> bytes})> readVerifiedStaged(
    Directory directory, {
    required String currentVersion,
  }) async {
    final pointer = File('${directory.path}/pending-update.json');
    Object? metadata;
    try {
      metadata = jsonDecode(await pointer.readAsString());
    } on Object {
      throw UpdateRejectedException(
        'the staged update metadata is unavailable',
      );
    }
    if (metadata is! Map || metadata['manifest'] is! Map) {
      throw UpdateRejectedException('the staged update has no signed manifest');
    }
    final manifest = UpdateManifest.fromJson(
      Map<String, Object?>.from(metadata['manifest'] as Map),
    );
    await verifyManifest(manifest, currentVersion: currentVersion);
    final path = '${directory.path}/syntila-worker-${manifest.version}';
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw UpdateRejectedException('the staged artifact is unavailable');
    }
    final file = File(path);
    if (await file.length() > 256 * 1024 * 1024) {
      throw UpdateRejectedException('the staged artifact is too large');
    }
    final bytes = await file.readAsBytes();
    verifyArtifact(manifest, bytes);
    return (manifest: manifest, bytes: bytes);
  }

  /// Materialize a verified release at a versioned, Agent-owned path. This
  /// does not change the service registration or start the executable.
  Future<File> prepareExecutable(
    Directory directory, {
    required String currentVersion,
  }) async {
    final staged = await readVerifiedStaged(
      directory,
      currentVersion: currentVersion,
    );
    final releases = Directory('${directory.path}/releases');
    final existingDirectory = await FileSystemEntity.type(
      releases.path,
      followLinks: false,
    );
    if (existingDirectory != FileSystemEntityType.notFound &&
        existingDirectory != FileSystemEntityType.directory) {
      throw UpdateRejectedException('the release directory is invalid');
    }
    await releases.create(recursive: true);
    await AgentPaths.restrict(releases);
    final target = File(
      '${releases.path}/syntila-worker-${staged.manifest.version}-${staged.manifest.sha256}${Platform.isWindows ? '.exe' : ''}',
    );
    final kind = await FileSystemEntity.type(target.path, followLinks: false);
    if (kind != FileSystemEntityType.notFound) {
      if (kind != FileSystemEntityType.file ||
          await target.length() > 256 * 1024 * 1024) {
        throw UpdateRejectedException('the prepared executable is invalid');
      }
      verifyArtifact(staged.manifest, await target.readAsBytes());
      return target;
    }
    final temporary = File('${target.path}.tmp');
    await temporary.create(exclusive: true);
    try {
      await temporary.writeAsBytes(staged.bytes, flush: true);
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', ['700', temporary.path]);
        if (result.exitCode != 0) {
          throw UpdateRejectedException(
            'could not make the prepared executable private',
          );
        }
      }
      verifyArtifact(staged.manifest, await temporary.readAsBytes());
      await temporary.rename(target.path);
      return target;
    } finally {
      if (await temporary.exists()) await temporary.delete();
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
    if (bytes.length > 256 * 1024 * 1024) {
      throw UpdateRejectedException('the artifact is too large');
    }
    verifyArtifact(manifest, bytes);
    await directory.create(recursive: true);
    await AgentPaths.restrict(directory);
    final target = File('${directory.path}/syntila-worker-${manifest.version}');
    final temp = File('${target.path}.part');
    // Never follow an existing temporary file or symlink. A leftover temp file
    // is evidence of an interrupted/concurrent update and needs inspection.
    await temp.create(exclusive: true);
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    final pointer = File('${directory.path}/pending-update.json');
    final pending = File('${pointer.path}.tmp');
    await pending.create(exclusive: true);
    try {
      await pending.writeAsString(
        jsonEncode({
          'version': manifest.version,
          'file': target.path,
          'manifest': {
            'version': manifest.version,
            'channel': manifest.channel,
            'url': manifest.url,
            'sha256': manifest.sha256,
            'signature': manifest.signature,
          },
        }),
        flush: true,
      );
      await pending.rename(pointer.path);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
    return target;
  }
}
