import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('validates assignment provider failure details', () {
    final envelope = <String, Object?>{
      'protocol': workspaceRuntimeProtocolName,
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'message',
      'timestamp': '2026-01-01T00:00:00Z',
      'type': 'assignment.error',
      for (final field in [
        'executionWorkspaceId',
        'workspaceRuntimeId',
        'workerId',
        'runId',
        'taskId',
        'attemptId',
        'assignmentId',
        'idempotencyKey'
      ])
        field: 'id',
      'payload': {
        'providerFailure': {
          'schemaVersion': 1,
          'source': 'stderr',
          'providerErrorText': 'ошибка',
          'failedRunResponse': 'partial'
        }
      },
    };
    expect(WorkspaceRuntimeMessage.parse(envelope).type, 'assignment.error');
    final details = envelope['payload'];
    envelope['payload'] = {'providerFailureUnavailable': true};
    expect(WorkspaceRuntimeMessage.parse(envelope).type, 'assignment.error');
    envelope['payload'] = {'providerFailureUnavailable': false};
    expect(() => WorkspaceRuntimeMessage.parse(envelope),
        throwsA(isA<ProtocolException>()));
    envelope['payload'] = {
      ...(details as Map<String, Object?>),
      'providerFailureUnavailable': true,
    };
    expect(() => WorkspaceRuntimeMessage.parse(envelope),
        throwsA(isA<ProtocolException>()));
    envelope['payload'] = {
      'providerFailure': {
        'schemaVersion': 1,
        'source': 'stderr',
        'providerErrorText': 'x' * 4097
      }
    };
    expect(() => WorkspaceRuntimeMessage.parse(envelope),
        throwsA(isA<ProtocolException>()));
  });
  test('maps unknown execution errors to the generic failure code', () {
    expect(canonicalExecutionErrorCode('unknown'), equals('execution_failed'));
    expect(executionErrorMessage('timeout'), isNotEmpty);
  });

  test('collaboration streams accept 1.1 without an execution Workspace', () {
    final event = RealtimeEvent.parse({
      'eventId': 'e',
      'type': 'discussion.created',
      'version': '1.1',
      'timestamp': '2026-10-06T00:00:00.000Z',
      'sequence': 1,
      'stream': {'kind': 'space', 'id': 'same'},
      'spaceId': 'same',
      'threadId': 'W',
      'payload': {'entityId': 'm', 'threadId': 'W'},
    });
    expect(event.workspaceId, isNull);
    expect(event.streamKey, '["space","same"]');
    expect(RealtimeEvent.parse(event.encode()).payload['entityId'], 'm');
    expect(
        () => RealtimeEvent.parse({...event.toJson(), 'workspaceId': 'same'}),
        throwsA(isA<ProtocolException>()));
    expect(
        () => RealtimeEvent.parse({
              ...event.toJson(),
              'payload': {'entityId': 'm', 'threadId': 'W', 'text': 'history'}
            }),
        throwsA(isA<ProtocolException>()));
    expect(() => RealtimeEvent.parse({...event.toJson(), 'version': '1.0'}),
        throwsA(isA<ProtocolException>()));
  });
  test('legacy execution events infer an independent stream key', () {
    final event = RealtimeEvent.parse({
      'eventId': 'e',
      'type': 'step.running',
      'version': '1.0',
      'timestamp': '2026-10-06T00:00:00.000Z',
      'workspaceId': 'same',
      'sequence': 1,
      'payload': {'workRequestId': 'R', 'threadId': 'W', 'stepKind': 'test'}
    });
    expect(event.streamKey, '["execution_workspace","same"]');
  });
  test('round trips durable and ephemeral realtime events', () {
    final event = RealtimeEvent.parse({
      'eventId': 'event-1',
      'type': 'run.completed',
      'version': '1.0',
      'timestamp': '2026-09-23T10:00:00.000Z',
      'workspaceId': 'workspace-1',
      'sequence': 7,
      'payload': <String, Object?>{
        'entityId': 'run-1',
        'status': 'completed',
      },
    });
    expect(RealtimeEvent.parse(event.encode()).type, equals('run.completed'));
    expect(durableRealtimeEventTypes, contains('run.completed'));
    expect(ephemeralRealtimeEventTypes, contains('stream.delta'));
  });

  test('accepts Worker Activity and classifies it as ephemeral',
      () {
    final event = {
      'eventId': 'activity-1',
      'type': 'assignment.activity',
      'version': '1.0',
      'timestamp': '2026-09-23T10:00:00.000Z',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'runtime-1',
      'assignmentId': 'assignment-1',
      'attemptId': 'attempt-1',
      'sequence': 7,
      'payload': <String, Object?>{
        'entityId': 'assignment-1',
        'workerId': 'chatgpt',
        'sourceEventId': 'source-1',
        'executionId': 'execution-1',
        'activitySequence': 1,
        'activityType': 'tool.started',
        'activityStatus': 'running',
        'title': 'Running tool',
      },
    };
    final parsed = RealtimeEvent.parse(event);
    expect(isReplayableRealtimeEvent(parsed.toJson()), isFalse);
    expect(ephemeralRealtimeEventTypes, contains('assignment.activity'));
  });

  test('accepts Worker activity on its Space stream', () {
    final event = {
      'eventId': 'event',
      'type': 'assignment.activity',
      'version': '1.1',
      'timestamp': '2026-11-21T12:00:00.000Z',
      'sequence': 1,
      'spaceId': 'space',
      'threadId': 'thread',
      'stream': {'kind': 'space', 'id': 'space'},
      'assignmentId': 'assignment',
      'attemptId': 'attempt',
      'payload': {
        'entityId': 'assignment',
        'workerId': 'chatgpt',
        'sourceEventId': 'source',
        'executionId': 'execution',
        'activitySequence': 1,
        'activityType': 'tool.started',
        'activityStatus': 'running',
        'title': 'Reading files',
      },
    };
    expect(RealtimeEvent.parse(event).type, 'assignment.activity');
    expect(() => RealtimeEvent.parse({...event, 'threadId': null}),
        throwsA(isA<ProtocolException>()));
  });

  test('validates optional base64 echo on diagnostic.probe messages', () {
    expect(workspaceProbePayloadCapability, 'workspace.probe_payload.v1');
    expect(diagnosticProbeEchoMaxChars, 65536);

    Map<String, Object?> envelope(String type, Map<String, Object?> payload) =>
        {
          'protocol': workspaceRuntimeProtocolName,
          'protocolVersion': workspaceRuntimeProtocolVersion,
          'messageId': 'msg-1',
          'timestamp': '2026-10-12T12:00:00.000Z',
          'type': type,
          'payload': payload,
        };

    expect(
      WorkspaceRuntimeMessage.parse(envelope('diagnostic.probe', {
        'probeId': 'p1',
        'sentAt': '2026-10-12T12:00:00.000Z',
      })).type,
      'diagnostic.probe',
    );
    expect(
      WorkspaceRuntimeMessage.parse(envelope('diagnostic.probe', {
        'probeId': 'p1',
        'sentAt': '2026-10-12T12:00:00.000Z',
        'echo': 'YWJjZA==',
      })).payload['echo'],
      'YWJjZA==',
    );
    expect(
      WorkspaceRuntimeMessage.parse(envelope('diagnostic.probe.ack', {
        'probeId': 'p1',
        'receivedAt': '2026-10-12T12:00:00.000Z',
        'ackedAt': '2026-10-12T12:00:00.001Z',
        'echo': 'A' * diagnosticProbeEchoMaxChars,
      })).type,
      'diagnostic.probe.ack',
    );

    for (final invalidEcho in <Object>[
      '',
      'not base64!',
      '====',
      'A' * (diagnosticProbeEchoMaxChars + 1),
      42,
    ]) {
      expect(
        () => WorkspaceRuntimeMessage.parse(envelope('diagnostic.probe', {
          'probeId': 'p1',
          'sentAt': '2026-10-12T12:00:00.000Z',
          'echo': invalidEcho,
        })),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => WorkspaceRuntimeMessage.parse(envelope('diagnostic.probe.ack', {
          'probeId': 'p1',
          'receivedAt': '2026-10-12T12:00:00.000Z',
          'ackedAt': '2026-10-12T12:00:00.001Z',
          'echo': invalidEcho,
        })),
        throwsA(isA<ProtocolException>()),
      );
    }
  });
}
