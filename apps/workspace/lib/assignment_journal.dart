import 'dart:convert';
import 'dart:io';

import 'provider_failure_cipher.dart';

enum AssignmentStatus {
  received,
  accepted,
  running,
  cancelling,
  completed,
  failed,
  cancelled,
  interrupted,
  resultPendingUpload,
  reconciled,
}

class AssignmentRecord {
  const AssignmentRecord({
    required this.assignmentId,
    required this.status,
    required this.updatedAt,
    this.workspaceId,
    this.workspaceRuntimeId,
    this.workerId,
    this.runId,
    this.taskId,
    this.attemptId,
    this.idempotencyKey,
    this.executionId,
    this.processExitCode,
    this.errorCode,
    this.result,
  });

  final String assignmentId;
  final AssignmentStatus status;
  final DateTime updatedAt;
  final String? workspaceId;
  final String? workspaceRuntimeId;
  final String? workerId;
  final String? runId;
  final String? taskId;
  final String? attemptId;
  final String? idempotencyKey;
  final String? executionId;
  final int? processExitCode;
  final String? errorCode;
  final Map<String, Object?>? result;

  Map<String, Object?> toJson() => {
        'assignmentId': assignmentId,
        'status': status.name,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (workspaceId != null) 'workspaceId': workspaceId,
        if (workspaceRuntimeId != null)
          'workspaceRuntimeId': workspaceRuntimeId,
        if (workerId != null) 'workerId': workerId,
        if (runId != null) 'runId': runId,
        if (taskId != null) 'taskId': taskId,
        if (attemptId != null) 'attemptId': attemptId,
        if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
        if (executionId != null) 'executionId': executionId,
        if (processExitCode != null) 'processExitCode': processExitCode,
        if (errorCode != null) 'errorCode': errorCode,
        if (result != null) 'result': result,
      };

  factory AssignmentRecord.fromJson(Map<String, Object?> json) {
    final assignmentId = json['assignmentId'];
    final statusName = json['status'];
    final updatedAtText = json['updatedAt'];
    if (assignmentId is! String || assignmentId.isEmpty) {
      throw const FormatException('assignmentId is required');
    }
    if (statusName is! String || statusName.isEmpty) {
      throw const FormatException('status is required');
    }
    if (updatedAtText is! String || updatedAtText.isEmpty) {
      throw const FormatException('updatedAt is required');
    }
    final status = AssignmentStatus.values.asNameMap()[statusName];
    final updatedAt = DateTime.tryParse(updatedAtText);
    if (status == null) throw const FormatException('status is invalid');
    if (updatedAt == null) throw const FormatException('updatedAt is invalid');
    final rawResult = json['result'];
    if (rawResult != null && rawResult is! Map) {
      throw const FormatException('result must be an object');
    }
    return AssignmentRecord(
      assignmentId: assignmentId,
      status: status,
      updatedAt: updatedAt,
      workspaceId: _optionalString(json, 'workspaceId'),
      workspaceRuntimeId: _optionalString(json, 'workspaceRuntimeId'),
      workerId: _optionalString(json, 'workerId'),
      runId: _optionalString(json, 'runId'),
      taskId: _optionalString(json, 'taskId'),
      attemptId: _optionalString(json, 'attemptId'),
      idempotencyKey: _optionalString(json, 'idempotencyKey'),
      executionId: _optionalString(json, 'executionId'),
      processExitCode: _optionalInt(json, 'processExitCode'),
      errorCode: _optionalString(json, 'errorCode'),
      result: rawResult == null
          ? null
          : Map<String, Object?>.from(rawResult as Map),
    );
  }

  static String? _optionalString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String || value.isEmpty) {
      throw FormatException('$key must be a non-empty string');
    }
    return value;
  }

  static int? _optionalInt(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! int) throw FormatException('$key must be an integer');
    return value;
  }
}

class AssignmentJournal {
  AssignmentJournal(this.file, {this.providerFailureCipher});
  final File file;
  final ProviderFailureCipher? providerFailureCipher;
  Future<void> _writeQueue = Future<void>.value();

  // The journal is append-only, so the latest state per assignment can be kept
  // in memory instead of re-reading and re-parsing the whole file on every
  // lookup. The cache is trusted only while the file length equals the length
  // this instance last wrote or loaded; any other change (an external write,
  // a partial record after a crash, an out-of-order transition) discards it
  // and the next lookup performs the full, validating replay.
  Map<String, AssignmentRecord>? _cache;
  int _knownLength = -1;
  int _lineCount = 0;

  /// Compaction thresholds: rewrite only a journal that is both large and
  /// mostly superseded history.
  static const compactionMinLines = 1000;
  static const compactionHistoryFactor = 3;

  Future<void> append(AssignmentRecord record) {
    final next = _writeQueue.then((_) async {
      await file.parent.create(recursive: true);
      final line = '${jsonEncode(await _encodeRecord(record))}\n';
      await file.writeAsString(line, mode: FileMode.append, flush: true);
      _applyAppended(record, utf8.encode(line).length, await file.length());
    });
    _writeQueue = next.catchError((Object _) {});
    return next;
  }

  void _applyAppended(AssignmentRecord record, int bytes, int newLength) {
    final cache = _cache;
    if (cache == null || _knownLength + bytes != newLength) {
      _cache = null;
      return;
    }
    final previous = cache[record.assignmentId];
    if (previous != null && !_canTransition(previous.status, record.status)) {
      // Possibly an out-of-order record or a real violation: let the full
      // replay decide, exactly as before.
      _cache = null;
      return;
    }
    if (previous == null || !record.updatedAt.isBefore(previous.updatedAt)) {
      cache[record.assignmentId] = record;
    }
    _knownLength = newLength;
    _lineCount++;
  }

  /// Marks work owned by a previous service process as interrupted.
  ///
  /// A journal entry in `received` proves execution had not started. Any later
  /// non-terminal state has an uncertain outcome and must never be replayed.
  Future<Map<String, AssignmentRecord>> recoverAfterRestart() async {
    await _writeQueue;
    final records = await reconcile();
    for (final record in records.values) {
      if (!const {
        AssignmentStatus.received,
        AssignmentStatus.accepted,
        AssignmentStatus.running,
        AssignmentStatus.cancelling,
      }.contains(record.status)) {
        continue;
      }
      final recoveryState = record.status == AssignmentStatus.received
          ? 'not_started'
          : 'outcome_unknown';
      await append(AssignmentRecord(
        assignmentId: record.assignmentId,
        status: AssignmentStatus.interrupted,
        updatedAt: DateTime.now().toUtc(),
        workspaceId: record.workspaceId,
        workspaceRuntimeId: record.workspaceRuntimeId,
        workerId: record.workerId,
        runId: record.runId,
        taskId: record.taskId,
        attemptId: record.attemptId,
        idempotencyKey: record.idempotencyKey,
        result: {
          ...?record.result,
          'recoveryState': recoveryState,
          'interruptedAt': DateTime.now().toUtc().toIso8601String(),
        },
      ));
    }
    await compactIfNeeded();
    return reconcile();
  }

  /// Latest state of every assignment. Returns a copy, so callers may iterate
  /// it while appending.
  Future<Map<String, AssignmentRecord>> reconcile() async =>
      Map<String, AssignmentRecord>.of(await _snapshot());

  /// Latest state of one assignment without copying the whole map. Use this on
  /// per-assignment paths.
  Future<AssignmentRecord?> find(String assignmentId) async =>
      (await _snapshot())[assignmentId];

  Future<Map<String, AssignmentRecord>> _snapshot() async {
    if (!await file.exists()) {
      _cache = null;
      return const {};
    }
    final length = await file.length();
    final cache = _cache;
    if (cache != null && length == _knownLength) return cache;
    final lines = await file.readAsLines();
    final records = await _replay(lines);
    _cache = records;
    _knownLength = length;
    _lineCount = lines.length;
    return records;
  }

  /// Rewrites the journal with only the latest record per assignment when it
  /// is large and mostly superseded history. The replacement is written to a
  /// temporary file and renamed over the journal, so a crash leaves either the
  /// old or the new complete file.
  Future<bool> compactIfNeeded() {
    final result = _writeQueue.then((_) async {
      final records = await _snapshot();
      if (_lineCount < compactionMinLines ||
          _lineCount < records.length * compactionHistoryFactor) {
        return false;
      }
      final ordered = records.values.toList()
        ..sort((left, right) => left.updatedAt.compareTo(right.updatedAt));
      final buffer = StringBuffer();
      for (final record in ordered) {
        buffer.writeln(jsonEncode(await _encodeRecord(record)));
      }
      final text = buffer.toString();
      final temporary = File('${file.path}.compact');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
      _cache = Map<String, AssignmentRecord>.of(records);
      _knownLength = utf8.encode(text).length;
      _lineCount = records.length;
      return true;
    });
    _writeQueue = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  Future<Map<String, Object?>> _encodeRecord(AssignmentRecord record) async {
    final json = record.toJson();
    final result = record.result;
    if (result != null && result.containsKey('providerFailure')) {
      final details = result['providerFailure'];
      final cipher = providerFailureCipher;
      if (details is! Map || cipher == null) {
        throw StateError('Provider failure encryption is unavailable');
      }
      final safeResult = Map<String, Object?>.from(result);
      safeResult.remove('providerFailure');
      safeResult['providerFailureEncrypted'] = await cipher.encrypt(
          record.assignmentId, Map<String, Object?>.from(details));
      json['result'] = safeResult;
    }
    return json;
  }

  Future<Map<String, AssignmentRecord>> _replay(List<String> lines) async {
    final records = <String, AssignmentRecord>{};
    final history = <String, List<_JournalEntry>>{};
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (line.trim().isEmpty) continue;
      try {
        final json = Map<String, Object?>.from(jsonDecode(line) as Map);
        final rawResult = json['result'];
        if (rawResult is Map && rawResult.containsKey('providerFailure')) {
          throw const FormatException('Plaintext provider failure in journal');
        }
        if (rawResult is Map &&
            rawResult.containsKey('providerFailureEncrypted')) {
          final result = Map<String, Object?>.from(rawResult);
          final encrypted = result.remove('providerFailureEncrypted');
          final cipher = providerFailureCipher;
          if (encrypted is! Map ||
              cipher == null ||
              json['assignmentId'] is! String) {
            throw StateError('Provider failure decryption is unavailable');
          }
          result['providerFailure'] = await cipher.decrypt(
              json['assignmentId'] as String,
              Map<String, Object?>.from(encrypted));
          json['result'] = result;
        }
        final record = AssignmentRecord.fromJson(json);
        history
            .putIfAbsent(record.assignmentId, () => [])
            .add(_JournalEntry(index, record));
        final previous = records[record.assignmentId];
        if (previous == null ||
            record.updatedAt.isAfter(previous.updatedAt) ||
            record.updatedAt.isAtSameMomentAs(previous.updatedAt)) {
          records[record.assignmentId] = record;
        }
      } on Object {
        if (index != lines.length - 1 || line.trimRight().endsWith('}')) {
          rethrow;
        }
        // A crash may leave a partial final JSONL record. Earlier corruption
        // remains fatal so durable state is not silently discarded.
      }
    }
    for (final entries in history.values) {
      entries.sort((left, right) {
        final timestamp =
            left.record.updatedAt.compareTo(right.record.updatedAt);
        return timestamp == 0 ? left.index.compareTo(right.index) : timestamp;
      });
      for (var index = 1; index < entries.length; index++) {
        final previous = entries[index - 1].record.status;
        final next = entries[index].record.status;
        if (!_canTransition(previous, next)) {
          throw FormatException(
            'invalid assignment transition: ${previous.name} -> ${next.name}',
          );
        }
      }
    }
    return records;
  }
}

class _JournalEntry {
  const _JournalEntry(this.index, this.record);
  final int index;
  final AssignmentRecord record;
}

bool _canTransition(AssignmentStatus previous, AssignmentStatus next) {
  if (previous == next) return true;
  if (next == AssignmentStatus.reconciled) return true;
  return switch (previous) {
    AssignmentStatus.received => {
        AssignmentStatus.accepted,
        AssignmentStatus.running,
        AssignmentStatus.cancelling,
        AssignmentStatus.cancelled,
        AssignmentStatus.interrupted,
      }.contains(next),
    AssignmentStatus.accepted => {
        AssignmentStatus.running,
        AssignmentStatus.completed,
        AssignmentStatus.failed,
        AssignmentStatus.cancelling,
        AssignmentStatus.cancelled,
        AssignmentStatus.interrupted,
      }.contains(next),
    AssignmentStatus.running => {
        AssignmentStatus.cancelling,
        AssignmentStatus.completed,
        AssignmentStatus.failed,
        AssignmentStatus.cancelled,
        AssignmentStatus.interrupted,
        AssignmentStatus.resultPendingUpload,
      }.contains(next),
    AssignmentStatus.cancelling => {
        AssignmentStatus.cancelled,
        AssignmentStatus.failed,
        AssignmentStatus.interrupted,
      }.contains(next),
    AssignmentStatus.interrupted =>
      {AssignmentStatus.resultPendingUpload}.contains(next),
    AssignmentStatus.resultPendingUpload =>
      {AssignmentStatus.completed, AssignmentStatus.failed}.contains(next),
    AssignmentStatus.completed ||
    AssignmentStatus.failed ||
    AssignmentStatus.cancelled =>
      false,
    AssignmentStatus.reconciled => false,
  };
}
