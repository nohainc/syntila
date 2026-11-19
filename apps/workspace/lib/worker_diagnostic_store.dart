import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'platform_runtime.dart';

/// Bounded JSONL logs for one Worker type. Files live beside Worker state,
/// outside immutable version directories so updates do not discard history.
final class WorkerDiagnosticStore {
  WorkerDiagnosticStore({
    required this.directory,
    this.maxFileBytes = 256 * 1024,
    this.maxFiles = 3,
    PlatformRuntime? platformRuntime,
  }) : _platformRuntime = platformRuntime ?? currentPlatformRuntime {
    if (maxFileBytes < 512) {
      throw ArgumentError.value(maxFileBytes, 'maxFileBytes', 'must be >= 512');
    }
    if (maxFiles < 1 || maxFiles > 10) {
      throw ArgumentError.value(maxFiles, 'maxFiles', 'must be from 1 to 10');
    }
  }

  final Directory directory;
  final int maxFileBytes;
  final int maxFiles;
  final PlatformRuntime _platformRuntime;

  static final Map<String, Future<void>> _writeQueues = {};
  static int _eventSequence = 0;
  File get currentFile => File('${directory.path}/worker.jsonl');

  Future<void> record({
    required String workerTypeId,
    required String workerVersion,
    required String protocolStage,
    required String event,
    String? eventId,
    String? requestId,
    String? assignmentId,
    String? workspaceId,
    String? workspaceRuntimeId,
    String? workerId,
    String? runId,
    String? taskId,
    String? attemptId,
    String component = 'workspace_service',
    String? operation,
    String? stage,
    bool retryable = false,
    String? workspaceVersion,
    String? engineVersion,
    String? profileDefinitionId,
    int? profileReleaseVersion,
    String? profileResolutionSource,
    String? probeStage,
    String? failureLayer,
    String level = 'info',
    String? providerToolName,
    String? providerToolVersion,
    int? durationMs,
    String? errorCode,
    int? processExitCode,
    Map<String, Object?> context = const {},
  }) {
    final diagnostic = DiagnosticEvent(
      eventId: eventId ?? _nextEventId(),
      timestamp: DateTime.now().toUtc().toIso8601String(),
      requestId: requestId,
      assignmentId: assignmentId,
      workspaceId: workspaceId,
      workspaceRuntimeId: workspaceRuntimeId,
      workerId: workerId,
      workerTypeId: workerTypeId,
      runId: runId,
      taskId: taskId,
      attemptId: attemptId,
      component: component,
      operation: operation ?? _operationFor(event),
      stage: stage ?? failureLayer ?? protocolStage,
      severity: _severity(level),
      errorCode: errorCode,
      retryable: retryable,
      context: {
        ...context,
        'workspaceVersion': workspaceVersion,
        'engineVersion': engineVersion,
        'profileDefinitionId': profileDefinitionId,
        'profileReleaseVersion': profileReleaseVersion,
        'profileResolutionSource': profileResolutionSource,
        'providerToolName': providerToolName,
        'providerToolVersion': providerToolVersion,
        'protocolStage': protocolStage,
        'failureLayer': failureLayer,
        'durationMs': durationMs,
        'processExitCode': processExitCode,
      },
    );
    final normalized = <String, Object?>{
      ...diagnostic.toJson(),
      // Preserve the existing local diagnostic fields for older readers.
      'timestamp': diagnostic.timestamp,
      'level': _safeLevel(level),
      'event': _safeEvent(event),
      'workerTypeId': _safeToken(workerTypeId, maxLength: 64),
      'workerVersion': _safeToken(workerVersion, maxLength: 64),
      'protocolStage': _safeToken(protocolStage, maxLength: 32),
      if (workspaceVersion != null)
        'workspaceVersion': _safeToken(workspaceVersion, maxLength: 64),
      if (engineVersion != null)
        'engineVersion': _safeToken(engineVersion, maxLength: 64),
      if (profileDefinitionId != null)
        'profileDefinitionId': _safeToken(profileDefinitionId, maxLength: 96),
      if (profileReleaseVersion != null && profileReleaseVersion > 0)
        'profileReleaseVersion': profileReleaseVersion,
      if (profileResolutionSource != null)
        'profileResolutionSource': _safeToken(
          profileResolutionSource,
          maxLength: 32,
        ),
      if (probeStage != null)
        'probeStage': _safeToken(probeStage, maxLength: 32),
      if (failureLayer != null)
        'failureLayer': _safeToken(failureLayer, maxLength: 32),
      if (runId != null) 'runId': _safeToken(runId, maxLength: 128),
      if (providerToolName != null)
        'providerToolName': _safeToken(providerToolName, maxLength: 64),
      if (providerToolVersion != null)
        'providerToolVersion': _safeToken(providerToolVersion, maxLength: 64),
      if (durationMs != null) 'durationMs': durationMs.clamp(0, 0x7fffffff),
      if (errorCode != null) 'errorCode': _safeToken(errorCode, maxLength: 64),
      if (processExitCode != null) 'processExitCode': processExitCode,
      if (context.isNotEmpty) 'context': _safeContext(context),
    };
    final line = '${jsonEncode(normalized)}\n';
    if (utf8.encode(line).length > maxFileBytes) {
      return Future.error(StateError('Worker diagnostic record exceeds limit'));
    }
    final key = directory.absolute.path;
    final previous = _writeQueues[key] ?? Future<void>.value();
    final queued = previous.catchError((_) {}).then((_) => _append(line));
    _writeQueues[key] = queued;
    return queued.whenComplete(() {
      if (identical(_writeQueues[key], queued)) _writeQueues.remove(key);
    });
  }

  /// Imports only stable event codes and explicitly safe scalar context from
  /// Worker JSONL. Free-form messages, stderr text, prompts and paths are
  /// deliberately discarded.
  Future<void> recordWorkerStderrLine(
    String line, {
    required String workerTypeId,
    required String workerVersion,
    required String protocolStage,
    String? runId,
    String? requestId,
    String? assignmentId,
    String? workspaceId,
    String? workspaceRuntimeId,
    String? workerId,
  }) async {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      final event = decoded['event'];
      final level = decoded['level'];
      final rawContext = decoded['context'];
      final context = rawContext is Map
          ? Map<String, Object?>.from(rawContext)
          : const <String, Object?>{};
      // Structured identity is accepted only as bounded correlation metadata;
      // arbitrary messages and context fields remain discarded.
      context.remove('assignmentId');
      context.remove('requestId');
      await record(
        workerTypeId: workerTypeId,
        workerVersion: workerVersion,
        protocolStage: protocolStage,
        workspaceVersion: _stringContext(context, 'workspaceVersion'),
        engineVersion: _stringContext(context, 'engineVersion'),
        profileDefinitionId: _stringContext(context, 'profileDefinitionId'),
        profileReleaseVersion: _intContext(context, 'profileReleaseVersion'),
        profileResolutionSource: _stringContext(
          context,
          'profileResolutionSource',
        ),
        probeStage: _stringContext(context, 'probeStage'),
        failureLayer: _stringContext(context, 'failureLayer'),
        event: event is String &&
                RegExp(r'^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+$')
                    .hasMatch(event)
            ? 'worker.$event'
            : 'worker.log.invalid_event',
        eventId:
            decoded['eventId'] is String ? decoded['eventId'] as String : null,
        requestId: requestId ?? _optionalToken(decoded['requestId']),
        assignmentId: assignmentId ?? _optionalToken(decoded['assignmentId']),
        workspaceId: workspaceId ?? _optionalToken(decoded['workspaceId']),
        workspaceRuntimeId:
            workspaceRuntimeId ?? _optionalToken(decoded['workspaceRuntimeId']),
        workerId: workerId ?? _optionalToken(decoded['workerId']),
        operation: _optionalToken(decoded['operation']),
        stage: _optionalToken(decoded['stage']),
        component: _optionalToken(decoded['component']) ?? 'cli_worker_engine',
        retryable: decoded['retryable'] == true,
        level: level is String ? level : 'info',
        runId: runId,
        providerToolName: _stringContext(context, 'providerToolName'),
        providerToolVersion: _stringContext(context, 'providerToolVersion'),
        durationMs: _intContext(context, 'durationMs'),
        errorCode: _stringContext(context, 'errorCode'),
        context: context,
      );
    } on Object {
      await record(
        workerTypeId: workerTypeId,
        workerVersion: workerVersion,
        protocolStage: protocolStage,
        event: 'worker.stderr.unstructured',
        runId: runId,
        context: {'lineBytes': utf8.encode(line).length},
      );
    }
  }

  Future<String> createCopyableReport({int maxCharacters = 16000}) async {
    if (maxCharacters < 512) {
      throw ArgumentError.value(
          maxCharacters, 'maxCharacters', 'must be >= 512');
    }
    final lines = <String>[];
    for (var index = maxFiles - 1; index >= 1; index--) {
      final file = File('${directory.path}/worker.jsonl.$index');
      if (await file.exists()) lines.addAll(await file.readAsLines());
    }
    if (await currentFile.exists()) {
      lines.addAll(await currentFile.readAsLines());
    }
    final safeLines = <String>[];
    for (final line in lines) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          safeLines.add(jsonEncode(_safeStoredRecord(decoded)));
        }
      } on Object {
        // Ignore incomplete/corrupt trailing records after a crash.
      }
    }
    final report = StringBuffer()
      ..writeln('Syntila Worker diagnostic report')
      ..writeln('Generated: ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln('Sensitive Worker input and free-form output are omitted.')
      ..writeln();
    for (final line in safeLines.reversed) {
      if (report.length + line.length + 1 > maxCharacters) break;
      report.writeln(line);
    }
    final output = report.toString();
    if (output.length <= maxCharacters) return output;
    return output.substring(0, maxCharacters);
  }

  /// Returns a bounded, allowlisted view of recent records for inclusion in a
  /// larger diagnostics export. The files are read newest-first and malformed
  /// or incomplete records are ignored so a crash cannot make reporting fail.
  Future<List<Map<String, Object?>>> readSafeRecords({
    int maxRecords = 50,
  }) async {
    if (maxRecords < 1) {
      throw ArgumentError.value(maxRecords, 'maxRecords', 'must be positive');
    }
    final files = <File>[];
    if (await currentFile.exists()) files.add(currentFile);
    for (var index = 1; index < maxFiles; index++) {
      final file = File('${directory.path}/worker.jsonl.$index');
      if (await file.exists()) files.add(file);
    }
    final records = <Map<String, Object?>>[];
    for (final file in files) {
      final lines = await file.readAsLines();
      for (final line in lines.reversed) {
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            records.add(_safeStoredRecord(decoded));
            if (records.length >= maxRecords) return records;
          }
        } on Object {
          // Ignore malformed or partially written records.
        }
      }
    }
    return records;
  }

  Future<void> _append(String line) async {
    await directory.create(recursive: true);
    await _platformRuntime.restrictPermissions(directory.path, directory: true);
    final bytes = utf8.encode(line);
    final file = currentFile;
    var currentLength = await file.exists() ? await file.length() : 0;
    if (currentLength > 0 &&
        await _hasIncompleteFinalRecord(file, currentLength)) {
      await _rotate();
      currentLength = 0;
    }
    if (currentLength + bytes.length > maxFileBytes) await _rotate();
    await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    await _platformRuntime.restrictPermissions(file.path, directory: false);
  }

  Future<void> _rotate() async {
    if (maxFiles == 1) {
      if (await currentFile.exists()) await currentFile.delete();
      return;
    }
    final oldest = File('${directory.path}/worker.jsonl.${maxFiles - 1}');
    if (await oldest.exists()) await oldest.delete();
    for (var index = maxFiles - 2; index >= 1; index--) {
      final source = File('${directory.path}/worker.jsonl.$index');
      if (await source.exists()) {
        await source.rename('${directory.path}/worker.jsonl.${index + 1}');
      }
    }
    if (await currentFile.exists()) {
      await currentFile.rename('${directory.path}/worker.jsonl.1');
    }
  }

  Future<bool> _hasIncompleteFinalRecord(File file, int length) async {
    final handle = await file.open(mode: FileMode.read);
    try {
      await handle.setPosition(length - 1);
      return await handle.readByte() != 10;
    } finally {
      await handle.close();
    }
  }

  static Map<String, Object?> _safeStoredRecord(Map<String, dynamic> value) {
    return {
      'schemaVersion': value['schemaVersion'] is int
          ? value['schemaVersion']
          : DiagnosticEvent.schemaVersion,
      if (value['eventId'] is String)
        'eventId': _safeToken(value['eventId'] as String, maxLength: 128),
      'timestamp': value['timestamp'] is String &&
              DateTime.tryParse(value['timestamp'] as String) != null
          ? value['timestamp']
          : 'unknown',
      'level': _safeLevel(value['level']?.toString() ?? 'info'),
      'event': _safeEvent(value['event']?.toString() ?? ''),
      if (value['requestId'] is String)
        'requestId': _safeToken(value['requestId'] as String, maxLength: 128),
      if (value['assignmentId'] is String)
        'assignmentId':
            _safeToken(value['assignmentId'] as String, maxLength: 128),
      if (value['workspaceId'] is String)
        'workspaceId':
            _safeToken(value['workspaceId'] as String, maxLength: 128),
      if (value['workspaceRuntimeId'] is String)
        'workspaceRuntimeId': _safeToken(
          value['workspaceRuntimeId'] as String,
          maxLength: 128,
        ),
      if (value['workerId'] is String)
        'workerId': _safeToken(value['workerId'] as String, maxLength: 128),
      'workerTypeId': _safeToken(
        value['workerTypeId']?.toString() ?? '',
        maxLength: 64,
      ),
      if (value['runId'] is String)
        'runId': _safeToken(value['runId'] as String, maxLength: 128),
      if (value['taskId'] is String)
        'taskId': _safeToken(value['taskId'] as String, maxLength: 128),
      if (value['attemptId'] is String)
        'attemptId': _safeToken(value['attemptId'] as String, maxLength: 128),
      'component': _safeToken(
        value['component']?.toString() ?? 'workspace_service',
        maxLength: 64,
      ),
      'operation': _safeToken(
        value['operation']?.toString() ?? 'diagnostic',
        maxLength: 64,
      ),
      'stage': _safeToken(
        value['stage']?.toString() ?? 'unknown',
        maxLength: 64,
      ),
      'severity': _severity(value['severity']?.toString() ?? 'info'),
      if (value['retryable'] is bool) 'retryable': value['retryable'],
      if (value['errorCode'] is String)
        'errorCode': _safeToken(value['errorCode'] as String, maxLength: 64),
      'workerVersion': _safeToken(
        value['workerVersion']?.toString() ?? '',
        maxLength: 64,
      ),
      'protocolStage': _safeToken(
        value['protocolStage']?.toString() ?? '',
        maxLength: 32,
      ),
      if (value['workspaceVersion'] is String)
        'workspaceVersion': _safeToken(
          value['workspaceVersion'] as String,
          maxLength: 64,
        ),
      if (value['engineVersion'] is String)
        'engineVersion': _safeToken(
          value['engineVersion'] as String,
          maxLength: 64,
        ),
      if (value['profileDefinitionId'] is String)
        'profileDefinitionId': _safeToken(
          value['profileDefinitionId'] as String,
          maxLength: 96,
        ),
      if (value['profileReleaseVersion'] is int &&
          (value['profileReleaseVersion'] as int) > 0)
        'profileReleaseVersion': value['profileReleaseVersion'],
      if (value['profileResolutionSource'] is String)
        'profileResolutionSource': _safeToken(
          value['profileResolutionSource'] as String,
          maxLength: 32,
        ),
      if (value['probeStage'] is String)
        'probeStage': _safeToken(value['probeStage'] as String, maxLength: 32),
      if (value['failureLayer'] is String)
        'failureLayer': _safeToken(
          value['failureLayer'] as String,
          maxLength: 32,
        ),
      if (value['providerToolName'] is String)
        'providerToolName': _safeToken(
          value['providerToolName'] as String,
          maxLength: 64,
        ),
      if (value['providerToolVersion'] is String)
        'providerToolVersion': _safeToken(
          value['providerToolVersion'] as String,
          maxLength: 64,
        ),
      if (value['durationMs'] is int)
        'durationMs': (value['durationMs'] as int).clamp(0, 0x7fffffff),
      if (value['processExitCode'] is int)
        'processExitCode': value['processExitCode'],
      if (value['context'] is Map)
        'context': _safeContext(
          Map<String, Object?>.from(value['context'] as Map),
        ),
    };
  }

  static Map<String, Object?> _safeContext(Map<String, Object?> context) {
    const fields = {
      'assignmentId',
      'requestId',
      'providerToolName',
      'providerToolVersion',
      'workspaceVersion',
      'engineVersion',
      'profileDefinitionId',
      'profileReleaseVersion',
      'profileDigest',
      'profileResolutionSource',
      'probeStage',
      'failureLayer',
      'durationMs',
      'elapsedMs',
      'cacheHit',
      'verified',
      'mcpPreparationMs',
      'remainingPreparationMs',
      'outputAgeMs',
      'errorCode',
      'protocolStage',
      'sessionPolicy',
      'processExitCode',
      'connectionState',
      'transport',
      'status',
      'modelId',
      'effort',
      'catalogRevision',
      'selectionSource',
      'lineBytes',
      'httpStatusCode',
      'recovered',
      'traceStage',
      'traceEpochId',
      'monotonicMs',
      'clockOffsetMs',
      'clockRttMs',
      'syncState',
      'localQueueLength',
      'activeAssignments',
      'probeId',
    };
    return {
      for (final entry in context.entries)
        if (fields.contains(entry.key) &&
            (entry.value is String ||
                entry.value is num ||
                entry.value is bool))
          entry.key: entry.value is String
              ? _safeText(entry.value as String, maxLength: 128)
              : entry.value,
    };
  }

  static String _nextEventId() {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    _eventSequence = (_eventSequence + 1) & 0xFFFF;
    return 'diag-$now-$_eventSequence';
  }

  static String _operationFor(String event) {
    final first = event.split('.').first;
    return first.isEmpty ? 'diagnostic' : first;
  }

  static String _severity(String level) => switch (level.toLowerCase()) {
        'warn' || 'warning' => 'warning',
        'debug' => 'debug',
        'error' => 'error',
        _ => 'info',
      };

  static String? _optionalToken(Object? value) {
    if (value is! String || value.isEmpty || value.length > 128) return null;
    return RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value) ? value : null;
  }

  static String? _stringContext(Map<String, Object?> context, String key) {
    final value = context[key];
    return value is String ? value : null;
  }

  static int? _intContext(Map<String, Object?> context, String key) {
    final value = context[key];
    return value is int ? value : null;
  }

  static String _safeLevel(String value) =>
      SafeProviderDiagnostics.safeLevel(value);

  static String _safeEvent(String value) =>
      SafeProviderDiagnostics.safeEvent(value);

  static String _safeToken(String value, {required int maxLength}) =>
      SafeProviderDiagnostics.safeToken(value, maxLength: maxLength);

  static String _safeText(String value, {required int maxLength}) {
    final safe = _redact(value.replaceAll(RegExp(r'[\r\n\t]'), ' '));
    return safe.length <= maxLength ? safe : safe.substring(0, maxLength);
  }

  static String _redact(String value) => SafeProviderDiagnostics.redact(value);
}
