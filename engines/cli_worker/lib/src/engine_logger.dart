import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

class EngineLogger {
  const EngineLogger({this.writeLine});

  final void Function(String line)? writeLine;

  void log(
    String level,
    String event, {
    Map<String, Object?> context = const {},
    String? operation,
    String? stage,
    bool retryable = false,
  }) {
    final safe = <String, Object?>{};
    for (final key in const {
      'conversationRoute',
      'conversationId',
      'workerSessionId',
      'baseContextRevision',
      'synchronizedContextRevision',
      'targetContextRevision',
      'synchronizedHistorySequence',
      'throughSequence',
      'requestId',
      'assignmentId',
      'workerId',
      'runId',
      'taskId',
      'attemptId',
      'workerTypeId',
      'engineVersion',
      'profileDefinitionId',
      'profileReleaseVersion',
      'profileDigest',
      'profileSchemaVersion',
      'providerToolName',
      'providerToolVersion',
      'profileResolutionSource',
      'probeStage',
      'failureLayer',
      'durationMs',
      'errorCode',
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
    }) {
      final value = context[key];
      if (value is String || value is num || value is bool) {
        safe[key] = value is String ? _captureDiagnostic(value) : value;
      }
    }
    final diagnostic = DiagnosticEvent.create(
      component: 'cli_worker_engine',
      operation: _token(operation) ?? _token(event.split('.').first) ?? 'event',
      stage: _token(stage) ?? _token(context['failureLayer']) ?? 'execute',
      severity: switch (level.toLowerCase()) {
        'debug' => 'debug',
        'error' => 'error',
        'warn' || 'warning' => 'warning',
        _ => 'info',
      },
      requestId: _token(context['requestId']),
      assignmentId: _token(context['assignmentId']),
      workerId: _token(context['workerId']),
      workerTypeId: _token(context['workerTypeId']),
      runId: _token(context['runId']),
      taskId: _token(context['taskId']),
      attemptId: _token(context['attemptId']),
      errorCode: _token(context['errorCode']),
      retryable: retryable || context['retryable'] == true,
      context: context,
    );
    final line = jsonEncode({
      ...diagnostic.toJson(),
      'timestamp': diagnostic.timestamp,
      'level': const {'debug', 'info', 'warning', 'error'}.contains(level)
          ? level
          : 'info',
      'event': event,
      'context': safe,
    });
    final writer = writeLine;
    if (writer == null) {
      stderr.writeln(line);
    } else {
      writer(line);
    }
  }

  static String? _token(Object? value) {
    if (value is! String || value.isEmpty || value.length > 128) return null;
    return RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value) ? value : null;
  }
}

String _captureDiagnostic(String value) {
  final safe = value
      .replaceAll(
        RegExp(r'(bearer\s+)[a-z0-9._~+/-]+=*', caseSensitive: false),
        r'$1[REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'''(["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|cookie|authorization|secret)["']?\s*[:=]\s*["'])([^"']*)(["'])|(["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|cookie|authorization|secret)["']?\s*[:=]\s*)([^\s,}&]+)''',
          caseSensitive: false,
        ),
        r'$1[REDACTED]$3$4[REDACTED]',
      );
  return safe.length <= 128 ? safe : safe.substring(0, 128);
}
