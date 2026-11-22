import 'dart:convert';
import 'dart:io';

/// The MCP Workers the owner has approved on this machine (ADR-041). A plugin is
/// identified by its id, version and manifest digest. The list is filled only
/// by a local command: the Cloud never ships plugin code or approves one, so a
/// compromised Cloud cannot make this Agent run new code.
class ApprovedMcpWorker {
  const ApprovedMcpWorker(this.id, this.version, this.digest, {this.deviceId});
  final String id;
  final String version;
  final String digest;
  final String? deviceId;
  Map<String, String> toJson() => {
    'id': id,
    'version': version,
    'digest': digest,
    if (deviceId != null) 'deviceId': deviceId!,
  };
}

class McpWorkerAllowList {
  McpWorkerAllowList(this.file);
  final File file;

  /// The manifest's pluginId (lowercase kebab-case), not the Cloud's `plugin-<hex>` Type id.
  static final _id = RegExp(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$');
  static final _version = RegExp(r'^\d+\.\d+\.\d+$');
  static final _digest = RegExp(r'^[0-9a-f]{64}$');

  static bool validPin(String id, String version, String digest) =>
      id.length <= 48 &&
      _id.hasMatch(id) &&
      _version.hasMatch(version) &&
      _digest.hasMatch(digest);

  Future<List<ApprovedMcpWorker>> list() async {
    if (!await file.exists()) return [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return [];
      return [
        for (final e in decoded)
          if (e is Map &&
              e['id'] is String &&
              e['version'] is String &&
              e['digest'] is String &&
              validPin(
                e['id'] as String,
                e['version'] as String,
                e['digest'] as String,
              ))
            ApprovedMcpWorker(
              e['id'] as String,
              e['version'] as String,
              e['digest'] as String,
              deviceId: e['deviceId'] is String
                  ? e['deviceId'] as String
                  : null,
            ),
      ];
    } on FormatException {
      return []; // An unreadable list approves nothing.
    }
  }

  Future<bool> isApproved(String id, String version, String digest) async =>
      validPin(id, version, digest) &&
      (await list()).any(
        (p) => p.id == id && p.version == version && p.digest == digest,
      );

  Future<void> _write(List<ApprovedMcpWorker> items) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode([for (final p in items) p.toJson()]),
      flush: true,
    );
    await temp.rename(file.path);
  }

  Future<void> approve(
    String id,
    String version,
    String digest, {
    String? deviceId,
  }) async {
    if (!validPin(id, version, digest)) {
      throw const FormatException(
        'the plugin id, version or digest is invalid',
      );
    }
    final items = await list();
    if (items.any(
      (p) => p.id == id && p.version == version && p.digest == digest,
    ))
      return;
    await _write([
      ...items,
      ApprovedMcpWorker(id, version, digest, deviceId: deviceId),
    ]);
  }

  /// Removes every approval of [id] with [digest]. Returns whether one existed.
  Future<bool> remove(String id, String digest) async {
    final items = await list();
    final kept = items
        .where((p) => !(p.id == id && p.digest == digest))
        .toList();
    if (kept.length == items.length) return false;
    await _write(kept);
    return true;
  }
}
