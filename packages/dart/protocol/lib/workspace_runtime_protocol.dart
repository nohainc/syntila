import 'dart:convert';

import 'syntila_protocol.dart';

const workspaceRuntimeProtocolName = 'syntila.workspace-runtime-protocol';
const workspaceRuntimeProtocolVersion = '5.1';
const workspaceRuntimeProtocolMaxMessageSizeBytes = 4194304;

const workspaceRuntimeMessageTypes = <String>{
  'workspace.hello',
  'workspace.hello.ack',
  'workspace.heartbeat',
  'workspace.heartbeat.ack',
  'workspace.sync.request',
  'workspace.sync.result',
  'workspace.status',
  'workspace.readiness',
  'workspace.update',
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
  'input.available',
};

class WorkspaceRuntimeMessage {
  WorkspaceRuntimeMessage._(this.value);

  final Map<String, Object?> value;

  String get type => value['type'] as String;
  Map<String, Object?> get payload =>
      Map<String, Object?>.from(value['payload'] as Map);

  static WorkspaceRuntimeMessage parse(Object? input) {
    final map = switch (input) {
      String text => _decode(text),
      Map value => Map<String, Object?>.from(value),
      _ => throw const ProtocolException('Workspace message must be an object'),
    };
    if (utf8.encode(jsonEncode(map)).length >
        workspaceRuntimeProtocolMaxMessageSizeBytes) {
      throw const ProtocolException('Workspace message exceeds the size limit');
    }
    _required(map, 'protocol');
    if (map['protocol'] != workspaceRuntimeProtocolName) {
      throw const ProtocolException('unsupported Workspace protocol name');
    }
    final version = _required(map, 'protocolVersion');
    if (!isCompatibleVersion(workspaceRuntimeProtocolVersion, version)) {
      throw const ProtocolException('unsupported Workspace protocol version');
    }
    _required(map, 'messageId');
    if (DateTime.tryParse(_required(map, 'timestamp')) == null) {
      throw const ProtocolException('timestamp is invalid');
    }
    final type = _required(map, 'type');
    if (!workspaceRuntimeMessageTypes.contains(type)) {
      throw ProtocolException('unsupported Workspace message type: $type');
    }
    if (map['payload'] is! Map) {
      throw const ProtocolException('Workspace payload must be an object');
    }
    if (type.startsWith('assignment.')) {
      for (final field in [
        'executionWorkspaceId',
        'workspaceRuntimeId',
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
    return WorkspaceRuntimeMessage._(map);
  }

  static Map<String, Object?> _decode(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const ProtocolException('Workspace message must be an object');
      }
      return Map<String, Object?>.from(decoded);
    } on FormatException {
      throw const ProtocolException('Workspace message is not valid JSON');
    }
  }

  static String _required(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty) {
      throw ProtocolException('Workspace $key is required');
    }
    return value;
  }
}
