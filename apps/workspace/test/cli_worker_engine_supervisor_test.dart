import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/cli_worker_engine_supervisor.dart';
import 'package:syntila_workspace/tool_profile_release_verifier.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test(
      'External Worker fields are sent only when the Engine advertises support',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final executor = WorkerExecutor(
      pluginId: 'example',
      version: '1.0.0',
      manifestDigest: 'a' * 64,
      artifactSha256: 'b' * 64,
      executable: '/bin/echo',
      dataDirectory: setup.state.path,
      protocol: 'mcp',
      toolPins: {'syntila.execute': 'c' * 64},
    );
    Future<Map> run(String id, {bool large = false}) async {
      await setup.supervisor.execute(
        null,
        pluginExecutor: executor,
        pluginWorkerTypeId: 'plugin-0123456789ab',
        stateDirectory: setup.state,
        workingDirectory: setup.thread,
        workerId: 'worker-external',
        maxConcurrentAssignments: 1,
        assignmentId: id,
        prompt: large ? 'p' * 400000 : 'Legacy prompt',
        externalConversation: ExternalConversationInput(
            request: 'hi',
            instructions: large ? 'i' * 450000 : 'Reply briefly.'),
        timeout: const Duration(seconds: 10),
        sessionPolicy: WorkerSessionPolicy.stateless,
        statelessContext: large
            ? ConversationBootstrap(
                conversationId: 'conversation',
                contextRevision: 1,
                throughSequence: 1,
                text: 'c' * 230000,
              )
            : null,
      );
      return jsonDecode(
              await File('${setup.state.path}/request-$id.json').readAsString())
          as Map;
    }

    final oldEngine = await run('old-engine');
    expect(oldEngine.containsKey('externalConversation'), isFalse);
    await File('${setup.state.path}/supports-external-conversation')
        .writeAsString('yes');
    final newEngine = await run('new-engine');
    expect(newEngine['externalConversation'], {
      'schemaVersion': 1,
      'request': 'hi',
      'instructions': 'Reply briefly.',
    });
    expect(newEngine['prompt'], 'Legacy prompt');
    final largeFrame = await run('large-frame', large: true);
    expect(largeFrame.containsKey('externalConversation'), isFalse);
    expect((largeFrame['prompt'] as String).length, 400000);
  });
  test('official Workers receive the original prompt without external fields',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final result = await _execute(
      setup,
      'official-conversation',
      prompt: 'Original provider prompt',
      externalConversation: ExternalConversationInput(
          request: 'hi', instructions: 'Reply conversationally.'),
    );
    expect(result.output, 'Original provider prompt');
    final request = jsonDecode(await File(
      '${setup.state.path}/request-official-conversation.json',
    ).readAsString()) as Map;
    expect(request.containsKey('externalConversation'), isFalse);
  });
  test('Engine VM service banners do not corrupt protocol framing', () async {
    final setup = await _setup(enableVmService: true);
    addTearDown(() => setup.root.delete(recursive: true));
    expect((await _execute(setup, 'vm-banner')).output, 'vm-banner');
  });

  test(
    'reaps only registered Engine processes after restart',
    () async {
      final root = await Directory.systemTemp.createTemp('engine-recovery-');
      addTearDown(() => root.delete(recursive: true));
      final state = Directory('${root.path}/worker-state');
      await state.create();

      Future<Process> startLoop(String name) async {
        final process = await Process.start(
          '/bin/sh',
          [
            '-c',
            'while :; do sleep 30; done',
            name,
            '--state-directory',
            state.path
          ],
        );
        // Never leave a loop behind, even when an assertion fails first.
        addTearDown(() => Process.killPid(process.pid, ProcessSignal.sigkill));
        return process;
      }

      final registered = await startLoop('syntila-engine-test');
      final unrelated = await startLoop('syntila-engine-test');
      final registry = Directory('${root.path}/runtime');
      await registry.create();
      await File('${registry.path}/assignment.worker-process.json')
          .writeAsString(jsonEncode({
        'pid': registered.pid,
        'executable': File('/bin/sh').absolute.path,
        'stateDirectory': state.path,
      }));
      final supervisor = CliWorkerEngineSupervisor(
        engineExecutable: '/bin/sh',
        processRegistryDirectory: registry,
      );

      expect(await supervisor.recoverOrphanedProcesses(), 1);
      await registered.exitCode.timeout(const Duration(seconds: 2));
      // A process with the same shape that was never registered is left alone.
      // SIGCONT is a harmless no-op that reports whether the process exists.
      expect(Process.killPid(unrelated.pid, ProcessSignal.sigcont), isTrue);
    },
    skip: _orphanReapingSkipReason(),
  );

  test('serializes Engine assignments at the local Worker limit', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    final second = _execute(setup, 'second');
    expect((await first).output, 'first');
    expect((await second).output, 'second');
    expect(File('${setup.state.path}/max-active').existsSync(), isFalse);
  });

  test('cancels a queued Engine assignment before it starts', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    final queued = _execute(setup, 'queued');
    final queuedExpectation = expectLater(
      queued,
      throwsA(isA<Object>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await setup.supervisor.cancel('queued'), isTrue);
    await queuedExpectation;
    expect((await first).output, 'first');
  });

  test('cancelling a queued assignment does not release the active slot',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    final cancelled = _execute(setup, 'cancelled');
    final cancelledExpectation = expectLater(
      cancelled,
      throwsA(isA<WorkerAssignmentCancelledException>()),
    );
    final waiting = _execute(setup, 'waiting');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await setup.supervisor.cancel('cancelled'), isTrue);
    await cancelledExpectation;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(File('${setup.state.path}/active').readAsStringSync(), 'first');
    expect((await first).output, 'slow');
    expect((await waiting).output, 'waiting');
    expect(File('${setup.state.path}/max-active').existsSync(), isFalse);
  });

  test('times out while waiting for the Worker concurrency slot', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    await expectLater(
      _execute(
        setup,
        'queued-timeout',
        timeout: const Duration(seconds: 1),
        queueWaitTimeout: const Duration(seconds: 1),
      ),
      throwsA(isA<CliWorkerEngineProbeException>().having(
          (error) => error.localDiagnostics,
          'diagnostics',
          allOf(contains('queue_wait'), contains('local_startup')))),
    );
    expect((await first).output, 'slow');
  });

  test('does not consume execution timeout while queued', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    final queuedSignal = Completer<void>();
    // The first assignment holds the slot for about five seconds. The queued
    // one has a shorter execution timeout with ample headroom over its own
    // run time, so it can only pass if queue wait is not counted against it.
    final queued = _execute(
      setup,
      'queued',
      timeout: const Duration(seconds: 3),
      queueWaitTimeout: const Duration(seconds: 7),
      onQueued: (_) {
        if (!queuedSignal.isCompleted) queuedSignal.complete();
      },
    );
    await queuedSignal.future;
    expect(await first, isA<WorkerResult>());
    expect((await queued).output, 'queued');
  });

  test('runs independent assignments concurrently up to the effective limit',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(
      setup,
      'first',
      prompt: 'barrier',
      maxConcurrentAssignments: 2,
    );
    final second = _execute(
      setup,
      'second',
      prompt: 'barrier',
      maxConcurrentAssignments: 2,
    );
    await _waitFor(() =>
        File('${setup.state.path}/started-first').existsSync() &&
        File('${setup.state.path}/started-second').existsSync());
    final queued = Completer<void>();
    final third = _execute(
      setup,
      'third',
      maxConcurrentAssignments: 2,
      onQueued: (_) {
        if (!queued.isCompleted) queued.complete();
      },
    );
    await queued.future;
    expect(File('${setup.state.path}/started-third').existsSync(), isFalse);
    await File('${setup.state.path}/release-barrier').writeAsString('release');
    expect((await first).output, 'barrier');
    expect((await second).output, 'barrier');
    expect((await third).output, 'third');
  });

  test('slots are one pool shared by every Worker', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first',
        prompt: 'barrier', workerId: 'worker-a', maxConcurrentAssignments: 2);
    final second = _execute(setup, 'second',
        prompt: 'barrier', workerId: 'worker-b', maxConcurrentAssignments: 2);
    await _waitFor(() =>
        File('${setup.state.path}/started-first').existsSync() &&
        File('${setup.state.path}/started-second').existsSync());
    final queued = Completer<void>();
    final third = _execute(setup, 'third',
        workerId: 'worker-c', maxConcurrentAssignments: 2, onQueued: (_) {
      if (!queued.isCompleted) queued.complete();
    });
    await queued.future;
    expect(File('${setup.state.path}/started-third').existsSync(), isFalse);
    final snapshot = setup.supervisor.slotSnapshot();
    expect(snapshot['active'], 2);
    expect(snapshot['queued'], 1);
    expect(snapshot['limit'], 2);
    expect(setup.supervisor.activeAssignmentCountFor('worker-a'), 1);
    expect(setup.supervisor.queuedAssignmentCountFor('worker-c'), 1);
    await File('${setup.state.path}/release-barrier').writeAsString('release');
    expect((await first).output, 'barrier');
    expect((await second).output, 'barrier');
    expect((await third).output, 'third');
    expect(setup.supervisor.slotSnapshot()['active'], 0);
  });

  test('live capacity changes preserve running work and admit queued work',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first',
        prompt: 'barrier', maxConcurrentAssignments: 2);
    final second = _execute(setup, 'second',
        prompt: 'barrier', maxConcurrentAssignments: 2);
    await _waitFor(() =>
        File('${setup.state.path}/started-first').existsSync() &&
        File('${setup.state.path}/started-second').existsSync());
    final queued = Completer<void>();
    final third = _execute(setup, 'third',
        prompt: 'barrier', maxConcurrentAssignments: 2, onQueued: (_) {
      if (!queued.isCompleted) queued.complete();
    });
    await queued.future;
    setup.supervisor.setParallelSlots(1);
    expect(setup.supervisor.slotSnapshot()['active'], 2);
    expect(setup.supervisor.slotSnapshot()['queued'], 1);
    expect(File('${setup.state.path}/started-third').existsSync(), isFalse);
    setup.supervisor.setParallelSlots(3);
    await _waitFor(File('${setup.state.path}/started-third').existsSync);
    expect(setup.supervisor.slotSnapshot()['active'], 3);
    await File('${setup.state.path}/release-barrier').writeAsString('release');
    expect((await first).output, 'barrier');
    expect((await second).output, 'barrier');
    expect((await third).output, 'barrier');
  });

  test('cancels the active Engine process tree as an assignment failure',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final execution = _execute(setup, 'active', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    expect(await setup.supervisor.cancel('active'), isTrue);
    await expectLater(
      execution,
      throwsA(isA<Object>()),
    );
  });

  test('Engine exit before a terminal frame releases the Worker slot',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    await expectLater(
      _execute(setup, 'exited', prompt: 'exit'),
      throwsA(isA<CliWorkerEngineProbeException>()),
    );
    expect((await _execute(setup, 'after-exit')).output, 'after-exit');
  });

  test('records durable ownership metadata while an Engine is active',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final execution = _execute(setup, 'metadata', prompt: 'slow');
    await _waitFor(() => setup.registry
        .listSync()
        .whereType<File>()
        .any((file) => file.path.endsWith('.worker-process.json')));
    final recordFile = setup.registry
        .listSync()
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('.worker-process.json'));
    final record = Map<String, Object?>.from(
      jsonDecode(await recordFile.readAsString()) as Map,
    );
    expect(record['assignmentId'], 'metadata');
    expect(record['attemptId'], 'attempt-metadata');
    expect(record['workerId'], 'worker-1');
    expect(record['enginePid'], isA<int>());
    expect(record['localExecutionId'], isA<String>());
    expect(record['deadlineAt'], isA<String>());
    expect(record['providerState'], 'not_started');
    await setup.supervisor.cancel('metadata');
    await expectLater(execution, throwsA(isA<Object>()));
  });

  test('a cancellation issued right after execute() prevents process creation',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final execution = _execute(setup, 'immediate');
    final expectation = expectLater(
      execution,
      throwsA(isA<WorkerAssignmentCancelledException>()),
    );
    // No await between execute() and cancel(): the assignment must already be
    // visible to cancellation.
    expect(await setup.supervisor.cancel('immediate'), isTrue);
    await expectation;
    expect(File('${setup.state.path}/active').existsSync(), isFalse);
    expect(setup.supervisor.activeAssignmentCountFor('worker-1'), 0);
    expect((await _execute(setup, 'after')).output, 'after');
  });

  test('a failing slot-reserved callback neither leaks the slot nor blocks',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    expect(
      (await _execute(setup, 'throws',
              onSlotReserved: () => throw StateError('diagnostic failed')))
          .output,
      'throws',
    );
    expect(
      (await _execute(setup, 'async-throws',
              onSlotReserved: () async => throw StateError('write failed')))
          .output,
      'async-throws',
    );
    expect(setup.supervisor.activeAssignmentCountFor('worker-1'), 0);
  });

  test('a slow slot-reserved callback does not delay the Engine launch',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final blocker = Completer<void>();
    addTearDown(() {
      if (!blocker.isCompleted) blocker.complete();
    });
    final result =
        await _execute(setup, 'fast', onSlotReserved: () => blocker.future)
            .timeout(const Duration(seconds: 5));
    expect(result.output, 'fast');
  });

  test('an Engine that cannot start releases capacity and is classified',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final broken = CliWorkerEngineSupervisor(
      engineExecutable: '${setup.root.path}/missing-engine',
      processRegistryDirectory: setup.registry,
    );
    for (final id in ['first', 'second']) {
      await expectLater(
        _execute(setup, id, supervisor: broken)
            .timeout(const Duration(seconds: 3)),
        throwsA(isA<CliWorkerEngineProbeException>()),
      );
      expect(broken.activeAssignmentCountFor('worker-1'), 0);
    }
    expect(broken.queuedAssignmentCount, 0);
    expect(
      setup.registry
          .listSync()
          .where((entity) => entity.path.endsWith('.worker-process.json')),
      isEmpty,
    );
  });

  test('reports the queue position when an assignment has to wait', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    WorkerQueueSnapshot? snapshot;
    final second = _execute(setup, 'second', onQueued: (queue) {
      snapshot = queue;
    });
    expect(snapshot?.position, 1);
    expect(snapshot?.active, 1);
    expect(snapshot?.limit, 1);
    expect(snapshot?.waitingForSession, isFalse);
    expect(setup.supervisor.queuedAssignmentCountFor('worker-1'), 1);
    await setup.supervisor.cancel('first');
    await expectLater(first, throwsA(isA<Object>()));
    expect((await second).output, 'second');
    expect(setup.supervisor.queuedAssignmentCountFor('worker-1'), 0);
  });

  test('raising the Worker limit admits waiting assignments before newcomers',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    final started = <String>[];
    final second = _execute(setup, 'second', onSlotReserved: () {
      started.add('second');
    });
    expect(setup.supervisor.queuedAssignmentCountFor('worker-1'), 1);
    final third = _execute(setup, 'third', maxConcurrentAssignments: 2,
        onSlotReserved: () {
      started.add('third');
    });
    await Future.wait([second, third]);
    expect(started.first, 'second');
    await setup.supervisor.cancel('first');
    await expectLater(first, throwsA(isA<Object>()));
  });

  test('never runs two assignments on the same native session at once',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'first',
        prompt: 'slow', sessionKey: 'native-1', maxConcurrentAssignments: 2);
    await _waitFor(File('${setup.state.path}/active').existsSync);
    WorkerQueueSnapshot? snapshot;
    final sameSession = _execute(setup, 'same-session',
        sessionKey: 'native-1',
        maxConcurrentAssignments: 2,
        onQueued: (queue) => snapshot = queue);
    expect(snapshot?.waitingForSession, isTrue);
    expect(setup.supervisor.activeAssignmentCountFor('worker-1'), 1);
    // An unrelated session of the same Worker is not blocked by that wait.
    expect(
      (await _execute(setup, 'other-session',
              sessionKey: 'native-2', maxConcurrentAssignments: 2))
          .output,
      'other-session',
    );
    expect(setup.supervisor.queuedAssignmentCountFor('worker-1'), 1);
    // Once the first assignment ends, the waiting one runs.
    await setup.supervisor.cancel('first');
    await expectLater(first, throwsA(isA<Object>()));
    expect((await sameSession).output, 'same-session');
    expect(setup.supervisor.activeAssignmentCountFor('worker-1'), 0);
  });

  test('the ownership record is durable before the provider is asked to start',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final execution = _execute(setup, 'record-first', prompt: 'slow');
    // The fake Engine creates `active` when it receives execute.request, so
    // by then the record must already exist.
    await _waitFor(File('${setup.state.path}/active').existsSync);
    expect(
      setup.registry
          .listSync()
          .where((entity) => entity.path.endsWith('.worker-process.json')),
      hasLength(1),
    );
    await setup.supervisor.cancel('record-first');
    await expectLater(execution, throwsA(isA<Object>()));
  });

  test('rejects duplicate local execution for the same assignment', () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    final first = _execute(setup, 'duplicate', prompt: 'slow');
    await _waitFor(File('${setup.state.path}/active').existsSync);
    await expectLater(
      _execute(setup, 'duplicate'),
      throwsA(isA<FormatException>()),
    );
    await setup.supervisor.cancel('duplicate');
    await expectLater(first, throwsA(isA<Object>()));
  });
  test('repeated cancellation at transferred slot prevents process creation',
      () async {
    final setup = await _setup();
    addTearDown(() => setup.root.delete(recursive: true));
    for (var iteration = 0; iteration < 20; iteration++) {
      final fenceEntered = Completer<void>();
      final grant = Completer<bool>();
      var spawned = false;
      final first = _execute(setup, 'owner-$iteration', authorizeStart: () {
        fenceEntered.complete();
        return grant.future;
      });
      final firstDone = expectLater(
          first, throwsA(isA<WorkerAssignmentCancelledException>()));
      await fenceEntered.future;
      final queued = Completer<void>();
      final nextFence = Completer<void>();
      final nextGrant = Completer<bool>();
      final nextId = 'handoff-$iteration';
      final next = _execute(setup, nextId,
          onQueued: (_) {
            if (!queued.isCompleted) queued.complete();
          },
          authorizeStart: () {
            nextFence.complete();
            return nextGrant.future;
          },
          onProcessStarted: () => spawned = true);
      final nextDone =
          expectLater(next, throwsA(isA<WorkerAssignmentCancelledException>()));
      await queued.future;
      expect(await setup.supervisor.cancel('owner-$iteration'), isTrue);
      grant.complete(true);
      await firstDone;
      await nextFence.future;
      expect(await setup.supervisor.cancel(nextId), isTrue);
      nextGrant.complete(true);
      await nextDone;
      expect(spawned, isFalse, reason: 'iteration $iteration');
      expect(setup.registry.listSync(), isEmpty);
    }
    expect((await _execute(setup, 'capacity-restored')).output,
        'capacity-restored');
  });
}

Future<WorkerResult> _execute(
  _Setup setup,
  String assignmentId, {
  String? prompt,
  Duration timeout = const Duration(seconds: 10),
  Duration? queueWaitTimeout,
  int maxConcurrentAssignments = 1,
  String workerId = 'worker-1',
  String? sessionKey,
  ExternalConversationInput? externalConversation,
  FutureOr<void> Function()? onSlotReserved,
  void Function(WorkerQueueSnapshot queue)? onQueued,
  CliWorkerEngineSupervisor? supervisor,
  FutureOr<bool> Function()? authorizeStart,
  void Function()? onProcessStarted,
}) =>
    (supervisor ?? setup.supervisor).execute(
      setup.admission,
      profileFile: setup.profileFile,
      stateDirectory: setup.state,
      workingDirectory: setup.thread,
      workerId: workerId,
      maxConcurrentAssignments: maxConcurrentAssignments,
      assignmentId: assignmentId,
      attemptId: setup.attemptId,
      prompt: prompt ?? assignmentId,
      externalConversation: externalConversation,
      timeout: timeout,
      queueWaitTimeout: queueWaitTimeout,
      sessionPolicy: sessionKey == null
          ? WorkerSessionPolicy.stateless
          : WorkerSessionPolicy.durableSession,
      sessionKey: sessionKey,
      onSlotReserved: onSlotReserved,
      onQueued: onQueued,
      authorizeStart: authorizeStart,
      onProcessStarted: onProcessStarted,
    );

Future<_Setup> _setup({bool enableVmService = false}) async {
  final root = await Directory.systemTemp.createTemp('engine-supervisor-');
  final profileFile = File(
    '${Directory.current.parent.parent.path}/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
  );
  final bytes = await profileFile.readAsBytes();
  final profile =
      Map<String, Object?>.from(jsonDecode(utf8.decode(bytes)) as Map);
  final provider = Map<String, Object?>.from(profile['providerTool'] as Map);
  final admission = ToolProfileReleaseAdmission(
    profile: profile,
    profileDefinitionId: profile['profileDefinitionId'] as String,
    releaseVersion: profile['releaseVersion'] as int,
    logicalWorkerTypeId: profile['logicalWorkerTypeId'] as String,
    providerToolName: provider['name'] as String,
    payloadDigest: sha256.convert(bytes).toString(),
    channel: 'stable',
  );
  final state = await Directory('${root.path}/state').create();
  final thread = await Directory('${root.path}/thread').create();
  final registry = await Directory('${root.path}/registry').create();
  final script = File('${root.path}/fake_engine.dart')
    ..writeAsStringSync(_fakeEngineSource);
  return _Setup(
    root: root,
    profileFile: profileFile,
    admission: admission,
    state: state,
    thread: thread,
    supervisor: CliWorkerEngineSupervisor(
      engineExecutable: _testDartExecutable(),
      engineArgumentsPrefix: [
        if (enableVmService) '--enable-vm-service=0',
        script.path,
      ],
      processRegistryDirectory: registry,
    ),
    registry: registry,
    attemptId: 'attempt-metadata',
  );
}

String _testDartExecutable() {
  final configured = Platform.environment['DART_EXECUTABLE'];
  if (configured != null && configured.isNotEmpty) return configured;
  try {
    final lookup = Process.runSync(
      Platform.isWindows ? 'where' : 'which',
      ['dart'],
    );
    if (lookup.exitCode == 0) {
      final executable = lookup.stdout
          .toString()
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      if (executable.isNotEmpty) return executable;
    }
  } on Object {
    // Fall back to the current runtime when the Dart executable is not on PATH.
  }
  return Platform.resolvedExecutable;
}

/// Why orphan reaping cannot be exercised here, or false when it can.
Object _orphanReapingSkipReason() {
  if (Platform.isWindows) return 'POSIX process tree reaping only';
  try {
    if (Process.runSync('ps', ['-p', '1', '-o', 'pid=']).exitCode != 0) {
      return 'ps is not usable in this environment';
    }
  } on ProcessException {
    return 'ps is not available in this environment';
  }
  return false;
}

Future<void> _waitFor(bool Function() condition) async {
  final timer = Stopwatch()..start();
  while (!condition()) {
    if (timer.elapsed > const Duration(seconds: 3)) {
      throw TimeoutException('condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _Setup {
  const _Setup({
    required this.root,
    required this.profileFile,
    required this.admission,
    required this.state,
    required this.thread,
    required this.supervisor,
    required this.registry,
    required this.attemptId,
  });

  final Directory root;
  final File profileFile;
  final ToolProfileReleaseAdmission admission;
  final Directory state;
  final Directory thread;
  final CliWorkerEngineSupervisor supervisor;
  final Directory registry;
  final String attemptId;
}

const _fakeEngineSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

String valueAfter(List<String> args, String key) => args[args.indexOf(key) + 1];

Future<void> main(List<String> args) async {
  final state = Directory(valueAfter(args, '--state-directory'));
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    switch (request['type']) {
      case 'initialize.request':
        stdout.writeln(jsonEncode({
          'type': 'initialize.result',
          'protocolVersion': request['protocolVersion'],
          'requestId': request['requestId'],
          'workerTypeId': request['workerTypeId'],
          'engineVersion': valueAfter(args, '--engine-version'),
          'profileDefinitionId': request['profileDefinitionId'],
          'profileReleaseVersion': request['profileReleaseVersion'],
          'profileSchemaVersion': 1,
          'capabilities': File('${state.path}/supports-external-conversation').existsSync()
              ? ['external_conversation_v1'] : <String>[],
        }));
      case 'execute.request':
        File('${state.path}/request-${request['assignmentId']}.json').writeAsStringSync(jsonEncode(request));
        if (request['prompt'] == 'exit') exit(17);
        File('${state.path}/started-${request['assignmentId']}').writeAsStringSync('started');
        if (request['prompt'] == 'barrier') {
          while (!File('${state.path}/release-barrier').existsSync()) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }
        final activeFile = File('${state.path}/active');
        if (activeFile.existsSync()) {
          File('${state.path}/max-active').writeAsStringSync('2');
        }
        activeFile.writeAsStringSync(request['assignmentId'] as String);
        final slow = request['prompt'] == 'slow';
        await Future<void>.delayed(Duration(milliseconds: slow ? 5000 : 250));
        if (activeFile.existsSync() && activeFile.readAsStringSync() == request['assignmentId']) {
          activeFile.deleteSync();
        }
        stdout.writeln(jsonEncode({
          'type': 'result',
          'requestId': request['requestId'],
          'assignmentId': request['assignmentId'],
          'output': request['prompt'],
          'artifacts': <String>[],
        }));
    }
  }
}
''';
