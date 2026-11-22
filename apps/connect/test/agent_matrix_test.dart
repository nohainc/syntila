// The crash and reconnect matrix from WORKER_AGENT_RUNTIME_V1.md section 5, and
// the P4 exit gate: independent Agents, separate journals, no Engine ever
// started twice, and no Workspace anywhere.
import 'dart:io';

import 'package:syntila_connect/syntila_connect.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

import 'support/fake_cloud.dart';
import 'support/fake_engine.dart';
import 'support/harness.dart';

class _RejectProfiles implements ProfileVerifier {
  @override
  Future<bool> verify(List<int> profileBytes, String? signature) async => false;
}

void main() {
  late FakeCloud cloud;
  late Directory root;
  late FakeEngine engine;
  late FakeWorker worker;
  late AgentHost host;

  setUp(() async {
    cloud = await FakeCloud.start();
    root = await tempRoot('matrix');
    engine = FakeEngine();
    worker = cloud.createWorker();
    host = await AgentHost.install(cloud, worker, root);
  });

  tearDown(() async {
    await host.dispose();
    await cloud.close();
    await root.delete(recursive: true);
  });

  /// Throws [SimulatedCrash] the first time [point] is reached.
  FaultPoint crashAt(String point) {
    var fired = false;
    return (name, id) {
      if (!fired && name == point) {
        fired = true;
        throw SimulatedCrash(point);
      }
    };
  }

  Future<AgentRuntime> restart() async {
    engine.orphanRunning();
    return host.startReady(engine);
  }

  Future<void> settled(FakeAssignment a) => waitFor(
    () =>
        a.status == 'completed' ||
        a.status == 'failed' ||
        a.status == 'cancelled',
    reason: 'assignment ${a.id} stayed ${a.status}',
  );

  Future<void> allAcknowledged() => waitFor(
    () => host.runtime!.journal.unacknowledged.isEmpty,
    reason: 'the journal still has unacknowledged entries',
  );

  group('crash and reconnect matrix', () {
    test('forwards Engine activity for the running assignment', () async {
      engine.hold = true;
      await host.startReady(engine);
      final a = cloud.dispatch(worker.id);
      await waitFor(() => engine.requests.containsKey(a.id));
      engine.requests[a.id]!.onActivity!(
        WorkerActivity(
          requestId: 'request',
          assignmentId: a.id,
          executionId: 'execution',
          workerId: 'chatgpt',
          eventId: 'event',
          sequence: 1,
          timestamp: DateTime.now().toUtc().toIso8601String(),
          eventType: 'tool.started',
          status: 'running',
          title: 'Reading files',
        ),
      );
      await waitFor(() => a.activity.isNotEmpty);
      expect(a.activity.single, containsPair('title', 'Reading files'));
      expect(a.activity.single, containsPair('eventType', 'tool.started'));
      engine.finish(a.id, const EngineOutcome(TerminalKind.completed, {}));
      await settled(a);
    });
    test(
      'does not report provider start when the Engine fails first',
      () async {
        engine.failBeforeProviderStart = true;
        await host.startReady(engine);
        final a = cloud.dispatch(worker.id);
        await settled(a);
        expect(a.status, 'failed');
        expect(a.startAcks, 0);
      },
    );
    test(
      'reports a failure with the Cloud\'s own code and canonical message',
      () async {
        engine.hold = true;
        await host.startReady(engine);
        final a = cloud.dispatch(worker.id);
        await waitFor(() => engine.launchCount(a.id) == 1);
        engine.finish(
          a.id,
          const EngineOutcome(TerminalKind.failed, {
            'errorCode': 'engine_failed',
            'message': 'The Engine could not run this assignment',
            'retryable': false,
            'detail': 'claude: rate limit reached, resets 5pm',
            'providerFailure': {
              'schemaVersion': 1,
              'source': 'stderr',
              'providerErrorText': 'Claude AI usage limit reached',
            },
          }),
        );
        await settled(a);
        expect(a.status, 'failed');
        expect(
          a.terminal!['providerFailure'],
          containsPair('providerErrorText', 'Claude AI usage limit reached'),
        );
        expect(
          (a.terminal!['error'] as Map)['details'],
          containsPair('diagnostic', 'claude: rate limit reached, resets 5pm'),
        );
        expect(
          a.terminal!['error'],
          containsPair('code', 'execution_failed'),
        );
        expect(
          a.terminal!['error'],
          containsPair('message', 'The assignment could not be completed.'),
        );
      },
    );
    test('uses the server snapshot and its timeout for the Engine', () async {
      await host.startReady(engine);
      final a = cloud.dispatch(
        worker.id,
        payload: {
          'timeoutMs': 12000,
          'model': 'test-model',
          'profileDigest': 'd' * 64,
        },
      );
      await settled(a);
      final request = engine.requests[a.id]!;
      expect(request.timeout, const Duration(seconds: 12));
      expect((request.payload['snapshot'] as Map)['model'], 'test-model');
      expect(
        host.runtime!.journal.find(a.id)!.context.snapshotDigest,
        'd' * 64,
      );
    });

    test('rejects a snapshot belonging to another Worker', () async {
      await host.startReady(engine);
      final a = cloud.dispatch(
        worker.id,
        payload: {'workerId': 'another-worker'},
      );
      await waitFor(() => a.acks > 0);
      expect(a.status, 'created');
      expect(engine.launchCount(a.id), 0);
      expect(host.runtime!.journal.find(a.id), isNull);
    });

    test(
      'rejects an assignment identifier that could escape the Work Root',
      () async {
        await host.startReady(engine);
        final a = cloud.dispatch(worker.id, assignmentId: '../escape');
        await waitFor(() => a.acks > 0);
        expect(engine.launchCount(a.id), 0);
        expect(host.runtime!.journal.find(a.id), isNull);
      },
    );

    test('does not admit an assignment without its pinned Profile', () async {
      final cache = ProfileCache(
        Directory('${root.path}/profiles'),
        _RejectProfiles(),
      );
      final agent = await host.open(engine, profiles: cache);
      await agent.start();
      await agent.connection.whenReady();
      final a = cloud.dispatch(worker.id, payload: {'profileDigest': 'a' * 64});
      await waitFor(() => a.acks > 0);
      expect(engine.launchCount(a.id), 0);
      expect(agent.journal.find(a.id), isNull);
    });
    test(
      'server crash before the committed command arrives: the inbox is reconciled',
      () async {
        final a = cloud.dispatch(
          worker.id,
        ); // nobody is connected; the command waits
        await host.startReady(engine);
        await settled(a);
        expect(a.status, 'completed');
        expect(engine.launchCount(a.id), 1);
        await allAcknowledged();
      },
    );

    test(
      'connection drops before the admission acknowledgement: it is re-sent from the journal',
      () async {
        var dropped = false;
        final agent = await host.startReady(
          engine,
          onPoint: (point, id) async {
            if (point == 'before-ack' && !dropped) {
              dropped = true;
              await cloud.dropSockets(worker.id);
            }
          },
        );
        final a = cloud.dispatch(worker.id);
        await settled(a);
        expect(a.status, 'completed');
        expect(
          engine.launchCount(a.id),
          1,
          reason: 'a replayed command never starts a second Engine',
        );
        expect(
          agent.connection.session!.epoch,
          greaterThan(1),
          reason: 'it reconnected with a new epoch',
        );
      },
    );

    test(
      'crash before the journal commit: nothing was admitted and nothing ran',
      () async {
        await host.startReady(engine, onPoint: crashAt('before-received'));
        final a = cloud.dispatch(worker.id);
        await waitFor(() => host.runtime!.isDead);
        expect(engine.launches, isEmpty);
        await restart();
        await settled(a);
        expect(a.status, 'completed');
        expect(engine.launchCount(a.id), 1);
      },
    );

    test(
      'crash after admission but before the Engine starts: replayed and run once',
      () async {
        await host.startReady(engine, onPoint: crashAt('after-accepted'));
        final a = cloud.dispatch(worker.id);
        await waitFor(() => host.runtime!.isDead);
        expect(engine.launches, isEmpty);
        await restart();
        await settled(a);
        expect(a.status, 'completed');
        expect(engine.launchCount(a.id), 1);
      },
    );

    test(
      'crash after the start was recorded but before the Engine existed: settled, never started',
      () async {
        await host.startReady(engine, onPoint: crashAt('after-starting'));
        final a = cloud.dispatch(worker.id);
        await waitFor(() => host.runtime!.isDead);
        await restart();
        await settled(a);
        expect(a.status, 'failed');
        expect(a.terminal!['error'], containsPair('retryable', true));
        expect(
          engine.launchCount(a.id),
          0,
          reason: 'an attempt that may have started is not started again',
        );
      },
    );

    test(
      'crash after the Engine was created: the orphan is killed and the attempt is not restarted',
      () async {
        engine.hold = true;
        await host.startReady(engine, onPoint: crashAt('after-engine-launch'));
        final a = cloud.dispatch(worker.id);
        await waitFor(() => host.runtime!.isDead);
        expect(engine.launchCount(a.id), 1);
        await restart();
        await settled(a);
        expect(a.status, 'failed');
        expect(engine.launchCount(a.id), 1);
        expect(
          engine.recovered,
          1,
          reason: 'the orphaned Engine was found and stopped',
        );
      },
    );

    test(
      'disconnect while the provider runs: it keeps running and the result arrives once',
      () async {
        engine.hold = true;
        final agent = await host.startReady(engine);
        final a = cloud.dispatch(worker.id);
        await waitFor(() => a.status == 'started');
        cloud.offline = true;
        await cloud.dropSockets(worker.id);
        await waitFor(() => agent.connection.phase != ConnectionPhase.ready);
        expect(a.status, 'started', reason: 'a closed socket is not a failure');
        expect(
          engine.runs[a.id]!.isRunning,
          isTrue,
          reason: 'the Engine keeps going while offline',
        );
        cloud.offline = false;
        await agent.connection.whenReady();
        engine.finish(
          a.id,
          const EngineOutcome(TerminalKind.completed, {
            'summary': 'late but fine',
          }),
        );
        await settled(a);
        expect(a.status, 'completed');
        expect(engine.launchCount(a.id), 1);
        await allAcknowledged();
      },
    );

    test(
      'finished while disconnected: the result is kept and sent after reconnect',
      () async {
        engine.hold = true;
        final agent = await host.startReady(engine);
        final a = cloud.dispatch(worker.id);
        await waitFor(() => a.status == 'started');
        cloud.offline = true;
        await cloud.dropSockets(worker.id);
        await waitFor(() => agent.connection.phase != ConnectionPhase.ready);
        engine.finish(
          a.id,
          const EngineOutcome(TerminalKind.completed, {
            'summary': 'done offline',
          }),
        );
        await waitFor(
          () => agent.journal.find(a.id)!.status == LocalStatus.terminal,
        );
        expect(a.status, 'started', reason: 'nothing could be delivered yet');
        cloud.offline = false;
        await settled(a);
        expect(a.status, 'completed');
        await allAcknowledged();
      },
    );

    test(
      'crash after sending the result but before the acknowledgement: reconciled, not repeated',
      () async {
        await host.startReady(engine, onPoint: crashAt('after-terminal-send'));
        final a = cloud.dispatch(worker.id);
        await waitFor(() => host.runtime!.isDead);
        await settled(a);
        await restart();
        await allAcknowledged();
        expect(engine.launchCount(a.id), 1);
        expect(a.status, 'completed');
      },
    );

    test(
      'a cancel that arrives while the Worker is offline is honoured before any start',
      () async {
        final a = cloud.dispatch(worker.id);
        cloud.pushCancelOnly(a);
        await host.startReady(engine);
        await settled(a);
        expect(a.status, 'cancelled');
        expect(engine.launches, isEmpty, reason: 'no Engine for revoked work');
      },
    );

    test(
      'a cancel for a command the Worker never saw is recorded, and the late command is not run',
      () async {
        final agent = await host.startReady(engine);
        final a = cloud.createAssignment(worker.id);
        cloud.pushCancelOnly(a);
        await waitFor(
          () =>
              agent.journal.find(a.id)?.status == LocalStatus.terminal ||
              agent.journal.find(a.id)?.status == LocalStatus.acknowledged,
        );
        cloud.push(a); // the command now arrives
        await settled(a);
        expect(a.status, 'cancelled');
        expect(engine.launches, isEmpty);
      },
    );

    test('work that fails readiness is refused, not queued', () async {
      engine.unavailable = 'engine_unavailable';
      await host.startReady(engine);
      final a = cloud.dispatch(worker.id);
      await waitFor(() => a.acks > 0);
      expect(a.status, 'created');
      expect(engine.launches, isEmpty);
    });

    test('a damaged journal fails closed and the lock is released', () async {
      await host.paths.ensure();
      await host.paths.journalFile.writeAsString(
        '{"seq":1,"id":"x"}\nnot json\n{"seq":3}\n',
      );
      await expectLater(
        host.open(engine),
        throwsA(isA<JournalCorruptedException>()),
      );
      await host.paths.journalFile.delete();
      final agent = await host.open(engine); // the lock was not left behind
      await agent.stop();
    });
  });

  group('every crash point', () {
    const points = [
      'before-received',
      'after-received',
      'before-accepted',
      'after-accepted',
      'before-ack',
      'before-starting',
      'after-starting',
      'after-engine-launch',
      'before-running',
      'after-running',
      'before-terminal',
      'after-terminal',
      'after-terminal-send',
      'before-acknowledged',
    ];
    for (final point in points) {
      test(
        '$point: ends terminal, journal settled, Engine started at most once',
        () async {
          await host.startReady(engine, onPoint: crashAt(point));
          final a = cloud.dispatch(worker.id);
          await waitFor(
            () => host.runtime!.isDead,
            reason: 'the crash point was not reached',
          );
          await restart();
          await settled(a);
          await allAcknowledged();
          expect(['completed', 'failed'], contains(a.status));
          expect(engine.maxLaunchesPerAssignment, lessThanOrEqualTo(1));
          for (final entry in host.runtime!.journal.entries) {
            expect(entry.engineStarts, lessThanOrEqualTo(1));
          }
        },
      );
    }

    test('two crashes in a row still never start the Engine twice', () async {
      engine.hold = true;
      await host.startReady(engine, onPoint: crashAt('after-running'));
      final a = cloud.dispatch(worker.id);
      await waitFor(() => host.runtime!.isDead);
      engine.orphanRunning();
      try {
        await host.startReady(engine, onPoint: crashAt('before-terminal'));
      } on SimulatedCrash {
        // Recovery settles the interrupted attempt while starting, so the
        // crash can surface from start() itself.
      }
      await host.runtime!.kill();
      await restart();
      await settled(a);
      expect(engine.maxLaunchesPerAssignment, lessThanOrEqualTo(1));
    });
  });

  group('session fencing from the Agent side', () {
    test(
      'two logins with one credential: the newer wins and the older one\'s late result is rejected',
      () async {
        cloud.closeSupersededSockets =
            false; // the old socket lingers, as it can during a node crash
        engine.hold = true;
        final older = await host.startReady(engine);
        final a = cloud.dispatch(worker.id);
        await waitFor(() => a.status == 'started');

        // A copy of the installation (same key) logs in from another place.
        final cloneRoot = await tempRoot('clone');
        addTearDown(() => cloneRoot.delete(recursive: true));
        final clonePaths = AgentPaths(Directory('${cloneRoot.path}/clone'));
        await clonePaths.ensure();
        await host.keys.load().then(
          (key) => FileKeyStore(clonePaths.keyFile).save(key!),
        );
        final cloneIdentity = host.identity;
        final newer = await AgentRuntime.open(
          paths: clonePaths,
          identity: cloneIdentity,
          keyStore: FileKeyStore(clonePaths.keyFile),
          engine: FakeEngine(),
          baseDelay: const Duration(milliseconds: 20),
          heartbeatInterval: const Duration(milliseconds: 200),
        );
        addTearDown(newer.kill);
        await newer.start();
        await newer.connection.whenReady();
        expect(
          newer.connection.session!.epoch,
          greaterThan(older.connection.session!.epoch),
        );

        // The older session's Engine now finishes and it reports.
        engine.finish(
          a.id,
          const EngineOutcome(TerminalKind.completed, {'summary': 'too late'}),
        );
        await waitFor(
          () => cloud.rejected.any((r) => r.startsWith('assignment.result')),
          reason: 'the late result was not refused',
        );
        expect(
          a.status,
          isNot('completed'),
          reason: 'a stale session commits nothing',
        );
        await older.kill();
      },
    );

    test('a revoked credential stops the Agent instead of retrying', () async {
      final agent = await host.startReady(engine);
      worker.publicKey =
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; // the server rotated it away
      await cloud.dropSockets(worker.id);
      await waitFor(() => agent.connection.phase == ConnectionPhase.revoked);
    });
  });

  group('exit gate', () {
    test(
      'two Agents with the same Type and name on two hosts run independently',
      () async {
        final second = cloud.createWorker();
        expect(second.workerType, worker.workerType);
        expect(second.name, worker.name);
        final hostRoot = await tempRoot('host-b');
        addTearDown(() => hostRoot.delete(recursive: true));
        final hostB = await AgentHost.install(cloud, second, hostRoot);
        final engineB = FakeEngine();
        addTearDown(hostB.dispose);

        final agentA = await host.startReady(engine);
        final agentB = await hostB.startReady(engineB);
        expect(
          agentA.connection.session!.sessionId,
          isNot(agentB.connection.session!.sessionId),
        );
        expect(agentA.connection.session!.epoch, 1);
        expect(
          agentB.connection.session!.epoch,
          1,
          reason: 'epochs are per Worker',
        );

        final a = cloud.dispatch(worker.id);
        final b = cloud.dispatch(second.id);
        await settled(a);
        await settled(b);
        expect(engine.launches, [a.id]);
        expect(engineB.launches, [b.id]);

        // One going down does not touch the other.
        await agentA.kill();
        final b2 = cloud.dispatch(second.id);
        await settled(b2);
        expect(b2.status, 'completed');
        expect(agentB.connection.session!.epoch, 1);
      },
    );

    test(
      'two Agents on one host keep separate journals, keys and locks',
      () async {
        final second = cloud.createWorker(name: worker.name);
        final hostB = await AgentHost.install(
          cloud,
          second,
          root,
        ); // same host directory
        addTearDown(hostB.dispose);
        final agentA = await host.startReady(engine);
        final agentB = await hostB.startReady(
          engine,
        ); // the same host's Engine supervisor

        final a = cloud.dispatch(worker.id);
        final b = cloud.dispatch(second.id);
        await settled(a);
        await settled(b);
        await waitFor(
          () =>
              agentA.journal.unacknowledged.isEmpty &&
              agentB.journal.unacknowledged.isEmpty,
        );

        expect(
          host.paths.journalFile.path,
          isNot(hostB.paths.journalFile.path),
        );
        expect(agentA.journal.find(b.id), isNull);
        expect(agentB.journal.find(a.id), isNull);
        expect(
          await host.paths.keyFile.readAsString(),
          isNot(await hostB.paths.keyFile.readAsString()),
        );
        expect(engine.maxLaunchesPerAssignment, 1);
        // The same data directory cannot be owned twice.
        await expectLater(
          AgentRuntime.open(
            paths: host.paths,
            identity: host.identity,
            keyStore: host.keys,
            engine: engine,
          ),
          throwsA(isA<AgentLockedException>()),
        );
      },
    );

    test(
      'it works without a Workspace: no Workspace code or service is involved',
      () {
        final pubspec = File('pubspec.yaml').readAsStringSync();
        expect(pubspec, isNot(contains('syntila_workspace')));
        for (final file in Directory(
          'lib',
        ).listSync(recursive: true).whereType<File>()) {
          final text = file.readAsStringSync();
          expect(
            text,
            isNot(contains('package:syntila_workspace')),
            reason: file.path,
          );
          expect(text, isNot(contains('workspace_runtime')), reason: file.path);
        }
      },
    );
  });
}
