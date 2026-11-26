import 'dart:math';

/// Latency trace stages, mirroring `TRACE_STAGES` in `@syntila/protocol`.
/// The first twelve are numbered T1-T12 in order; the rest are auxiliary.
const List<String> diagnosticTraceStages = [
  'web_submitted',
  'cloud_accepted',
  'workflow_dispatch_started',
  'gateway_queued',
  'service_received',
  'service_accepted',
  'profile_resolved',
  'slot_reserved',
  'engine_process_created',
  'provider_started',
  'terminal_persisted',
  'web_received',
];
const List<String> diagnosticAuxiliaryTraceStages = [
  'workflow_completed',
  'provider_first_output',
  'provider_last_output_reported',
  'provider_process_exited',
  'engine_result_received',
  'service_result_persisted',
  'service_result_sending',
  'cloud_ack_received',
  'workflow_observed_terminal',
  'probe_sent',
  'probe_acknowledged',
  // Local startup milestones between Service admission and provider start.
  'worker_resolved',
  'profile_ready',
  'waiting_for_space',
  'queued_for_slot',
  'engine_initialized',
];

/// Versioned, provider-neutral evidence emitted by the execution pipeline.
///
/// The event is deliberately small and allowlisted. It is suitable for local
/// JSONL storage and for forwarding to Cloud without carrying prompts,
/// provider output, credentials, or local paths.
final class DiagnosticEvent {
  DiagnosticEvent({
    required this.eventId,
    required this.timestamp,
    required this.component,
    required this.operation,
    required this.stage,
    required this.severity,
    this.requestId,
    this.assignmentId,
    this.workerId,
    this.workerTypeId,
    this.runId,
    this.taskId,
    this.attemptId,
    this.errorCode,
    this.retryable = false,
    Map<String, Object?> context = const {},
  }) : context = sanitizeContext(context) {
    _requireToken(eventId, 'eventId', 128);
    _requireTimestamp(timestamp);
    _requireToken(component, 'component', 64);
    _requireToken(operation, 'operation', 64);
    _requireToken(stage, 'stage', 64);
    if (!const {'debug', 'info', 'warning', 'error'}.contains(severity)) {
      throw ArgumentError.value(severity, 'severity');
    }
    for (final entry in <String?, String>{
      requestId: 'requestId',
      assignmentId: 'assignmentId',
      workerId: 'workerId',
      workerTypeId: 'workerTypeId',
      runId: 'runId',
      taskId: 'taskId',
      attemptId: 'attemptId',
      errorCode: 'errorCode',
    }.entries) {
      if (entry.key != null) _requireToken(entry.key!, entry.value, 128);
    }
  }

  factory DiagnosticEvent.create({
    required String component,
    required String operation,
    required String stage,
    required String severity,
    String? requestId,
    String? assignmentId,
    String? workerId,
    String? workerTypeId,
    String? runId,
    String? taskId,
    String? attemptId,
    String? errorCode,
    bool retryable = false,
    Map<String, Object?> context = const {},
  }) =>
      DiagnosticEvent(
        eventId: _newEventId(),
        timestamp: DateTime.now().toUtc().toIso8601String(),
        component: component,
        operation: operation,
        stage: stage,
        severity: severity,
        requestId: requestId,
        assignmentId: assignmentId,
        workerId: workerId,
        workerTypeId: workerTypeId,
        runId: runId,
        taskId: taskId,
        attemptId: attemptId,
        errorCode: errorCode,
        retryable: retryable,
        context: context,
      );

  factory DiagnosticEvent.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported diagnostic event schema');
    }
    String requiredString(String key, {int maxLength = 128}) {
      final value = json[key];
      if (value is! String ||
          value.trim().isEmpty ||
          value.length > maxLength) {
        throw FormatException('$key must be a bounded non-empty string');
      }
      return value;
    }

    final severity = requiredString('severity', maxLength: 16);
    if (!const {'debug', 'info', 'warning', 'error'}.contains(severity)) {
      throw const FormatException('severity is invalid');
    }
    final retryable = json['retryable'];
    if (retryable is! bool) throw const FormatException('retryable is invalid');
    return DiagnosticEvent(
      eventId: requiredString('eventId'),
      timestamp: requiredString('timestamp', maxLength: 64),
      requestId: _optionalString(json, 'requestId'),
      assignmentId: _optionalString(json, 'assignmentId'),
      workerId: _optionalString(json, 'workerId'),
      workerTypeId: _optionalString(json, 'workerTypeId'),
      runId: _optionalString(json, 'runId'),
      taskId: _optionalString(json, 'taskId'),
      attemptId: _optionalString(json, 'attemptId'),
      component: requiredString('component', maxLength: 64),
      operation: requiredString('operation', maxLength: 64),
      stage: requiredString('stage', maxLength: 64),
      severity: severity,
      errorCode: _optionalString(json, 'errorCode'),
      retryable: retryable,
      context: json['context'] is Map
          ? Map<String, Object?>.from(json['context'] as Map)
          : const {},
    );
  }

  static const int schemaVersion = 1;
  final String eventId;
  final String timestamp;
  final String? requestId;
  final String? assignmentId;
  final String? workerId;
  final String? workerTypeId;
  final String? runId;
  final String? taskId;
  final String? attemptId;
  final String component;
  final String operation;
  final String stage;
  final String severity;
  final String? errorCode;
  final bool retryable;
  final Map<String, Object?> context;

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'eventId': eventId,
        'timestamp': timestamp,
        if (requestId != null) 'requestId': requestId,
        if (assignmentId != null) 'assignmentId': assignmentId,
        if (workerId != null) 'workerId': workerId,
        if (workerTypeId != null) 'workerTypeId': workerTypeId,
        if (runId != null) 'runId': runId,
        if (taskId != null) 'taskId': taskId,
        if (attemptId != null) 'attemptId': attemptId,
        'component': component,
        'operation': operation,
        'stage': stage,
        'severity': severity,
        if (errorCode != null) 'errorCode': errorCode,
        'retryable': retryable,
        if (context.isNotEmpty) 'context': context,
      };

  /// Context fields are intentionally a closed list. Unknown fields and
  /// nested objects are discarded instead of relying on best-effort redaction.
  static Map<String, Object?> sanitizeContext(Map<String, Object?> input) {
    const allowed = {
      'connectVersion',
      'engineVersion',
      'profileDefinitionId',
      'profileReleaseVersion',
      'profileResolutionSource',
      'profileDigest',
      'providerToolName',
      'providerToolVersion',
      'protocolStage',
      'failureLayer',
      'processExitCode',
      'durationMs',
      'outputAgeMs',
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
      'queuePosition',
      'slotLimit',
      'queueWaitTimeoutMs',
      'waitingForSession',
    };
    final result = <String, Object?>{};
    for (final entry in input.entries) {
      if (!allowed.contains(entry.key)) continue;
      final value = entry.value;
      if (value is String) {
        final normalized = value.replaceAll(RegExp(r'[\r\n\t]'), ' ');
        result[entry.key] =
            normalized.length > 128 ? normalized.substring(0, 128) : normalized;
      } else if (value is num || value is bool) {
        result[entry.key] = value;
      }
    }
    return Map.unmodifiable(result);
  }

  static String? _optionalString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String || value.trim().isEmpty || value.length > 128) {
      throw FormatException('$key must be a bounded non-empty string');
    }
    return value;
  }

  static void _requireToken(String value, String name, int maxLength) {
    if (value.isEmpty ||
        value.length > maxLength ||
        !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) {
      throw ArgumentError.value(value, name, 'must be a safe bounded token');
    }
  }

  static void _requireTimestamp(String value) {
    if (DateTime.tryParse(value)?.isUtc != true) {
      throw ArgumentError.value(value, 'timestamp', 'must be a UTC timestamp');
    }
  }

  static String _newEventId() {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final suffix = Random.secure().nextInt(0xFFFFFF).toRadixString(16);
    return 'diag-$now-$suffix';
  }
}
