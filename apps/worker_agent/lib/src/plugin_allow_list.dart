import 'dart:convert';
import 'dart:io';

/// The plugins the owner has approved on this machine (ADR-041). A plugin is
/// identified by its id, version and manifest digest. The list is filled only
/// by a local command: the Cloud never ships plugin code or approves one, so a
/// compromised Cloud cannot make this Agent run new code.
class ApprovedPlugin {
  const ApprovedPlugin(this.id, this.version, this.digest);
  final String id;
  final String version;
  final String digest;
  Map<String, String> toJson() => {'id': id, 'version': version, 'digest': digest};
}

class PluginAllowList {
  PluginAllowList(this.file);
  final File file;

  static final _id = RegExp(r'^plugin-[0-9a-f]{12}$');
  static final _version = RegExp(r'^\d+\.\d+\.\d+$');
  static final _digest = RegExp(r'^[0-9a-f]{64}$');

  static bool validPin(String id, String version, String digest) =>
      _id.hasMatch(id) && _version.hasMatch(version) && _digest.hasMatch(digest);

  Future<List<ApprovedPlugin>> list() async {
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
              validPin(e['id'] as String, e['version'] as String, e['digest'] as String))
            ApprovedPlugin(e['id'] as String, e['version'] as String, e['digest'] as String),
      ];
    } on FormatException {
      return []; // An unreadable list approves nothing.
    }
  }

  Future<bool> isApproved(String id, String version, String digest) async =>
      validPin(id, version, digest) &&
      (await list()).any((p) => p.id == id && p.version == version && p.digest == digest);

  Future<void> _write(List<ApprovedPlugin> items) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode([for (final p in items) p.toJson()]), flush: true);
    await temp.rename(file.path);
  }

  Future<void> approve(String id, String version, String digest) async {
    if (!validPin(id, version, digest)) {
      throw const FormatException('the plugin id, version or digest is invalid');
    }
    final items = await list();
    if (items.any((p) => p.id == id && p.version == version && p.digest == digest)) return;
    await _write([...items, ApprovedPlugin(id, version, digest)]);
  }

  /// Removes every approval of [id] with [digest]. Returns whether one existed.
  Future<bool> remove(String id, String digest) async {
    final items = await list();
    final kept = items.where((p) => !(p.id == id && p.digest == digest)).toList();
    if (kept.length == items.length) return false;
    await _write(kept);
    return true;
  }
}
