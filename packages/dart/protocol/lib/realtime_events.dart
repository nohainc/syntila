import 'dart:convert';

import 'syntila_protocol.dart';

bool isReplayableRealtimeEvent(Map<String, Object?> event) {
  final type = event['type'];
  return type is String && durableRealtimeEventTypes.contains(type);
}

class RealtimeEvent {
  RealtimeEvent._(this.value);

  final Map<String, Object?> value;

  String get eventId => value['eventId']! as String;
  String get type => value['type']! as String;
  String get version => value['version']! as String;
  String? get workspaceId => value['workspaceId'] as String?;
  Map<String, Object?> get stream => value['stream'] is Map
      ? Map<String, Object?>.from(value['stream'] as Map)
      : {'kind': 'execution_workspace', 'id': workspaceId};
  String get streamKey => jsonEncode([stream['kind'], stream['id']]);
  int get sequence => value['sequence']! as int;
  Map<String, Object?> get payload =>
      Map<String, Object?>.from(value['payload']! as Map);

  Map<String, Object?> toJson() => Map<String, Object?>.from(value);
  String encode() => jsonEncode(value);

  static RealtimeEvent parse(Object? input) {
    final decoded = switch (input) {
      String text => _decode(text),
      Map value => Map<String, Object?>.from(value),
      _ => throw const ProtocolException('Realtime event must be an object'),
    };
    for (final key in const [
      'eventId',
      'type',
      'version',
      'timestamp',
      'sequence',
      'payload',
    ]) {
      if (!decoded.containsKey(key)) {
        throw ProtocolException('Realtime event $key is required');
      }
    }
    _requiredString(decoded, 'eventId');
    _requiredString(decoded, 'type');
    final version = _requiredString(decoded, 'version');
    if (!RegExp(r'^\d+\.\d+$').hasMatch(version) ||
        !isCompatibleVersion('1.0', version)) {
      throw ProtocolException('unsupported realtime event version: $version');
    }
    if (DateTime.tryParse(_requiredString(decoded, 'timestamp')) == null) {
      throw const ProtocolException('Realtime event timestamp is invalid');
    }
    final rawStream = decoded['stream'];
    if (rawStream != null) {
      if (rawStream is! Map ||
          rawStream.keys.any((key) => key != 'kind' && key != 'id')) {
        throw const ProtocolException('Realtime stream is invalid');
      }
      final stream = Map<String, Object?>.from(rawStream);
      final kind = _requiredString(stream, 'kind');
      final streamId = _requiredString(stream, 'id');
      if (!realtimeStreamKinds.contains(kind)) {
        throw const ProtocolException('Realtime stream kind is invalid');
      }
      if (kind == 'execution_workspace') {
        if (_requiredString(decoded, 'workspaceId') != streamId) {
          throw const ProtocolException(
            'Execution stream must match workspaceId',
          );
        }
      } else {
        if (decoded.containsKey('workspaceId') || version == '1.0') {
          throw const ProtocolException(
            'Synchronization streams require 1.1 and no workspaceId',
          );
        }
        if (kind == 'space' && decoded['spaceId'] != streamId) {
          throw const ProtocolException('Space stream must match spaceId');
        }
      }
    } else {
      _requiredString(decoded, 'workspaceId');
    }
    if (decoded['sequence'] is! int || (decoded['sequence'] as int) < 0) {
      throw const ProtocolException('Realtime event sequence is invalid');
    }
    final payload = decoded['payload'];
    if (payload is! Map) {
      throw const ProtocolException('Realtime event payload must be an object');
    }
    if (collaborationRealtimeEventTypes.contains(decoded['type'])) {
      if (rawStream is! Map || rawStream['kind'] == 'execution_workspace') {
        throw const ProtocolException(
          'Collaboration requires a synchronization stream',
        );
      }
      _requiredString(decoded, 'spaceId');
      _requiredString(Map<String, Object?>.from(payload), 'entityId');
      if (payload.keys.any((key) => key != 'entityId' && key != 'threadId')) {
        throw const ProtocolException(
          'Collaboration payloads contain identifiers only',
        );
      }
      if ((decoded['type'] as String).startsWith('thread.') ||
          (decoded['type'] as String).startsWith('discussion.')) {
        if (_requiredString(decoded, 'threadId') != payload['threadId']) {
          throw const ProtocolException('Thread signal identity mismatch');
        }
      }
    } else if ((durableRealtimeEventTypes.contains(decoded['type']) ||
            ephemeralRealtimeEventTypes.contains(decoded['type'])) &&
        decoded['workspaceId'] == null &&
        !(rawStream is Map &&
            rawStream['kind'] == 'space' &&
            (decoded['type'] == 'assignment.activity' ||
                (decoded['type'] as String).startsWith('work_request.') ||
                (decoded['type'] as String).startsWith('step.')))) {
      throw const ProtocolException('Execution events require workspaceId');
    }
    if (decoded['type'] == 'assignment.activity') {
      _requiredString(decoded, 'assignmentId');
      _requiredString(decoded, 'attemptId');
      if (decoded['workspaceId'] != null) {
        _requiredString(decoded, 'workspaceRuntimeId');
      } else {
        _requiredString(decoded, 'threadId');
      }
      final activity = Map<String, Object?>.from(payload);
      if (_requiredString(activity, 'entityId') != decoded['assignmentId']) {
        throw const ProtocolException(
          'Worker Activity entity does not match assignment',
        );
      }
      _requiredString(activity, 'workerId');
      _requiredString(activity, 'sourceEventId');
      _requiredString(activity, 'executionId');
      final activitySequence = activity['activitySequence'];
      if (activitySequence is! int || activitySequence < 1) {
        throw const ProtocolException('Worker Activity sequence is invalid');
      }
      _requiredString(activity, 'activityType');
      _requiredString(activity, 'activityStatus');
      _requiredString(activity, 'title');
    } else if (decoded['workspaceId'] == null &&
        ((decoded['type'] as String).startsWith('work_request.') ||
            (decoded['type'] as String).startsWith('step.'))) {
      final work = Map<String, Object?>.from(payload);
      _requiredString(work, 'threadId');
      _requiredString(work, 'workRequestId');
    }
    const allowedPayloadFields = {
      'entityId',
      'status',
      'message',
      'summary',
      'text',
      'delta',
      'tool',
      'artifactId',
      'workerId',
      'workRequestId',
      'threadId',
      'stepKind',
      'leaseId',
      'percentage',
      'durationMs',
      'tokenCount',
      'coalesced',
      'sourceEventId',
      'executionId',
      'activityId',
      'activitySequence',
      'activityType',
      'activityStatus',
      'title',
      'details',
    };
    if (payload.keys.any((key) => !allowedPayloadFields.contains(key))) {
      throw const ProtocolException(
        'Realtime event payload contains an unsupported or secret field',
      );
    }
    if ((payload['delta'] is String &&
            (payload['delta'] as String).length > 8192) ||
        (payload['text'] is String &&
            (payload['text'] as String).length > 32768)) {
      throw const ProtocolException('Realtime event payload is too large');
    }
    if (decoded['type'] == 'assignment.activity') {
      final details = payload['details'];
      if (details != null && details is! Map) {
        throw const ProtocolException('Worker Activity details are invalid');
      }
      if (details is Map && details.length > 32) {
        throw const ProtocolException('Worker Activity details are too large');
      }
      if (jsonEncode(payload).length > 16 * 1024) {
        throw const ProtocolException('Worker Activity payload is too large');
      }
    }
    return RealtimeEvent._(decoded);
  }

  static Map<String, Object?> _decode(String text) {
    try {
      final value = jsonDecode(text);
      if (value is! Map) {
        throw const ProtocolException('Realtime event must be an object');
      }
      return Map<String, Object?>.from(value);
    } on FormatException {
      throw const ProtocolException('Realtime event is not valid JSON');
    }
  }

  static String _requiredString(Map<String, Object?> value, String key) {
    final item = value[key];
    if (item is! String || item.trim().isEmpty) {
      throw ProtocolException('Realtime event $key is required');
    }
    return item;
  }
}
