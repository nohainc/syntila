import 'dart:convert';

import 'syntila_protocol.dart';
import 'provider_failure.dart';

const workerAgentProtocolName = 'syntila.worker-agent-protocol';
const workerAgentProtocolVersion = '5.1';
const workerAgentProtocolMaxMessageSizeBytes = 4194304;
const workerAgentProbePayloadCapability = 'agent.probe_payload.v1';
const diagnosticProbeEchoMaxChars = 65536;
final _base64AsciiPattern = RegExp(r'^[A-Za-z0-9+/]+=*$');

const workerAgentMessageTypes = <String>{
  'agent.hello',
  'agent.hello.ack',
  'agent.heartbeat',
  'agent.heartbeat.ack',
  'agent.sync.request',
  'agent.sync.result',
  'agent.status',
  'agent.readiness',
  'agent.update',
  'worker.inventory',
  'thread.status',
  'assignment.start',
  'assignment.start.ack',
  'assignment.startup',
  'assignment.start.permit.request',
  'assignment.start.permit.grant',
  'assignment.ack',
  'assignment.activity',
  'assignment.result',
  'assignment.error',
  'assignment.cancel',
  'assignment.cancel.ack',
  'assignment.cancelled',
  'diagnostic.probe',
  'diagnostic.probe.ack',
  'worker.usage.request',
  'worker.usage.result',
  'mcp.tool_call.request',
  'mcp.tool_call.result',
  'mcp.tool_call.status.request',
  'mcp.tool_call.status.result',
  'mcp.inventory',
  'input.available',
};

class WorkerAgentMessage {
  WorkerAgentMessage._(this.value);

  final Map<String, Object?> value;

  String get type => value['type'] as String;
  Map<String, Object?> get payload =>
      Map<String, Object?>.from(value['payload'] as Map);

  static WorkerAgentMessage parse(Object? input) {
    final map = switch (input) {
      String text => _decode(text),
      Map value => Map<String, Object?>.from(value),
      _ => throw const ProtocolException('Worker Agent message must be an object'),
    };
    if (utf8.encode(jsonEncode(map)).length >
        workerAgentProtocolMaxMessageSizeBytes) {
      throw const ProtocolException('Worker Agent message exceeds the size limit');
    }
    _required(map, 'protocol');
    if (map['protocol'] != workerAgentProtocolName) {
      throw const ProtocolException('unsupported Worker Agent protocol name');
    }
    final version = _required(map, 'protocolVersion');
    if (!isCompatibleVersion(workerAgentProtocolVersion, version)) {
      throw const ProtocolException('unsupported Worker Agent protocol version');
    }
    _required(map, 'messageId');
    if (DateTime.tryParse(_required(map, 'timestamp')) == null) {
      throw const ProtocolException('timestamp is invalid');
    }
    final type = _required(map, 'type');
    if (!workerAgentMessageTypes.contains(type)) {
      throw ProtocolException('unsupported Worker Agent message type: $type');
    }
    if (map['payload'] is! Map) {
      throw const ProtocolException('Worker Agent payload must be an object');
    }
    if (type.startsWith('assignment.')) {
      for (final field in [
        'workerId',
        'runId',
        'taskId',
        'attemptId',
        'assignmentId',
        'idempotencyKey',
      ]) {
        _required(map, field);
      }
    }
    if (type == 'assignment.error') {
      final payloadMap = Map<String, Object?>.from(map['payload'] as Map);
      if (payloadMap.containsKey('providerFailureUnavailable') &&
          (payloadMap['providerFailureUnavailable'] != true ||
              payloadMap.containsKey('providerFailure'))) {
        throw const ProtocolException('Invalid providerFailureUnavailable');
      }
      if (payloadMap.containsKey('providerFailure')) {
        final details = payloadMap['providerFailure'];
        if (details is! Map) {
          throw const ProtocolException('providerFailure must be an object');
        }
        try {
          ProviderFailureDetails.fromJson(Map<String, Object?>.from(details));
        } on FormatException catch (error) {
          throw ProtocolException(error.message);
        }
      }
    }
    if (type == 'diagnostic.probe' || type == 'diagnostic.probe.ack') {
      final payloadMap = Map<String, Object?>.from(map['payload'] as Map);
      final echo = payloadMap['echo'];
      if (echo != null &&
          (echo is! String ||
              echo.isEmpty ||
              echo.length > diagnosticProbeEchoMaxChars ||
              !_base64AsciiPattern.hasMatch(echo))) {
        throw const ProtocolException(
          'diagnostic probe echo must be base64 of at most 65536 characters',
        );
      }
    }
    return WorkerAgentMessage._(map);
  }

  static Map<String, Object?> _decode(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const ProtocolException('Worker Agent message must be an object');
      }
      return Map<String, Object?>.from(decoded);
    } on FormatException {
      throw const ProtocolException('Worker Agent message is not valid JSON');
    }
  }

  static String _required(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty) {
      throw ProtocolException('Agent message $key is required');
    }
    return value;
  }
}
