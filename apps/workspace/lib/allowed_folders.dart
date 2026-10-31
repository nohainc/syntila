import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Result of the most recent local access check for an Allowed Folder.
enum AllowedFolderStatus {
  /// The folder exists and the service account can create files in it.
  available('available'),

  /// The folder exists and can be listed, but a write probe failed.
  readOnly('read_only'),

  /// The folder no longer exists or is no longer a directory.
  missing('missing'),

  /// The folder exists but the service account cannot list it.
  denied('denied');

  const AllowedFolderStatus(this.wireValue);
  final String wireValue;

  static AllowedFolderStatus parse(Object? value) => values.firstWhere(
        (status) => status.wireValue == value,
        orElse: () => AllowedFolderStatus.missing,
      );
}

/// A folder outside Work Root that the Workspace owner explicitly allowed
/// Spaces on this Workspace to use. The absolute path never leaves the
/// machine; Cloud only ever sees [id], [displayName], and [status].
final class AllowedFolder {
  const AllowedFolder({
    required this.id,
    required this.displayName,
    required this.path,
    required this.status,
    required this.addedAt,
    required this.checkedAt,
  });

  final String id;
  final String displayName;
  final String path;
  final AllowedFolderStatus status;
  final DateTime addedAt;
  final DateTime checkedAt;

  AllowedFolder copyWith({
    String? displayName,
    AllowedFolderStatus? status,
    DateTime? checkedAt,
  }) =>
      AllowedFolder(
        id: id,
        displayName: displayName ?? this.displayName,
        path: path,
        status: status ?? this.status,
        addedAt: addedAt,
        checkedAt: checkedAt ?? this.checkedAt,
      );

  /// Local representation for the private registry and the management UI.
  Map<String, Object?> toJson() => {
        'id': id,
        'displayName': displayName,
        'path': path,
        'status': status.wireValue,
        'addedAt': addedAt.toUtc().toIso8601String(),
        'checkedAt': checkedAt.toUtc().toIso8601String(),
      };

  /// Representation safe to publish to Cloud: no local path.
  Map<String, Object?> toCloudSummary() => {
        'id': id,
        'displayName': displayName,
        'status': status.wireValue,
        'checkedAt': checkedAt.toUtc().toIso8601String(),
      };

  static AllowedFolder? tryParse(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['displayName'];
    final path = value['path'];
    final addedAt = DateTime.tryParse(value['addedAt']?.toString() ?? '');
    final checkedAt = DateTime.tryParse(value['checkedAt']?.toString() ?? '');
    if (id is! String ||
        !AllowedFolderRegistry._safeId.hasMatch(id) ||
        name is! String ||
        path is! String ||
        path.isEmpty ||
        addedAt == null ||
        checkedAt == null) {
      return null;
    }
    return AllowedFolder(
      id: id,
      displayName: name,
      path: path,
      status: AllowedFolderStatus.parse(value['status']),
      addedAt: addedAt,
      checkedAt: checkedAt,
    );
  }
}

/// A requested folder cannot be allowed. [code] is stable for IPC clients.
class AllowedFolderViolation implements Exception {
  const AllowedFolderViolation(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'AllowedFolderViolation($code): $message';
}

/// Owner-managed list of local folders that Spaces on this Workspace may
/// attach in addition to their Space directory.
///
/// The list is private Workspace Service state. Only the local management
/// IPC (owner OS account plus installation key) can change it; Cloud
/// assignment payloads can only reference entries by [AllowedFolder.id].
/// Adding, removing, or re-checking a folder never creates, moves, or deletes
/// user files beyond a short-lived write probe.
class AllowedFolderRegistry {
  AllowedFolderRegistry({
    required this.registryDirectory,
    required this.workRoot,
    required this.applicationDataRoot,
    required this.homeDirectory,
    DateTime Function()? clock,
    Random? random,
  })  : _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  final Directory registryDirectory;
  final Directory workRoot;
  final Directory applicationDataRoot;
  final String homeDirectory;
  final DateTime Function() _clock;
  final Random _random;
  Future<void> _tail = Future<void>.value();

  static const fileName = 'allowed-folders.json';
  static const _schemaVersion = 1;
  static const maxFolders = 32;
  static const maxDisplayNameLength = 80;
  static final _safeId = RegExp(r'^folder-[a-f0-9]{16}$');

  File get _file =>
      File('${registryDirectory.path}${Platform.pathSeparator}$fileName');

  /// Stored folders in insertion order, without touching the filesystem
  /// beyond the registry file.
  Future<List<AllowedFolder>> list() => _serial(_read);

  Future<AllowedFolder?> find(String id) async {
    for (final folder in await list()) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  /// Validates [path] and stores it. Rejects system, home, Work Root, and
  /// application-state locations, paths already allowed, and folders the
  /// service account cannot write to.
  Future<AllowedFolder> add(String path, {String? displayName}) =>
      _serial(() async {
        final folders = await _read();
        if (folders.length >= maxFolders) {
          throw const AllowedFolderViolation(
              'limit_reached', 'At most $maxFolders folders can be allowed.');
        }
        final canonical = await _canonicalDirectory(path);
        _rejectProtected(canonical);
        for (final existing in folders) {
          if (_samePath(existing.path, canonical)) {
            throw const AllowedFolderViolation(
                'duplicate', 'This folder is already allowed.');
          }
          if (_contains(existing.path, canonical) ||
              _contains(canonical, existing.path)) {
            throw const AllowedFolderViolation('overlapping',
                'This folder overlaps a folder that is already allowed.');
          }
        }
        final name = _displayName(displayName, canonical);
        _rejectTakenName(folders, name);
        // Check write access now: a folder Spaces cannot write to is never
        // registered.
        final status = await probe(canonical);
        if (status != AllowedFolderStatus.available) {
          throw AllowedFolderViolation(
              status == AllowedFolderStatus.readOnly
                  ? 'not_writable'
                  : status == AllowedFolderStatus.denied
                      ? 'denied'
                      : 'not_a_directory',
              status == AllowedFolderStatus.readOnly
                  ? 'The folder is not writable. Grant write access to the '
                      'Workspace service account and try again.'
                  : status == AllowedFolderStatus.denied
                      ? 'The folder cannot be accessed by the Workspace '
                          'service account.'
                      : 'The selected path is not an existing folder.');
        }
        final now = _clock();
        final folder = AllowedFolder(
          id: _newId(folders),
          displayName: name,
          path: canonical,
          status: status,
          addedAt: now,
          checkedAt: now,
        );
        await _write([...folders, folder]);
        return folder;
      });

  /// Forgets the folder. The folder and its files are left untouched.
  Future<bool> remove(String id) => _serial(() async {
        final folders = await _read();
        final remaining = folders.where((folder) => folder.id != id).toList();
        if (remaining.length == folders.length) return false;
        await _write(remaining);
        return true;
      });

  Future<AllowedFolder?> rename(String id, String displayName) =>
      _serial(() async {
        final folders = await _read();
        final current = folders.where((folder) => folder.id == id).firstOrNull;
        if (current != null) {
          _rejectTakenName(
            folders.where((folder) => folder.id != id),
            _displayName(displayName, current.path),
          );
        }
        AllowedFolder? renamed;
        final updated = [
          for (final folder in folders)
            if (folder.id == id)
              renamed = folder.copyWith(
                  displayName: _displayName(displayName, folder.path))
            else
              folder,
        ];
        if (renamed != null) await _write(updated);
        return renamed;
      });

  /// Maps the folder IDs Cloud attached to an assignment back to local paths,
  /// checking access again right before launch. Any folder that is no longer
  /// allowed or accessible fails the execution; folders are never dropped.
  Future<List<String>> resolveForExecution(List<String> ids) async {
    if (ids.isEmpty) return const [];
    if (ids.length > maxFolders || ids.toSet().length != ids.length) {
      throw const AllowedFolderViolation(
          'folder_unavailable', 'The attached folder list is invalid.');
    }
    final folders = {for (final folder in await list()) folder.id: folder};
    final paths = <String>[];
    for (final id in ids) {
      final folder = folders[id];
      if (folder == null) {
        throw const AllowedFolderViolation(
            'folder_unavailable',
            'An additional folder attached to this Space is no longer allowed '
                'on this Workspace.');
      }
      final status = await probe(folder.path);
      if (status == AllowedFolderStatus.missing ||
          status == AllowedFolderStatus.denied) {
        throw AllowedFolderViolation(
            'folder_unavailable',
            'The additional folder "${folder.displayName}" is '
                '${status == AllowedFolderStatus.missing ? 'missing' : 'not accessible'} '
                'on this Workspace.');
      }
      paths.add(folder.path);
    }
    return paths;
  }

  /// Re-runs the access check for one folder, or all folders when [id] is
  /// null, and persists the results.
  Future<List<AllowedFolder>> recheck({String? id}) => _serial(() async {
        final folders = await _read();
        final now = _clock();
        final updated = <AllowedFolder>[
          for (final folder in folders)
            if (id == null || folder.id == id)
              folder.copyWith(status: await probe(folder.path), checkedAt: now)
            else
              folder,
        ];
        await _write(updated);
        return updated;
      });

  /// Classifies current access to [path] without following it outside the
  /// stored canonical location.
  static Future<AllowedFolderStatus> probe(String path) async {
    final directory = Directory(path);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      return AllowedFolderStatus.missing;
    }
    try {
      await directory.list(followLinks: false).take(1).drain<void>();
    } on FileSystemException {
      return AllowedFolderStatus.denied;
    }
    final probeFile = File('$path${Platform.pathSeparator}'
        '.syntila-write-check-$pid-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await probeFile.writeAsString('ok', flush: true);
    } on FileSystemException {
      return AllowedFolderStatus.readOnly;
    }
    try {
      await probeFile.delete();
    } on FileSystemException {
      // The folder is writable; a leftover probe file is harmless.
    }
    return AllowedFolderStatus.available;
  }

  Future<String> _canonicalDirectory(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty || !_isAbsolute(trimmed)) {
      throw const AllowedFolderViolation(
          'invalid_path', 'Choose an absolute folder path.');
    }
    final type = await FileSystemEntity.type(trimmed, followLinks: true);
    if (type != FileSystemEntityType.directory) {
      throw const AllowedFolderViolation(
          'not_a_directory', 'The selected path is not an existing folder.');
    }
    try {
      return _normalize(await Directory(trimmed).resolveSymbolicLinks());
    } on FileSystemException catch (error) {
      throw AllowedFolderViolation(
          'denied', 'The folder cannot be accessed: ${error.message}');
    }
  }

  void _rejectProtected(String canonical) {
    if (_isFilesystemRoot(canonical)) {
      throw const AllowedFolderViolation(
          'protected', 'The filesystem root cannot be allowed.');
    }
    final home = _resolvedOrNormalized(homeDirectory);
    if (home != null && _samePath(canonical, home)) {
      throw const AllowedFolderViolation('protected',
          'The home folder cannot be allowed. Choose a folder inside it.');
    }
    if (home != null && _contains(canonical, home)) {
      throw const AllowedFolderViolation('protected',
          'A folder containing the home folder cannot be allowed.');
    }
    for (final protected in [workRoot.path, applicationDataRoot.path]) {
      final resolved = _resolvedOrNormalized(protected);
      if (resolved == null) continue;
      if (_samePath(canonical, resolved) ||
          _contains(resolved, canonical) ||
          _contains(canonical, resolved)) {
        throw AllowedFolderViolation(
            'protected',
            protected == workRoot.path
                ? 'Work Root folders are already available to their Spaces.'
                : 'Syntila application data cannot be allowed.');
      }
    }
  }

  Future<List<AllowedFolder>> _read() async {
    if (!await _file.exists()) return const [];
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map || decoded['schemaVersion'] != _schemaVersion) {
        throw const FormatException('unsupported schema');
      }
      final entries = decoded['folders'];
      if (entries is! List) throw const FormatException('folders missing');
      return [
        for (final entry in entries)
          if (AllowedFolder.tryParse(entry) case final folder?) folder,
      ];
    } on FormatException catch (error) {
      throw StateError('Allowed folder registry is invalid: ${error.message}');
    } on FileSystemException catch (error) {
      throw StateError(
          'Allowed folder registry could not be read: ${error.message}');
    }
  }

  Future<void> _write(List<AllowedFolder> folders) async {
    await registryDirectory.create(recursive: true);
    final temporary =
        File('${_file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}');
    await temporary.writeAsString(
        jsonEncode({
          'schemaVersion': _schemaVersion,
          'folders': [for (final folder in folders) folder.toJson()],
        }),
        flush: true);
    try {
      await temporary.rename(_file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  String _newId(List<AllowedFolder> existing) {
    while (true) {
      final buffer = StringBuffer('folder-');
      for (var i = 0; i < 8; i++) {
        buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
      }
      final id = buffer.toString();
      if (existing.every((folder) => folder.id != id)) return id;
    }
  }

  /// Folder names are unique within a Workspace (case-insensitive): Spaces
  /// and Cloud show folders by name.
  static void _rejectTakenName(Iterable<AllowedFolder> others, String name) {
    final key = name.toLowerCase();
    if (others.any((folder) => folder.displayName.toLowerCase() == key)) {
      throw AllowedFolderViolation(
          'name_taken', 'A folder named "$name" is already allowed.');
    }
  }

  String _displayName(String? requested, String path) {
    final trimmed = requested?.trim() ?? '';
    final fallback = path
        .split(RegExp(r'[\\/]'))
        .lastWhere((part) => part.isNotEmpty, orElse: () => path);
    final name = trimmed.isEmpty ? fallback : trimmed;
    if (name.length > maxDisplayNameLength ||
        name.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      throw const AllowedFolderViolation('invalid_name',
          'Folder names must be at most $maxDisplayNameLength characters.');
    }
    return name;
  }

  static bool _isAbsolute(String path) =>
      path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  static bool _isFilesystemRoot(String path) =>
      path == '/' || RegExp(r'^[A-Za-z]:\\?$').hasMatch(path);

  static String _normalize(String path) {
    if (_isFilesystemRoot(path)) return path;
    return path.replaceFirst(RegExp(r'[\\/]+$'), '');
  }

  static String? _resolvedOrNormalized(String path) {
    if (path.trim().isEmpty) return null;
    try {
      return _normalize(Directory(path).resolveSymbolicLinksSync());
    } on FileSystemException {
      return _normalize(Directory(path).absolute.path);
    }
  }

  static String _key(String path) =>
      Platform.isWindows || Platform.isMacOS ? path.toLowerCase() : path;

  static bool _samePath(String a, String b) => _key(a) == _key(b);

  /// True when [child] is strictly below [parent].
  static bool _contains(String parent, String child) {
    final separator = Platform.pathSeparator;
    final prefix = parent.endsWith(separator) ? parent : '$parent$separator';
    return _key(child).startsWith(_key(prefix));
  }
}

/// Whether a Tool Profile can pass additional folders to its CLI. Every
/// argument vector that may be selected (base and each compatibility
/// override) must contain the `forEachAdditionalDirectory` slot.
bool profileSupportsAdditionalDirectories(Map<String, Object?> profile) {
  bool hasSlot(Object? arguments) =>
      arguments is List &&
      arguments.any((part) =>
          part is Map && part.containsKey('forEachAdditionalDirectory'));
  final execution = profile['execution'];
  if (execution is! Map || !hasSlot(execution['arguments'])) return false;
  final overrides = profile['compatibilityOverrides'];
  if (overrides is List) {
    for (final override in overrides) {
      if (override is Map &&
          override.containsKey('executionArguments') &&
          !hasSlot(override['executionArguments'])) {
        return false;
      }
    }
  }
  return true;
}

/// Folder IDs Cloud attached to an assignment, or an empty list. Malformed
/// values fail closed.
List<String> assignmentAdditionalFolderIds(Map<String, Object?> payload) {
  final input = payload['input'];
  final value = input is Map ? input['additionalFolderIds'] : null;
  if (value == null) return const [];
  if (value is! List ||
      value.any((id) =>
          id is! String || !AllowedFolderRegistry._safeId.hasMatch(id))) {
    throw const AllowedFolderViolation(
        'folder_unavailable', 'The attached folder list is invalid.');
  }
  return List<String>.unmodifiable(value.cast<String>());
}
