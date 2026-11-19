import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class FolderRejectedException implements Exception {
  FolderRejectedException(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// The folders the local owner has authorized for this Worker. Cloud only ever
/// sees the opaque ids; a Worker chosen in the web app cannot grant a folder.
class AllowedFolders {
  AllowedFolders(this.file, {required this.home, required this.dataRoot});

  final File file;
  final String home;

  /// Syntila's application-data root. A grant that overlaps it is refused.
  final String dataRoot;

  static String _canonical(String path) {
    final directory = Directory(path);
    if (!directory.existsSync()) {
      throw FolderRejectedException('the folder does not exist');
    }
    return p.normalize(directory.resolveSymbolicLinksSync());
  }

  static bool _within(String child, String parent) =>
      child == parent || p.isWithin(parent, child);

  String _idFor(String canonical) =>
      'fld-${sha256.convert(utf8.encode(canonical)).toString().substring(0, 16)}';

  Future<List<Map<String, String>>> list() async {
    if (!await file.exists()) return [];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) return [];
    return [
      for (final item in decoded)
        if (item is Map && item['id'] is String && item['path'] is String)
          {'id': item['id'] as String, 'path': item['path'] as String},
    ];
  }

  Future<void> _save(List<Map<String, String>> folders) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(folders), flush: true);
    await temp.rename(file.path);
  }

  /// Validates and stores [path]; returns its opaque id.
  Future<String> add(String path) async {
    final canonical = _canonical(path);
    if (canonical == p.rootPrefix(canonical) || canonical == p.separator) {
      throw FolderRejectedException('a filesystem root cannot be granted');
    }
    final homeCanonical = _canonical(home);
    if (_within(homeCanonical, canonical)) {
      throw FolderRejectedException(
        'the home folder or a parent of it cannot be granted',
      );
    }
    final dataDirectory = Directory(dataRoot);
    final dataCanonical = dataDirectory.existsSync()
        ? p.normalize(dataDirectory.resolveSymbolicLinksSync())
        : p.normalize(p.absolute(dataRoot));
    if (_within(canonical, dataCanonical) ||
        _within(dataCanonical, canonical)) {
      throw FolderRejectedException(
        'a folder that overlaps Syntila application data cannot be granted',
      );
    }
    final id = _idFor(canonical);
    final folders = await list();
    if (folders.any((f) => f['id'] == id)) return id;
    folders.add({'id': id, 'path': canonical});
    await _save(folders);
    return id;
  }

  Future<bool> remove(String id) async {
    final folders = await list();
    final kept = folders.where((f) => f['id'] != id).toList();
    if (kept.length == folders.length) return false;
    await _save(kept);
    return true;
  }

  /// Whether [path] is inside a granted folder. Checked on the canonical path,
  /// so a symlink out of a granted folder does not pass. Call it at request
  /// time and again right before execution.
  Future<bool> isAllowed(String path) async {
    final String canonical;
    try {
      final entity =
          FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound
          ? null
          : p.normalize(File(path).resolveSymbolicLinksSync());
      if (entity == null) return false;
      canonical = entity;
    } on FileSystemException {
      return false;
    }
    for (final folder in await list()) {
      if (_within(canonical, folder['path']!)) return true;
    }
    return false;
  }
}
