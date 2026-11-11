import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_external_worker_protocol/syntila_external_worker_protocol.dart';

/// Canonical JSON: keys sorted, no whitespace. This is the exact form the
/// manifest digest is computed over (same as the Workspace and Cloud).
String canonicalExternalWorkerJson(Object? value) {
  if (value is List)
    return '[${value.map(canonicalExternalWorkerJson).join(',')}]';
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonicalExternalWorkerJson(value[k])}').join(',')}}';
  }
  return jsonEncode(value);
}

/// The pinned identity of a plugin: SHA-256 of the canonical manifest.
String externalWorkerManifestDigest(Map<String, Object?> manifest) => sha256
    .convert(utf8.encode(canonicalExternalWorkerJson(manifest)))
    .toString();

class PackResult {
  const PackResult({required this.manifest, required this.digest});
  final ExternalWorkerManifest manifest;
  final String digest;
}

/// Fills `sha256` and `size` for every artifact of `<directory>/plugin.json`
/// from the files on disk, validates the result, rewrites the file, and
/// returns the manifest digest. Artifacts whose files are missing keep their
/// existing values (a bundle may carry only one platform's build).
PackResult packExternalWorkerDirectory(String directory) {
  final file = File('$directory/plugin.json');
  if (!file.existsSync()) {
    throw FormatException('plugin.json was not found in $directory');
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map)
    throw const FormatException('plugin.json must be an object');
  final manifest = Map<String, Object?>.from(decoded);
  final artifacts = manifest['artifacts'];
  if (artifacts is! Map) {
    throw const FormatException('plugin.json needs an "artifacts" object');
  }
  final filled = <String, Object?>{};
  for (final entry in artifacts.entries) {
    final artifact = Map<String, Object?>.from(entry.value as Map);
    final command = artifact['command'];
    if (command is! String || !isSafeExternalWorkerRelativePath(command)) {
      throw FormatException(
          'artifacts.${entry.key}.command is not a safe path');
    }
    final binary = File('$directory/$command');
    if (binary.existsSync()) {
      final bytes = binary.readAsBytesSync();
      artifact['sha256'] = sha256.convert(bytes).toString();
      artifact['size'] = bytes.length;
    }
    artifact.putIfAbsent('args', () => <String>[]);
    filled[entry.key as String] = artifact;
  }
  manifest['artifacts'] = filled;
  final validation = validateExternalWorkerManifest(manifest);
  final valid = validation.manifest;
  if (valid == null) {
    throw FormatException(
      'plugin.json is invalid: ${validation.issues.join('; ')}',
    );
  }
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  return PackResult(
      manifest: valid, digest: externalWorkerManifestDigest(manifest));
}
