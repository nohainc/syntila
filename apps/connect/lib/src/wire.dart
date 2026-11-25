import 'dart:convert';

/// Envelope construction and parsing for the Worker Agent gateway protocol.
const wireProtocol = 'syntila.worker-agent-protocol';
const wireProtocolVersion = '5.1';

/// The fields an assignment command carries and every reply must echo.
const correlationFields = [
  'executionWorkspaceId',
  'workspaceRuntimeId',
  'workerId',
  'runId',
  'taskId',
  'attemptId',
  'assignmentId',
  'idempotencyKey',
];

class MessageIds {
  int _sequence = 0;
  String next() =>
      'agent-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
}

Map<String, Object?> envelope(
  MessageIds ids,
  String type,
  Map<String, Object?> payload, {
  Map<String, Object?> correlation = const {},
  String? correlationId,
}) => {
  'protocol': wireProtocol,
  'protocolVersion': wireProtocolVersion,
  'messageId': ids.next(),
  if (correlationId != null) 'correlationId': correlationId,
  'timestamp': DateTime.now().toUtc().toIso8601String(),
  'type': type,
  'payload': payload,
  ...correlation,
};

/// The correlation block of a received assignment message, or null when a
/// required field is missing.
Map<String, Object?>? correlationOf(Map<String, Object?> message) {
  final result = <String, Object?>{};
  for (final field in correlationFields) {
    final value = message[field];
    if (value is! String || value.isEmpty) return null;
    result[field] = value;
  }
  return result;
}

Map<String, Object?>? decodeFrame(Object? raw) {
  if (raw is! String) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

String encodeFrame(Map<String, Object?> message) => jsonEncode(message);
