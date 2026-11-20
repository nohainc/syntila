import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Local state of one assignment. It only moves forward.
///
/// `starting` is written before the Engine process is created and `running`
/// after it exists, so after a crash the journal alone says whether an Engine
/// may have been started. A restarted Agent never starts the same attempt
/// twice: it settles it (see [AgentRuntime.recoverFromJournal]).
enum LocalStatus {
  received,
  accepted,
  starting,
  running,
  terminal,
  acknowledged,
}

enum TerminalKind { completed, failed, cancelled }

class JournalCorruptedException implements Exception {
  JournalCorruptedException(this.line, this.reason);
  final int line;
  final String reason;

  @override
  String toString() => 'the journal is damaged at line $line: $reason';
}

class IllegalTransitionException implements Exception {
  IllegalTransitionException(this.assignmentId, this.from, this.to);
  final String assignmentId;
  final LocalStatus? from;
  final LocalStatus to;

  @override
  String toString() =>
      'assignment $assignmentId cannot move from ${from?.name ?? 'nothing'} to ${to.name}';
}

/// The identifiers the server's fences are keyed on, plus a digest of the
/// immutable execution snapshot (Profile, model, permissions).
class AssignmentContext {
  const AssignmentContext({
    required this.runId,
    required this.taskId,
    required this.attemptId,
    required this.idempotencyKey,
    this.snapshotDigest,
  });

  final String runId;
  final String taskId;
  final String attemptId;
  final String idempotencyKey;
  final String? snapshotDigest;

  Map<String, Object?> toJson() => {
    'runId': runId,
    'taskId': taskId,
    'attemptId': attemptId,
    'idempotencyKey': idempotencyKey,
    if (snapshotDigest != null) 'snapshotDigest': snapshotDigest,
  };

  factory AssignmentContext.fromJson(Map<String, Object?> json) =>
      AssignmentContext(
        runId: json['runId'] as String,
        taskId: json['taskId'] as String,
        attemptId: json['attemptId'] as String,
        idempotencyKey: json['idempotencyKey'] as String,
        snapshotDigest: json['snapshotDigest'] as String?,
      );
}

class JournalEntry {
  JournalEntry({
    required this.assignmentId,
    required this.status,
    required this.context,
    required this.updatedAt,
    this.terminalKind,
    this.terminal,
    this.cancelRequested = false,
    this.engineStarts = 0,
    this.command,
    this.correlation = const {},
  });

  final String assignmentId;
  LocalStatus status;
  final AssignmentContext context;
  DateTime updatedAt;
  TerminalKind? terminalKind;
  Map<String, Object?>? terminal;
  bool cancelRequested;

  /// The command as received (correlation fields and payload). Kept until the
  /// assignment is terminal so a restarted Agent can run an admitted command
  /// that never started; dropped afterwards.
  Map<String, Object?>? command;

  /// The envelope correlation of the command (Workspace, runtime and Worker
  /// ids plus the run, task, attempt, assignment and idempotency ids). Every
  /// reply echoes it, so it stays after the assignment is terminal.
  Map<String, Object?> correlation;

  /// How many times an Engine start was recorded for this assignment. The
  /// invariant is `engineStarts <= 1`.
  int engineStarts;

  bool get isTerminal =>
      status == LocalStatus.terminal || status == LocalStatus.acknowledged;
}

/// Durable per-Worker record of every accepted command. Every write is
/// flushed to disk (fsync) before the call returns, and acceptance is only
/// acknowledged to the server after that.
class AgentJournal {
  AgentJournal(
    this.file, {
    DateTime Function()? clock,
    this.beforeWrite,
    this.afterWrite,
  }) : _clock = clock ?? DateTime.now;

  final File file;
  final DateTime Function() _clock;

  /// Test hooks that stand in for a process crash right before or right after
  /// a record is made durable. A hook that throws aborts the call.
  final FutureOr<void> Function(String assignmentId, String event)? beforeWrite;
  final FutureOr<void> Function(String assignmentId, String event)? afterWrite;

  final Map<String, JournalEntry> _entries = {};
  RandomAccessFile? _handle;
  int _seq = 0;
  Future<void> _queue = Future<void>.value();

  /// Replays the file. A partial last line (a crash mid-write) is dropped and
  /// truncated; damage anywhere else fails closed.
  Future<void> open() async {
    await file.parent.create(recursive: true);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      var validLength = bytes.length;
      final lastNewline = bytes.lastIndexOf(10);
      if (bytes.isNotEmpty && lastNewline != bytes.length - 1) {
        validLength = lastNewline + 1;
      }
      final text = utf8.decode(bytes.sublist(0, validLength));
      final lines = const LineSplitter().convert(text);
      for (var i = 0; i < lines.length; i++) {
        _apply(i + 1, lines[i]);
      }
      if (validLength != bytes.length) {
        final repair = await file.open(mode: FileMode.append);
        await repair.truncate(validLength);
        await repair.flush();
        await repair.close();
      }
    }
    _handle = await file.open(mode: FileMode.append);
  }

  void _apply(int lineNumber, String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      throw JournalCorruptedException(lineNumber, 'not valid JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw JournalCorruptedException(lineNumber, 'not an object');
    }
    final seq = decoded['seq'];
    final id = decoded['id'];
    final statusName = decoded['status'];
    final at = decoded['at'];
    if (seq is! int ||
        id is! String ||
        statusName is! String ||
        at is! String) {
      throw JournalCorruptedException(lineNumber, 'missing fields');
    }
    if (seq <= _seq) {
      throw JournalCorruptedException(lineNumber, 'sequence went backwards');
    }
    _seq = seq;
    final status = LocalStatus.values.asNameMap()[statusName];
    if (status == null) {
      throw JournalCorruptedException(lineNumber, 'unknown status');
    }
    final time = DateTime.tryParse(at);
    if (time == null) throw JournalCorruptedException(lineNumber, 'bad time');
    final existing = _entries[id];
    if (decoded['snapshot'] == true) {
      // Written by compaction: a complete entry in one record.
      final context = decoded['ctx'];
      if (context is! Map<String, Object?>) {
        throw JournalCorruptedException(lineNumber, 'snapshot without context');
      }
      _entries[id] = JournalEntry(
        assignmentId: id,
        status: status,
        context: AssignmentContext.fromJson(context),
        updatedAt: time,
        terminalKind: _kind(decoded['kind']),
        terminal: (decoded['terminal'] as Map?)?.cast<String, Object?>(),
        cancelRequested: decoded['cancel'] == true,
        engineStarts: decoded['starts'] as int? ?? 0,
        command: (decoded['cmd'] as Map?)?.cast<String, Object?>(),
        correlation:
            (decoded['corr'] as Map?)?.cast<String, Object?>() ?? const {},
      );
      return;
    }
    if (decoded['cancel'] == true && existing != null) {
      existing.cancelRequested = true;
      existing.updatedAt = time;
      if (decoded['intentOnly'] == true) return;
    }
    if (existing == null) {
      final context = decoded['ctx'];
      if (context is! Map<String, Object?>) {
        throw JournalCorruptedException(lineNumber, 'first record needs ctx');
      }
      _entries[id] = JournalEntry(
        assignmentId: id,
        status: status,
        context: AssignmentContext.fromJson(context),
        updatedAt: time,
        engineStarts: status == LocalStatus.starting ? 1 : 0,
        command: (decoded['cmd'] as Map?)?.cast<String, Object?>(),
        correlation:
            (decoded['corr'] as Map?)?.cast<String, Object?>() ?? const {},
      );
      return;
    }
    if (decoded['intentOnly'] == true) return;
    if (!_allowed(existing.status, status)) {
      throw JournalCorruptedException(
        lineNumber,
        'illegal move ${existing.status.name} -> ${status.name}',
      );
    }
    existing.status = status;
    existing.updatedAt = time;
    if (status == LocalStatus.starting) existing.engineStarts += 1;
    if (status == LocalStatus.terminal) {
      existing.terminalKind = _kind(decoded['kind']);
      existing.terminal = (decoded['terminal'] as Map?)
          ?.cast<String, Object?>();
      existing.command = null;
    }
  }

  static TerminalKind? _kind(Object? name) =>
      name is String ? TerminalKind.values.asNameMap()[name] : null;

  static bool _allowed(LocalStatus from, LocalStatus to) {
    if (from == to) return false;
    switch (from) {
      case LocalStatus.received:
        return to != LocalStatus.acknowledged;
      case LocalStatus.accepted:
        return to == LocalStatus.starting || to == LocalStatus.terminal;
      case LocalStatus.starting:
        return to == LocalStatus.running || to == LocalStatus.terminal;
      case LocalStatus.running:
        return to == LocalStatus.terminal;
      case LocalStatus.terminal:
        return to == LocalStatus.acknowledged;
      case LocalStatus.acknowledged:
        return false;
    }
  }

  JournalEntry? find(String assignmentId) => _entries[assignmentId];

  Iterable<JournalEntry> get entries => _entries.values;

  /// Entries the server has not acknowledged as terminal yet.
  List<JournalEntry> get unacknowledged =>
      _entries.values
          .where((e) => e.status != LocalStatus.acknowledged)
          .toList()
        ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));

  /// Moves an assignment to [status] and makes the record durable. The first
  /// record for an assignment must be `received` and carry [context].
  Future<JournalEntry> record(
    String assignmentId,
    LocalStatus status, {
    AssignmentContext? context,
    TerminalKind? kind,
    Map<String, Object?>? terminal,
    Map<String, Object?>? command,
    Map<String, Object?>? correlation,
  }) => _enqueue(() async {
    final existing = _entries[assignmentId];
    if (existing == null) {
      if (status != LocalStatus.received || context == null) {
        throw IllegalTransitionException(assignmentId, null, status);
      }
    } else if (!_allowed(existing.status, status)) {
      throw IllegalTransitionException(assignmentId, existing.status, status);
    }
    final event = status.name;
    await beforeWrite?.call(assignmentId, event);
    final record = <String, Object?>{
      'seq': _seq + 1,
      'at': _clock().toUtc().toIso8601String(),
      'id': assignmentId,
      'status': status.name,
      if (existing == null) 'ctx': context!.toJson(),
      if (existing == null && command != null) 'cmd': command,
      if (existing == null && correlation != null) 'corr': correlation,
      if (kind != null) 'kind': kind.name,
      if (terminal != null) 'terminal': terminal,
    };
    await _write(record);
    _apply(0, jsonEncode(record));
    await afterWrite?.call(assignmentId, event);
    return _entries[assignmentId]!;
  });

  /// Durable cancel intent. It survives a crash so the cancellation is
  /// reconciled before any start, even when it arrived while offline.
  Future<void> recordCancelIntent(String assignmentId) => _enqueue(() async {
    final existing = _entries[assignmentId];
    if (existing == null || existing.cancelRequested || existing.isTerminal) {
      return;
    }
    await beforeWrite?.call(assignmentId, 'cancel');
    final record = {
      'seq': _seq + 1,
      'at': _clock().toUtc().toIso8601String(),
      'id': assignmentId,
      'status': existing.status.name,
      'cancel': true,
      'intentOnly': true,
    };
    await _write(record);
    _apply(0, jsonEncode(record));
    await afterWrite?.call(assignmentId, 'cancel');
  });

  Future<void> _write(Map<String, Object?> record) async {
    final handle = _handle;
    if (handle == null) throw StateError('the journal is not open');
    await handle.writeString('${jsonEncode(record)}\n');
    await handle.flush(); // fsync
  }

  /// Drops acknowledged entries older than [hold]; a recent acknowledged entry
  /// stays so a replayed command is answered from the record. The rewrite is
  /// atomic (temporary file, fsync, rename).
  Future<int> compact({
    Duration hold = const Duration(hours: 24),
  }) => _enqueue(() async {
    final cutoff = _clock().subtract(hold);
    final keep = _entries.values
        .where(
          (e) =>
              e.status != LocalStatus.acknowledged ||
              e.updatedAt.isAfter(cutoff),
        )
        .toList();
    final dropped = _entries.length - keep.length;
    if (dropped == 0) return 0;
    final temp = File('${file.path}.compact');
    final out = await temp.open(mode: FileMode.write);
    var seq = 0;
    for (final entry in keep) {
      seq += 1;
      await out.writeString(
        '${jsonEncode({'seq': seq, 'at': entry.updatedAt.toUtc().toIso8601String(), 'id': entry.assignmentId, 'status': entry.status.name, 'snapshot': true, 'ctx': entry.context.toJson(), if (entry.terminalKind != null) 'kind': entry.terminalKind!.name, if (entry.terminal != null) 'terminal': entry.terminal, if (entry.cancelRequested) 'cancel': true, if (entry.command != null) 'cmd': entry.command, 'corr': entry.correlation, 'starts': entry.engineStarts})}\n',
      );
    }
    await out.flush();
    await out.close();
    await _handle?.close();
    await temp.rename(file.path);
    _handle = await file.open(mode: FileMode.append);
    _entries.removeWhere((id, e) => !keep.contains(e));
    _seq = seq;
    return dropped;
  });

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> close() async {
    await _queue;
    await _handle?.close();
    _handle = null;
  }

  /// Drops the file handle without any further write, as a killed process would.
  Future<void> abandon() async {
    await _handle?.close();
    _handle = null;
  }
}
