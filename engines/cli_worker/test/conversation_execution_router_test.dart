import 'dart:convert';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:syntila_cli_worker_engine/src/conversation_execution_router.dart';
import 'package:syntila_cli_worker_engine/src/worker_session.dart';
import 'package:test/test.dart';

void main() {
  const router = ConversationExecutionRouter();
  final bootstrap = ConversationBootstrap(
    conversationId: 'C',
    contextRevision: 1,
    turnRevision: 2,
    throughSequence: 2,
    text: jsonEncode({
      'conversationId': 'C',
      'throughSequence': 2,
      'history': [
        {
          'sequence': 1,
          'contextRevision': 1,
          'kind': 'user_message',
          'text': 'Prior question',
        },
        {
          'sequence': 2,
          'contextRevision': 1,
          'kind': 'worker_response',
          'text': 'Prior answer',
        },
      ],
    }),
  );
  WorkerSession stored(int revision, int sequence) => WorkerSession(
    id: 'S',
    conversationId: 'C',
    workerId: 'W',
    profileId: 'profile',
    profileVersion: 1,
    nativeSessionId: 'native',
    synchronizedContextRevision: revision,
    synchronizedHistorySequence: sequence,
    status: 'active',
    lastModelId: 'model-x',
    lastEffort: 'medium',
    createdAt: 'now',
    lastUsedAt: 'now',
  );
  ExecuteRequest request({bool context = true}) => ExecuteRequest(
    requestId: 'R',
    assignmentId: 'A',
    prompt: 'New question',
    timeoutMs: 10000,
    sessionPolicy: WorkerSessionPolicy.durableSession,
    sessionKey: 'key',
    model: 'model-y',
    reasoningEffort: 'high',
    workerSession: WorkerSessionContext(
      id: 'S',
      conversationId: 'C',
      workerId: 'W',
      baseContextRevision: 1,
      bootstrap: context ? bootstrap : null,
    ),
  );

  test(
    'runtime router separates all five continuity actions from provider invocation',
    () {
      final current = router.prepare(
        request(),
        nativeSessionId: 'native',
        storedSession: stored(1, 2),
      );
      expect(current.action, ConversationExecutionAction.continueSession);
      expect(current.prompt, 'New question');
      final sync = router.prepare(
        request(),
        nativeSessionId: 'native',
        storedSession: stored(0, 0),
      );
      expect(sync.action, ConversationExecutionAction.syncAndContinue);
      expect(sync.prompt, contains('Canonical Syntila conversation context'));
      expect(sync.prompt, contains('Prior answer'));
      expect(
        router.prepare(request()).action,
        ConversationExecutionAction.bootstrapSession,
      );
      final replacement = router.prepare(
        request(),
        storedSession: stored(1, 2),
        reconstruct: true,
      );
      expect(
        replacement.action,
        ConversationExecutionAction.reconstructSession,
      );
      expect(replacement.prompt, contains(bootstrap.text));
      final stateless = router.prepare(
        ExecuteRequest(
          requestId: 'R',
          assignmentId: 'A',
          prompt: 'New question',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.stateless,
          statelessContext: bootstrap,
        ),
      );
      expect(stateless.action, ConversationExecutionAction.statelessExecution);
      expect(stateless.prompt, contains('Prior question'));
      expect(bootstrap.contextRevision, 1);
      expect(stored(1, 2).synchronizedContextRevision, 1);
    },
  );

  test(
    'missing canonical reconstruction context is rejected before execution',
    () {
      expect(
        () => router.prepare(request(context: false)),
        throwsFormatException,
      );
      expect(
        () => router.prepare(
          request(context: false),
          nativeSessionId: 'native',
          reconstruct: true,
        ),
        throwsFormatException,
      );
    },
  );

  test('a resumed session receives a synthesis from a different session', () {
    final researchHistory = ConversationBootstrap(
      conversationId: 'C',
      contextRevision: 2,
      turnRevision: 3,
      throughSequence: 4,
      text: jsonEncode({
        'conversationId': 'C',
        'throughSequence': 4,
        'history': [
          {
            'sequence': 3,
            'contextRevision': 2,
            'kind': 'user_message',
            'text': 'Research question',
          },
          {
            'sequence': 4,
            'contextRevision': 2,
            'kind': 'worker_response',
            'text': 'Synthesis outcome',
            'metadata': {'workerSessionId': 'research-synthesis-session'},
          },
        ],
      }),
    );
    final next = ExecuteRequest(
      requestId: 'next',
      assignmentId: 'next-assignment',
      prompt: 'Follow up',
      timeoutMs: 10000,
      sessionPolicy: WorkerSessionPolicy.durableSession,
      sessionKey: 'key',
      workerSession: WorkerSessionContext(
        id: 'S',
        conversationId: 'C',
        workerId: 'W',
        baseContextRevision: 2,
        bootstrap: researchHistory,
      ),
    );
    expect(router.prepare(next).prompt, contains('Synthesis outcome'));
    final resumed = router.prepare(
      next,
      nativeSessionId: 'native',
      storedSession: stored(1, 2),
    );
    expect(resumed.action, ConversationExecutionAction.syncAndContinue);
    expect(resumed.prompt, contains('Synthesis outcome'));
    // A result can arrive after this session already consumed that revision.
    final late = router.prepare(
      next,
      nativeSessionId: 'native',
      storedSession: stored(2, 3),
    );
    expect(late.action, ConversationExecutionAction.syncAndContinue);
    expect(late.prompt, contains('Synthesis outcome'));
  });
}
