import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'folders.dart';

/// The Agent's Work Root and its stable `spaces/<space-id>/` mapping
/// (ADR-037). Paths stay on this machine; the Cloud only ever sees Space IDs.
///
/// The Work Root and every adopted folder must already be an Allowed Folder
/// with write access, so choosing a Worker in the web app never reaches a
/// folder the owner did not approve.
class WorkRoot {
  WorkRoot(this.file, this.folders);

  final File file;
  final AllowedFolders folders;

  static final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');

  Future<Map<String, Object?>> _read() async {
    if (!await file.exists()) return {};
    final decoded = jsonDecode(await file.readAsString());
    return decoded is Map<String, Object?> ? decoded : {};
  }

  Future<void> _write(Map<String, Object?> value) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(value), flush: true);
    await temp.rename(file.path);
  }

  Future<String?> root() async => (await _read())['root'] as String?;

  /// Chooses the Work Root. It is granted for read and write in the same step.
  Future<void> setRoot(String path) async {
    await Directory(path).create(recursive: true);
    await folders.add(path, write: true);
    final value = await _read();
    value['root'] = p.normalize(Directory(path).resolveSymbolicLinksSync());
    await _write(value);
  }

  Future<Map<String, String>> adopted() async {
    final raw = (await _read())['adopted'];
    return raw is Map
        ? {
            for (final e in raw.entries)
              if (e.key is String && e.value is String)
                e.key as String: e.value as String,
          }
        : {};
  }

  /// The local folder of a Space: an adopted existing folder if the owner
  /// mapped one, otherwise `<root>/spaces/<space-id>`. Re-checked against the
  /// grants every time, so a revoked folder cannot be reached.
  Future<Directory> spaceDirectory(String spaceId) async {
    if (!_safeId.hasMatch(spaceId)) {
      throw FolderRejectedException('the Space id is not a safe folder name');
    }
    final adoptedPath = (await adopted())[spaceId];
    final String path;
    if (adoptedPath != null) {
      path = adoptedPath;
    } else {
      final base = await root();
      if (base == null) {
        throw FolderRejectedException('no Work Root has been set');
      }
      path = p.join(base, 'spaces', spaceId);
      await Directory(path).create(recursive: true);
    }
    await folders.require(path, write: true);
    return Directory(p.normalize(Directory(path).resolveSymbolicLinksSync()));
  }

  /// Explicit migration of an existing Workspace layout: each Space ID is
  /// mapped to the folder it already uses. Nothing is moved or deleted; a
  /// folder that is not granted for writing is refused.
  Future<void> adopt(Map<String, String> spaceFolders) async {
    final mapped = await adopted();
    for (final entry in spaceFolders.entries) {
      if (!_safeId.hasMatch(entry.key)) {
        throw FolderRejectedException('the Space id is not a safe folder name');
      }
      await folders.require(entry.value, write: true);
      mapped[entry.key] = p.normalize(
        Directory(entry.value).resolveSymbolicLinksSync(),
      );
    }
    final value = await _read();
    value['adopted'] = mapped;
    await _write(value);
  }
}
