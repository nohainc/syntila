import 'dart:async';
import 'dart:io';

import 'package:syntila_workspace/assignment_startup.dart';
import 'package:syntila_workspace/cli_worker_engine_supervisor.dart'
    show CliWorkerEngineSupervisor;
import 'package:syntila_workspace/cloud_connection.dart';
import 'package:syntila_workspace/space_directory.dart';
import 'package:syntila_workspace/worker_executor.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

import 'support/assignment_worker_fixture.dart';

WorkspaceAssignmentContext _statefulContext(
  String assignmentId,
  String threadId,
  int token, {
  int? queueWaitTimeoutMs,
}) =>
    WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'runtime-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: assignmentId,
      idempotencyKey: 'idem-$assignmentId',
      payload: {
        'workerId': 'worker-1',
        'workerTypeId': 'test-worker',
        'spaceId': 'space-1',
        'threadId': threadId,
        'executionClass': 'stateful_thread',
        'leaseId': 'lease-$threadId-$token',
        'fencingToken': token,
        if (queueWaitTimeoutMs != null)
          'queueWaitTimeoutMs': queueWaitTimeoutMs,
      },
    );

void main() {
  late Directory root;
  late Completer<void> releaseFirst;
  late List<String> executed;
  late List<(String, AssignmentStartupStage)> stages;
  late Map<String, Object?> lastPayload;
  late WorkerAssignmentHandler handler;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('space-wait-');
    releaseFirst = Completer<void>();
    executed = [];
    stages = [];
    lastPayload = {};
    final state = Directory('${root.path}/state');
    handler = WorkerAssignmentHandler(
      applicationStateDirectory: state,
      spaceDirectoryLifecycle: SpaceDirectoryLifecycle(
        SpaceDirectoryResolver(
          workRoot: Directory('${root.path}/work'),
          registryDirectory: state,
        ),
      ),
      resolveLogicalWorker: (id) => assignmentWorker(id),
      onStartupStage: (context, stage, detail) =>
          stages.add((context.assignmentId, stage)),
      executeWithToolProfile: (worker, directory, context, payload,
          {onProgress}) async {
        executed.add(context.assignmentId);
        lastPayload = payload;
        if (context.assignmentId == 'first') await releaseFirst.future;
        return WorkerResult(
          requestId: 'result-${context.assignmentId}',
          assignmentId: context.assignmentId,
          output: context.assignmentId,
        );
      },
    );
  });

  tearDown(() async {
    if (!releaseFirst.isCompleted) releaseFirst.complete();
    await root.delete(recursive: true);
  });

  Future<void> firstHoldsTheLock() async {
    unawaited(handler
        .call(_statefulContext('first', 'thread-a', 1))
        .then<void>((_) {}, onError: (_) {}));
    for (var i = 0; i < 200 && !executed.contains('first'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(executed, contains('first'));
  }

  test('a waiting assignment is visible, cancellable and launches nothing',
      () async {
    await firstHoldsTheLock();
    final waiting = handler.call(_statefulContext('second', 'thread-a', 1));
    final expectation = expectLater(
      waiting,
      throwsA(isA<AssignmentExecutionFailure>()
          .having((error) => error.code, 'code', 'cancelled')),
    );
    // Wait for observable readiness rather than assuming filesystem/lock
    // setup completes within 50 ms under a component-suite load.
    final waitingStage = ('second', AssignmentStartupStage.waitingForSpace);
    final deadline = Stopwatch()..start();
    while (!stages.contains(waitingStage) &&
        deadline.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(stages, contains(waitingStage));

    final stopwatch = Stopwatch()..start();
    expect(await handler.cancel('second', 'user cancelled'), isTrue);
    await expectation;
    // The wait ended at once; the first assignment still holds the lock.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(releaseFirst.isCompleted, isFalse);

    releaseFirst.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // The abandoned wait never reached the Worker executor.
    expect(executed, ['first']);
  });

  test('the wait counts against the local queue allowance', () async {
    await firstHoldsTheLock();
    await expectLater(
      handler.call(
          _statefulContext('second', 'thread-a', 1, queueWaitTimeoutMs: 200)),
      throwsA(isA<AssignmentExecutionFailure>()
          .having((error) => error.code, 'code', 'timeout')
          .having((error) => error.retryable, 'retryable', isTrue)
          .having((error) => error.message, 'message',
              contains('Another request in this Space was still running'))
          .having((error) => error.localDiagnostic, 'diagnostic',
              contains('space_wait'))),
    );
    releaseFirst.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(executed, ['first']);
  });

  test('the Engine receives only the allowance left after the Space wait',
      () async {
    await firstHoldsTheLock();
    final second = handler.call(
        _statefulContext('second', 'thread-a', 1, queueWaitTimeoutMs: 5000));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    releaseFirst.complete();
    expect((await second).summary, isNotEmpty);
    final remaining = lastPayload['queueWaitTimeoutMs'] as int;
    expect(remaining, lessThan(5000));
    expect(remaining, greaterThan(100));
  });

  test('the default allowance matches the Engine supervisor default', () {
    expect(defaultAssignmentQueueAllowance,
        CliWorkerEngineSupervisor.defaultQueueWaitTimeout);
  });
}
