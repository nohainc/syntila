import 'dart:convert';
import 'package:test/test.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

void main() {
  test('external conversation input round trips and remains optional', () {
    ExecuteRequest frame({ExternalConversationInput? conversation}) =>
        ExecuteRequest(
          requestId: 'req-1',
          assignmentId: 'asg-1',
          prompt: 'Legacy prompt',
          timeoutMs: 1000,
          sessionPolicy: WorkerSessionPolicy.stateless,
          externalConversation: conversation,
        );
    final oldFrame = frame().toJson();
    expect(oldFrame.containsKey('externalConversation'), isFalse);
    final encoded = frame(
            conversation: ExternalConversationInput(
                request: 'hi',
                instructions: 'Reply briefly.',
                workflowId: 'chat',
                workflowVersion: 1,
                stepKind: 'chat'))
        .toJson();
    final decoded = ExecuteRequest.fromJson(encoded);
    expect(decoded.externalConversation?.request, 'hi');
    expect(decoded.externalConversation?.instructions, 'Reply briefly.');
    expect(decoded.prompt, 'Legacy prompt');
    expect(decoded.externalConversation?.workflowId, 'chat');
    expect(decoded.externalConversation?.workflowVersion, 1);
    expect(decoded.externalConversation?.stepKind, 'chat');
    expect(
        decoded.externalConversation!
            .withoutWorkflow()
            .toJson()
            .containsKey('workflow'),
        isFalse);
    final invalid = {
      ...encoded,
      'externalConversation': {
        'schemaVersion': 2,
        'request': 'hi',
        'instructions': 'x',
      }
    };
    expect(() => ExecuteRequest.fromJson(invalid), throwsFormatException);
  });
  test('Work execution context refreshes independently of history revisions',
      () {
    ConversationBootstrap context(String workflowId) => ConversationBootstrap(
        conversationId: 'C',
        contextRevision: 1,
        turnRevision: 2,
        throughSequence: 1,
        text: jsonEncode({
          'schemaVersion': 1,
          'kind': 'BootstrapContext',
          'conversationId': 'C',
          'throughSequence': 1,
          'history': [],
          'context': {},
          'conversationContext': {},
          'workflowExecutionContext': {
            'schemaVersion': 1,
            'workflowId': workflowId,
            'workRequestId': 'R',
            'activeStepId': 'VERIFY',
            'steps': [
              {'id': 'VERIFY', 'kind': 'verify', 'status': 'queued'}
            ],
            'prerequisiteResults': [
              {'stepId': 'IMPLEMENT', 'workerId': 'ChatGPT', 'text': 'Result'}
            ]
          }
        }));
    final delta = jsonDecode(context('direct').deltaAfter(1, 1)!) as Map;
    expect(
        (delta['workflowExecutionContext'] as Map)['activeStepId'], 'VERIFY');
    expect(
        ((delta['workflowExecutionContext'] as Map)['prerequisiteResults']
                as List)
            .single['text'],
        'Result');
    expect(delta['conversationContext'], isEmpty);
    expect(context('chat').deltaAfter(1, 1), isNull);
  });

  test(
      'structured workflow context survives delta and stateless execution transport',
      () {
    final context = ConversationBootstrap(
        conversationId: 'C',
        contextRevision: 2,
        turnRevision: 3,
        throughSequence: 4,
        text: jsonEncode({
          'schemaVersion': 1,
          'kind': 'BootstrapContext',
          'conversationId': 'C',
          'throughSequence': 4,
          'history': [],
          'context': {
            'objective': {'revision': 1, 'sequence': 1, 'value': 'Goal'},
            'summary': {'revision': 2, 'sequence': 4, 'value': null},
            'workflowState': {
              'revision': 2,
              'sequence': 4,
              'value': {
                'workflowId': 'chat',
                'workflowVersion': 1,
                'status': 'running'
              }
            },
            'constraints': {},
            'importantDecisions': {},
            'openIssues': {},
            'artifacts': {}
          }
        }));
    final delta = jsonDecode(context.deltaAfter(1, 1)!) as Map;
    expect(delta['kind'], 'DeltaContext');
    expect((delta['context'] as Map).containsKey('objective'), isFalse);
    expect(((delta['context'] as Map)['summary'] as Map)['value'], isNull);
    expect(
        (((delta['context'] as Map)['workflowState'] as Map)['value']
            as Map)['status'],
        'running');
    expect(context.deltaAfter(2, 4), isNull);
    final frame = ExecuteRequest(
        requestId: 'R',
        assignmentId: 'A',
        prompt: 'New request',
        timeoutMs: 1000,
        sessionPolicy: WorkerSessionPolicy.stateless,
        statelessContext: context);
    expect(
        (decodeWorkerFrame(frame.encode()) as ExecuteRequest)
            .statelessContext!
            .toJson(),
        context.toJson());
    expect(
        () => ExecuteRequest(
            requestId: 'R',
            assignmentId: 'A',
            prompt: 'New request',
            timeoutMs: 1000,
            sessionPolicy: WorkerSessionPolicy.durableSession,
            sessionKey: 'scope',
            statelessContext: context),
        throwsFormatException);
  });

  test(
      'canonical bootstrap round trips and rejects foreign scopes or oversized text',
      () {
    final bootstrap = ConversationBootstrap(
        conversationId: 'C',
        contextRevision: 0,
        throughSequence: 2,
        text: '{"history":[]}');
    final scope = WorkerSessionContext(
        id: 'S',
        conversationId: 'C',
        workerId: 'W',
        baseContextRevision: 0,
        bootstrap: bootstrap);
    expect(WorkerSessionContext.fromJson(scope.toJson()).bootstrap!.toJson(),
        bootstrap.toJson());
    expect(
        () => WorkerSessionContext(
            id: 'S',
            conversationId: 'other',
            workerId: 'W',
            baseContextRevision: 0,
            bootstrap: bootstrap),
        throwsFormatException);
    expect(
        () => WorkerSessionContext(
            id: 'S',
            conversationId: 'C',
            workerId: 'W',
            baseContextRevision: 1,
            bootstrap: bootstrap),
        throwsFormatException);
    expect(
        () => ConversationBootstrap(
            conversationId: 'C',
            contextRevision: 0,
            throughSequence: 0,
            text: 'x' * (256 * 1024 + 1)),
        throwsFormatException);
    expect(
        () => ConversationBootstrap.fromJson(
            {...bootstrap.toJson(), 'nativeSessionId': 'private'}),
        throwsFormatException);
  });

  test('delta carries only missed turns and newer artifact/context facts', () {
    final bootstrap = ConversationBootstrap(
        conversationId: 'C',
        contextRevision: 3,
        turnRevision: 4,
        throughSequence: 6,
        text: jsonEncode({
          'conversationId': 'C',
          'throughSequence': 6,
          'history': [
            {'sequence': 1, 'contextRevision': 1, 'kind': 'user_message'},
            {'sequence': 2, 'contextRevision': 1, 'kind': 'worker_response'},
            {'sequence': 3, 'contextRevision': 2, 'kind': 'user_message'},
            {'sequence': 4, 'contextRevision': 2, 'kind': 'worker_response'},
            {'sequence': 5, 'contextRevision': 1, 'kind': 'artifact_event'},
            {'sequence': 6, 'contextRevision': 0, 'kind': 'context_event'},
          ]
        }));
    final delta = jsonDecode(bootstrap.deltaAfter(1, 2)!) as Map;
    expect(
        (delta['history'] as List).map((entry) => (entry as Map)['sequence']),
        [3, 4, 5, 6]);
    expect(bootstrap.deltaAfter(3, 6), isNull);
    final bookkeeping = ConversationBootstrap(
        conversationId: 'C',
        contextRevision: 3,
        turnRevision: 4,
        throughSequence: 7,
        text: jsonEncode({
          'conversationId': 'C',
          'throughSequence': 7,
          'history': [
            {
              'sequence': 7,
              'contextRevision': 0,
              'kind': 'context_event',
              'eventType': 'context.revision_advanced'
            }
          ]
        }));
    expect(bookkeeping.deltaAfter(3, 6), isNull);

    final lateReply = ConversationBootstrap(
        conversationId: 'C',
        contextRevision: 3,
        turnRevision: 4,
        throughSequence: 7,
        text: jsonEncode({
          'conversationId': 'C',
          'throughSequence': 7,
          'history': [
            {
              'sequence': 7,
              'contextRevision': 1,
              'kind': 'worker_response',
              'metadata': {'workerSessionId': 'other-session'}
            }
          ]
        }));
    expect(lateReply.deltaAfter(3, 6, knownWorkerSessionId: 'own-session'),
        isNotNull);
    expect(lateReply.deltaAfter(3, 6, knownWorkerSessionId: 'other-session'),
        isNull);

    expect(ConversationBootstrap.fromJson(bootstrap.toJson()).turnRevision, 4);
    expect(
        () => ConversationBootstrap(
            conversationId: 'C',
            contextRevision: 3,
            turnRevision: 3,
            throughSequence: 0,
            text: '{}'),
        throwsFormatException);
    final malformed = ConversationBootstrap(
        conversationId: 'C',
        contextRevision: 0,
        turnRevision: 1,
        throughSequence: 1,
        text: '{"conversationId":"foreign","throughSequence":1,"history":[]}');
    expect(() => malformed.deltaAfter(0, 0), throwsFormatException);
  });

  test('session context carries only validated Syntila metadata', () {
    final context = WorkerSessionContext(
        id: 'session-A',
        conversationId: 'conversation-A',
        workerId: 'worker-A',
        baseContextRevision: 0);
    final frame = ExecuteRequest(
        requestId: 'R',
        assignmentId: 'A',
        prompt: 'Hello',
        timeoutMs: 1000,
        sessionPolicy: WorkerSessionPolicy.durableSession,
        sessionKey: 'scope-A',
        workerSession: context,
        model: 'model-A');
    final decoded = decodeWorkerFrame(frame.encode()) as ExecuteRequest;
    expect(
        () => ExecuteRequest.fromJson(
            {...frame.toJson(), 'workerSession': 'invalid'}),
        throwsFormatException);
    expect(decoded.workerSession!.toJson(), context.toJson());
    expect(jsonEncode(decoded.toJson()), isNot(contains('nativeSessionId')));
    expect(
        () => WorkerSessionContext.fromJson(
            {...context.toJson(), 'nativeSessionId': 'private'}),
        throwsFormatException);
    expect(
        () => WorkerSessionContext(
            id: 'S',
            conversationId: 'C',
            workerId: 'W',
            baseContextRevision: -1),
        throwsFormatException);
    expect(
        () => ExecuteRequest(
            requestId: 'R',
            assignmentId: 'A',
            prompt: 'Hello',
            timeoutMs: 1000,
            sessionPolicy: WorkerSessionPolicy.stateless,
            workerSession: context),
        throwsFormatException);
  });
}
