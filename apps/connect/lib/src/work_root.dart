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

  /// Returns the configured Work Root, or initializes [defaultPath] on first
  /// run (creating the folder, verifying write access, and granting it).
  Future<String> ensureDefault(String defaultPath) async {
    final existing = await root();
    if (existing != null) return existing;
    await setRoot(defaultPath);
    return (await root())!;
  }

  /// Chooses the Work Root. Creates it if missing, verifies write access, and
  /// grants it for read and write in the same step.
  Future<void> setRoot(String path) async {
    final dir = Directory(path);
    try {
      await dir.create(recursive: true);
    } on FileSystemException catch (error) {
      throw FolderRejectedException(
        'could not create Work Root folder ($path): ${error.message}',
      );
    }
    final canonical = p.normalize(dir.resolveSymbolicLinksSync());
    final id = await folders.add(canonical, write: true);
    try {
      await _verifyWritable(canonical);
    } on FolderRejectedException {
      await folders.remove(id);
      rethrow;
    }
    final value = await _read();
    value['root'] = canonical;
    await _write(value);
  }

  Future<void> _verifyWritable(String canonical) async {
    final probe = File(
      p.join(
        canonical,
        '.syntila-write-check-$pid-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await probe.writeAsString('', flush: true);
      await probe.delete();
    } on FileSystemException catch (error) {
      throw FolderRejectedException(
        'Work Root folder is not writable ($canonical): ${error.message}',
      );
    }
  }

  /// The local folder of a Space: `<root>/spaces/<space-id>`. Re-checked
  /// against the grants every time, so a revoked folder cannot be reached.
  Future<Directory> spaceDirectory(String spaceId) async {
    if (!_safeId.hasMatch(spaceId)) {
      throw FolderRejectedException('the Space id is not a safe folder name');
    }
    final base = await root();
    if (base == null) {
      throw FolderRejectedException('no Work Root has been set');
    }
    final path = p.join(base, 'spaces', spaceId);
    await Directory(path).create(recursive: true);
    await folders.require(path, write: true);
    return Directory(p.normalize(Directory(path).resolveSymbolicLinksSync()));
  }
}
