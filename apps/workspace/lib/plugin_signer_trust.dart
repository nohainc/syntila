import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'plugin_store.dart';

/// Installation-local fingerprint recognition. Never used as execution authority.
/// One Service owns writes; serialized mutations preserve concurrent IPC changes.
class PluginSignerTrust {
  PluginSignerTrust(this.file);
  final File file;
  Future<void> _tail = Future<void>.value();

  static bool validFingerprint(Object? value) =>
      value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  Future<Map<String, Map<String, Object?>>> _read() async {
    if (!await file.exists()) return {};
    try {
      if (await file.length() > 1024 * 1024) {
        throw const FormatException('signer store exceeds size bound');
      }
      final json = jsonDecode(await file.readAsString());
      if (json is! Map ||
          json['schemaVersion'] != 1 ||
          json['signers'] is! Map) {
        throw const FormatException('signer store');
      }
      final result = <String, Map<String, Object?>>{};
      for (final entry in (json['signers'] as Map).entries) {
        if (!validFingerprint(entry.key) || entry.value is! Map) {
          throw const FormatException('signer record');
        }
        final record = Map<String, Object?>.from(entry.value as Map);
        if (record['fingerprint'] != entry.key ||
            record['acceptedAt'] is! String ||
            DateTime.tryParse(record['acceptedAt'] as String) == null) {
          throw const FormatException('signer record');
        }
        result[entry.key as String] = record;
      }
      return result;
    } on Object {
      throw const PluginServiceException('plugin_signer_trust_invalid',
          'Local signer records could not be read. Preserve the file for recovery.');
    }
  }

  Future<T> _run<T>(T Function(Map<String, Map<String, Object?>>) action,
      {bool write = false}) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        final records = await _read();
        final value = action(records);
        if (write) {
          await file.parent.create(recursive: true);
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsString(
              jsonEncode({
                'schemaVersion': 1,
                'signers': records,
              }),
              flush: true);
          if (!Platform.isWindows) {
            final mode = await Process.run('chmod', ['600', temporary.path]);
            if (mode.exitCode != 0) {
              throw const FileSystemException('permissions');
            }
          }
          await temporary.rename(file.path);
        }
        result.complete(value);
      } on Object catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<List<Map<String, Object?>>> all() => _run((records) {
        final keys = records.keys.toList()..sort();
        return [for (final key in keys) records[key]!];
      });

  Future<bool> contains(String fingerprint) =>
      _run((records) => records.containsKey(fingerprint));

  Future<void> pin(String fingerprint, DateTime acceptedAt) {
    if (!validFingerprint(fingerprint)) {
      throw const FormatException('fingerprint');
    }
    return _run((records) {
      if (!records.containsKey(fingerprint) && records.length >= 1024) {
        throw const PluginServiceException('plugin_quota_exceeded',
            'At most 1024 signing keys can be recognized on this installation.');
      }
      records[fingerprint] = {
        'fingerprint': fingerprint,
        'acceptedAt': acceptedAt.toUtc().toIso8601String(),
      };
    }, write: true);
  }

  Future<bool> remove(String fingerprint) {
    if (!validFingerprint(fingerprint)) {
      throw const FormatException('fingerprint');
    }
    return _run((records) => records.remove(fingerprint) != null, write: true);
  }
}
