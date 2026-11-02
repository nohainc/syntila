import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:syntila_workspace/cloud_connection.dart';
import 'package:syntila_workspace/work_request_input_staging.dart';
import 'package:syntila_workspace/worker_executor.dart';
import 'package:crypto/crypto.dart';
import 'package:syntila_workspace/space_directory.dart';
import 'package:syntila_workspace/thread_directory.dart';
import 'package:syntila_workspace/thread_path.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

import 'support/assignment_worker_fixture.dart';

void main() {
  test('materializes a 100 MB input and rejects one byte over', () async {
    final root = await Directory.systemTemp.createTemp('attachment-limit-');
    addTearDown(() => root.delete(recursive: true));
    final staging = WorkRequestInputStaging(Directory('${root.path}/staged'));
    const fileId = 'wrf-11111111-2222-3333-4444-555555555555';
    const size = 100000000;
    final bytes = Uint8List(size);
    final digest = 'sha256:${sha256.convert(bytes)}';
    await staging.stageStream(
        fileId: fileId,
        sizeBytes: size,
        contentDigest: digest,
        content: Stream.value(bytes));
    final work = Directory('${root.path}/work')..createSync();
    final handler = WorkerAssignmentHandler(
      threadDirectoryLifecycle: ThreadDirectoryLifecycle(
        pathResolver: ThreadPathResolver(work),
      ),
      inputStaging: staging,
      resolveLogicalWorker: (id) => assignmentWorker(id),
    );
    WorkspaceAssignmentContext context(int size) => WorkspaceAssignmentContext(
          workspaceId: 'workspace-1',
          workspaceRuntimeId: 'runtime-1',
          workerId: 'worker',
          runId: 'run',
          taskId: 'task',
          attemptId: 'attempt',
          assignmentId: 'assignment',
          idempotencyKey: 'key',
          payload: {
            'workerId': 'worker',
            'workerTypeId': 'test-worker',
            'spaceId': 'space',
            'threadId': 'thread',
            'executionClass': 'stateless_read',
            'workRequestId':
                'work-request-11111111-2222-3333-4444-555555555555',
            'input': {
              'attachments': [
                {
                  'kind': 'file',
                  'fileId': fileId,
                  'sizeBytes': size,
                  'contentDigest': digest,
                },
              ]
            },
          },
        );
    final scope = await handler.prepareAssignmentScope(context(size));
    final file = File('${scope.workingDirectory.path}/.syntila/inputs/'
        'work-request-11111111-2222-3333-4444-555555555555/file-001');
    expect(await file.length(), size);
    await expectLater(
        handler.prepareAssignmentScope(context(size + 1)), throwsStateError);
    expect(await file.length(), size);
  });

  test(
      'new Thread in an existing Space is not rejected by another Thread fence',
      () async {
    final root = await Directory.systemTemp.createTemp('space-thread-fence-');
    addTearDown(() => root.delete(recursive: true));
    final state = Directory('${root.path}/state');
    await Directory('${state.path}/space-fences').create(recursive: true);
    final legacyFence = File('${state.path}/space-fences/space-1.json');
    final legacyBytes = jsonEncode({
      'leaseId': 'lease-old-thread',
      'fencingToken': 23,
    });
    await legacyFence.writeAsString(legacyBytes);
    var executions = 0;
    var activeExecutions = 0;
    var maxActiveExecutions = 0;
    final executionGate = Completer<void>();
    final directories = <String>{};
    WorkerAssignmentHandler handler() => WorkerAssignmentHandler(
          applicationStateDirectory: state,
          spaceDirectoryLifecycle: SpaceDirectoryLifecycle(
            SpaceDirectoryResolver(
              workRoot: Directory('${root.path}/work'),
              registryDirectory: state,
            ),
          ),
          resolveLogicalWorker: (id) => assignmentWorker(id),
          executeWithToolProfile: (worker, directory, context, payload,
              {onProgress}) async {
            executions++;
            directories.add(directory.path);
            activeExecutions++;
            if (activeExecutions > maxActiveExecutions) {
              maxActiveExecutions = activeExecutions;
            }
            if (activeExecutions == 2 && !executionGate.isCompleted) {
              executionGate.complete();
            }
            if (context.assignmentId.contains('thread-a-25') ||
                context.assignmentId.contains('thread-b-3')) {
              await executionGate.future.timeout(
                const Duration(seconds: 2),
                onTimeout: () {},
              );
            } else {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            activeExecutions--;
            return WorkerResult(
              requestId: 'result-${context.assignmentId}',
              assignmentId: context.assignmentId,
              output: 'Executed',
            );
          },
        );
    WorkspaceAssignmentContext context(String threadId, int token) =>
        WorkspaceAssignmentContext(
          workspaceId: 'workspace-1',
          workspaceRuntimeId: 'runtime-1',
          workerId: 'worker-1',
          runId: 'run-1',
          taskId: 'task-1',
          attemptId: 'attempt-1',
          assignmentId: 'assignment-$threadId-$token',
          idempotencyKey: 'idem-$threadId-$token',
          payload: {
            'workerId': 'worker-1',
            'workerTypeId': 'test-worker',
            'spaceId': 'space-1',
            'threadId': threadId,
            'executionClass': 'stateful_thread',
            'leaseId': 'lease-$threadId-$token',
            'fencingToken': token,
          },
        );
    final first = handler();
    await first.call(context('thread-a', 24));
    await first.call(context('thread-b', 1));
    expect(executions, 2);
    // Restart: each Thread keeps its own monotonic fencing history.
    final restarted = handler();
    await expectLater(restarted.call(context('thread-a', 23)),
        throwsA(isA<SpaceMutationViolation>()));
    await expectLater(
        restarted.call(context('thread-b', 1).copyWith(
          payload: {
            ...context('thread-b', 1).payload,
            'leaseId': 'conflicting-lease'
          },
        )),
        throwsA(isA<SpaceMutationViolation>()));
    await restarted.call(context('thread-b', 2));
    expect(executions, 3);
    await Future.wait([
      restarted.call(context('thread-a', 25)),
      restarted.call(context('thread-b', 3)),
    ]);
    expect(executions, 5);
    expect(maxActiveExecutions, 2);
    expect(directories, hasLength(1));
    expect(await legacyFence.readAsString(), legacyBytes);
  });

  test('desktop lifecycle wiring executes Work with fencing enabled', () async {
    final root = await Directory.systemTemp.createTemp('direct-runtime-');
    addTearDown(() => root.delete(recursive: true));
    var executions = 0;
    final handler = WorkerAssignmentHandler(
      threadDirectoryLifecycle:
          ThreadDirectoryLifecycle(pathResolver: ThreadPathResolver(root)),
      resolveLogicalWorker: (id) => assignmentWorker(id),
      executeWithToolProfile: (worker, directory, context, payload,
          {onProgress}) async {
        executions++;
        expect(directory.path, contains('thread-1'));
        return WorkerResult(
            requestId: 'result-1',
            assignmentId: context.assignmentId,
            output: 'Work completed');
      },
    );
    WorkspaceAssignmentContext context(int fence) => WorkspaceAssignmentContext(
          workspaceId: 'workspace-1',
          workspaceRuntimeId: 'runtime-1',
          workerId: 'worker-1',
          runId: 'run-1',
          taskId: 'task-1',
          attemptId: 'attempt-1',
          assignmentId: 'assignment-1',
          idempotencyKey: 'idem-1',
          payload: {
            'workerId': 'worker-1',
            'workerTypeId': 'test-worker',
            'spaceId': 'space-1',
            'threadId': 'thread-1',
            'executionClass': 'stateful_thread',
            'leaseId': 'lease-1',
            'fencingToken': fence,
          },
        );
    expect((await handler.call(context(2))).output?['text'], 'Work completed');
    await expectLater(
        handler.call(context(1)), throwsA(isA<ThreadMutationViolation>()));
    expect(executions, 1);
  });
  test('assignment execution uses the Tool Profile Engine runner', () async {
    final directory =
        await Directory.systemTemp.createTemp('profile-assignment-');
    addTearDown(() => directory.delete(recursive: true));
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(
        workerId,
        workerTypeId: 'chatgpt',
      ),
      executeWithToolProfile: (worker, workingDirectory, context, payload,
              {onProgress}) async =>
          WorkerResult(
        requestId: 'engine-result',
        assignmentId: context.assignmentId,
        output: 'explain the change',
      ),
    );
    final result = await handler.call(const WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'runtime-1',
      workerId: 'workspace-worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-engine-1',
      idempotencyKey: 'idem-engine-1',
      payload: {
        'workerId': 'workspace-worker-1',
        'workerTypeId': 'chatgpt',
        'executionClass': 'stateless_read',
        'prompt': 'explain the change',
        'model': 'codex-latest',
        'timeoutMs': 60000,
      },
    ));
    expect(result.summary, 'explain the change');
    expect(result.output?['text'], 'explain the change');
  });

  test('resolves process CWD from Space and Thread IDs', () async {
    final root = await Directory.systemTemp.createTemp('cwd-root-');
    addTearDown(() => root.delete(recursive: true));
    final handler = WorkerAssignmentHandler(
      threadDirectoryLifecycle: ThreadDirectoryLifecycle(
        pathResolver: ThreadPathResolver(root),
      ),
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
    );
    final context = const WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'runtime-1',
      workerId: 'cwd-worker',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-cwd-1',
      idempotencyKey: 'idem-cwd-1',
      payload: {
        'workerId': 'cwd-worker',
        'workerTypeId': 'test-worker',
        'spaceId': 'space-1',
        'threadId': 'thread-1',
        'workRequestId': 'request-1',
        'executionClass': 'stateless_read',
      },
    );

    final scope = await handler.prepareAssignmentScope(context);
    final expected = await Directory(
      '${root.path}${Platform.pathSeparator}space-1${Platform.pathSeparator}thread-1',
    ).resolveSymbolicLinks();
    expect(scope.workingDirectory.path, expected);

    final sameThread = await handler.prepareAssignmentScope(
      context.copyWith(
        workerId: 'claude-worker',
        payload: {
          ...context.payload,
          'workerId': 'claude-worker',
          'workerTypeId': 'test-worker',
        },
      ),
    );
    final otherThread = await handler.prepareAssignmentScope(
      context.copyWith(
        payload: {
          ...context.payload,
          'threadId': 'thread-2',
        },
      ),
    );
    expect(sameThread.workingDirectory.path, expected);
    expect(otherThread.workingDirectory.path, isNot(expected));
  });

  test('resolves new executions to one shared Space directory', () async {
    final root = await Directory.systemTemp.createTemp('space-cwd-root-');
    addTearDown(() => root.delete(recursive: true));
    final handler = WorkerAssignmentHandler(
      spaceDirectoryLifecycle: SpaceDirectoryLifecycle(
        SpaceDirectoryResolver(
          workRoot: Directory('${root.path}/work'),
          registryDirectory: Directory('${root.path}/state'),
        ),
      ),
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
    );
    const base = WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'runtime-1',
      workerId: 'cwd-worker',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-space-cwd-1',
      idempotencyKey: 'idem-space-cwd-1',
      payload: {
        'workerId': 'cwd-worker',
        'workerTypeId': 'test-worker',
        'spaceId': 'space-1',
        'threadId': 'thread-1',
        'spaceName': 'Syntila',
        'executionClass': 'stateless_read',
      },
    );

    final first = await handler.prepareAssignmentScope(base);
    final second = await handler.prepareAssignmentScope(
      base.copyWith(payload: {
        ...base.payload,
        'threadId': 'thread-2',
      }),
    );
    expect(first.workingDirectory.path, second.workingDirectory.path);
    expect(first.workingDirectory.path, endsWith('Syntila'));
    expect(
        Directory('${root.path}/work/Syntila/thread-1').existsSync(), isFalse);
  });

  test('persists a repository checkout across runtime recreation', () async {
    final root =
        await Directory.systemTemp.createTemp('space-repository-root-');
    addTearDown(() => root.delete(recursive: true));
    SpaceDirectoryLifecycle lifecycle() => SpaceDirectoryLifecycle(
          SpaceDirectoryResolver(
            workRoot: Directory('${root.path}/work'),
            registryDirectory: Directory('${root.path}/state'),
          ),
        );
    WorkspaceAssignmentContext context(String spaceName) =>
        WorkspaceAssignmentContext(
          workspaceId: 'workspace-1',
          workspaceRuntimeId: 'runtime-1',
          workerId: 'repository-worker',
          runId: 'run-repository',
          taskId: 'task-repository',
          attemptId: 'attempt-repository',
          assignmentId: 'assignment-repository',
          idempotencyKey: 'idem-repository',
          payload: {
            'workerId': 'repository-worker',
            'workerTypeId': 'test-worker',
            'spaceId': 'space-repository',
            'threadId': 'thread-repository',
            'spaceName': spaceName,
            'executionClass': 'stateful_thread',
          },
        );

    final firstHandler = WorkerAssignmentHandler(
      spaceDirectoryLifecycle: lifecycle(),
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
    );
    final first = await firstHandler.prepareAssignmentScope(context('Syntila'));
    final repository = Directory(
        '${first.workingDirectory.path}${Platform.pathSeparator}checkout');
    await repository.create();
    await _runGit(repository, ['init', '-q']);
    await File('${repository.path}${Platform.pathSeparator}README.md')
        .writeAsString('persistent checkout\n');
    await _runGit(repository, ['add', 'README.md']);
    await _runGit(repository, [
      '-c',
      'user.email=test@example.com',
      '-c',
      'user.name=Syntila Test',
      'commit',
      '-qm',
      'initial'
    ]);

    final secondHandler = WorkerAssignmentHandler(
      spaceDirectoryLifecycle: lifecycle(),
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
    );
    final second = await secondHandler.prepareAssignmentScope(
      context('Renamed Syntila'),
    );
    expect(second.workingDirectory.path, first.workingDirectory.path);
    expect(
      await File('${repository.path}${Platform.pathSeparator}README.md')
          .readAsString(),
      'persistent checkout\n',
    );
    final status = await Process.run(
      'git',
      ['-C', repository.path, 'rev-parse', '--is-inside-work-tree'],
    );
    expect(status.exitCode, 0);
    expect(status.stdout.toString().trim(), 'true');
  });

  test('requires Thread identity for stateful process CWD', () async {
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
    );

    await expectLater(
      handler.prepareAssignmentScope(const WorkspaceAssignmentContext(
        workspaceId: 'workspace-1',
        workspaceRuntimeId: 'runtime-1',
        workerId: 'worker',
        runId: 'run-1',
        taskId: 'task-1',
        attemptId: 'attempt-1',
        assignmentId: 'assignment-stateful-cwd',
        idempotencyKey: 'idem-stateful-cwd',
        payload: {
          'workerId': 'worker',
          'workerTypeId': 'test-worker',
          'executionClass': 'stateful_thread',
        },
      )),
      throwsA(predicate(
          (error) => error.toString().contains('spaceId is required'))),
    );
  });

  test('applies the local Worker concurrency ceiling to its process spec',
      () async {
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(
        workerId,
        localConcurrencyLimit: 3,
      ),
    );
    final scope =
        await handler.prepareAssignmentScope(const WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'runtime-1',
      workerId: 'local-worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-concurrency-policy',
      idempotencyKey: 'idem-concurrency-policy',
      payload: {
        'workerId': 'local-worker-1',
        'workerTypeId': 'test-worker',
      },
    ));
    expect(scope.worker.localConcurrencyLimit, 3);
  });

  test('rejects a Cloud-supplied CWD', () async {
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(workerId),
    );

    await expectLater(
      handler.call(const WorkspaceAssignmentContext(
        workspaceId: 'workspace-1',
        workspaceRuntimeId: 'runtime-1',
        workerId: 'cwd-worker',
        runId: 'run-1',
        taskId: 'task-1',
        attemptId: 'attempt-1',
        assignmentId: 'assignment-cwd-rejected',
        idempotencyKey: 'idem-cwd-rejected',
        payload: {
          'workerId': 'cwd-worker',
          'workerTypeId': 'test-worker',
          'spaceId': 'space-1',
          'threadId': 'thread-1',
          'cwd': '/tmp/escape',
        },
      )),
      throwsA(predicate(
          (error) => error.toString().contains('alternate working directory'))),
    );
  });

  test('rejects assignment permissions not declared by the installed Worker',
      () async {
    final handler = WorkerAssignmentHandler(
      resolveLogicalWorker: (workerId) => assignmentWorker(
        workerId,
        permissions: {'repository:read'},
      ),
    );
    await expectLater(
      handler.call(const WorkspaceAssignmentContext(
        workspaceId: 'workspace-1',
        workspaceRuntimeId: 'workspace-1',
        workerId: 'worker-1',
        runId: 'run-1',
        taskId: 'task-1',
        attemptId: 'attempt-1',
        assignmentId: 'assignment-permission-denied',
        idempotencyKey: 'idem-permission-denied',
        payload: {
          'workerId': 'worker-1',
          'workerTypeId': 'test-worker',
          'permissions': ['shell:execute'],
        },
      )),
      throwsA(isA<AssignmentExecutionFailure>().having(
        (error) => error.code,
        'code',
        'permission_denied',
      )),
    );
  });
}

Future<void> _runGit(Directory workingDirectory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: workingDirectory.path,
  );
  if (result.exitCode != 0) {
    throw StateError('git failed: ${result.stderr}');
  }
}
