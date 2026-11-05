import 'dart:io';
import 'dart:convert';
import 'dart:math';

/// Minimal session persistence under the plugin's data directory, enough to
/// declare `sessionResume`. State is yours to define; keep secrets out.
class SessionStore {
  SessionStore(String dataDirectory) : _root = Directory(dataDirectory);

  final Directory _root;

  File _file(String key) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'must be an opaque safe key');
    }
    final sessions = Directory('${_root.path}/sessions');
    final file = File('${sessions.path}/$key');
    for (final path in [sessions.path, file.path, '${file.path}.lock']) {
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('Session paths cannot be symbolic links');
      }
    }
    return file;
  }

  bool exists(String key) => _file(key).existsSync();

  String? read(String key) {
    final file = _file(key);
    if (!file.existsSync()) return null;
    if (file.lengthSync() > 2 * 1024 * 1024)
      throw StateError('Session state exceeds limit');
    return file.readAsStringSync();
  }

  void write(String key, String state) {
    if (utf8.encode(state).length > 2 * 1024 * 1024)
      throw StateError('Session state exceeds limit');
    final file = _file(key);
    file.parent.createSync(recursive: true);
    final temporary =
        File('${file.path}.${pid}.${Random.secure().nextInt(1 << 32)}.tmp');
    try {
      temporary.writeAsStringSync(state, flush: true);
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  static final _held = <String>{};

  /// Cross-process exclusive transaction. OS locks release on process exit.
  /// The callback must persist provider state before returning its checkpoint.
  /// Retries of the last committed request return its saved result without
  /// running the callback. This cannot deduplicate an uncommitted remote call.
  Future<SessionCheckpoint> transact(
    String key, {
    required String requestId,
    required String formatId,
    required String? model,
    required Future<SessionCheckpoint> Function(SessionCheckpoint? previous)
        update,
  }) async {
    final file = _file(key);
    file.parent.createSync(recursive: true);
    final path = '${file.parent.resolveSymbolicLinksSync()}/$key.lock';
    if (!_held.add(path)) throw StateError('Session is busy');
    RandomAccessFile? lock;
    try {
      lock = await File(path).open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final text = read(key);
      final previous = text == null
          ? null
          : SessionCheckpoint.fromJson(
              Map<String, Object?>.from(jsonDecode(text) as Map));
      if (previous != null &&
          previous.formatId == formatId &&
          previous.model == model &&
          previous.requestId == requestId) {
        return previous;
      }
      final next = await update(previous);
      if (next.requestId != requestId ||
          next.formatId != formatId ||
          next.model != model ||
          next.generation != (previous?.generation ?? 0) + 1 ||
          next.contextRevision < (previous?.contextRevision ?? 0)) {
        throw StateError('Invalid session checkpoint transition');
      }
      write(key, jsonEncode(next.toJson()));
      return next;
    } finally {
      await lock?.close();
      _held.remove(path);
    }
  }

  void delete(String key) {
    final file = _file(key);
    if (file.existsSync()) file.deleteSync();
  }
}

/// Adapter-owned execution state, never the canonical conversation authority.
class SessionCheckpoint {
  SessionCheckpoint(
      {required this.requestId,
      required this.formatId,
      required this.model,
      required this.generation,
      required this.contextRevision,
      required this.state,
      required this.output}) {
    if (requestId.isEmpty ||
        formatId.isEmpty ||
        generation < 1 ||
        contextRevision < 0) {
      throw const FormatException('Invalid session checkpoint');
    }
  }
  final String requestId;
  final String formatId;
  final String? model;
  final int generation;
  final int contextRevision;

  /// Native handle, transcript, or checkpoint reference; keep credentials out.
  final String state;
  final String output;
  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'requestId': requestId,
        'formatId': formatId,
        'model': model,
        'generation': generation,
        'contextRevision': contextRevision,
        'state': state,
        'output': output
      };
  factory SessionCheckpoint.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1)
      throw const FormatException('Unknown checkpoint format');
    return SessionCheckpoint(
        requestId: json['requestId'] as String,
        formatId: json['formatId'] as String,
        model: json['model'] as String?,
        generation: json['generation'] as int,
        contextRevision: json['contextRevision'] as int,
        state: json['state'] as String,
        output: json['output'] as String);
  }
}
