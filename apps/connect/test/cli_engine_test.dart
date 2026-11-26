import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_connect/syntila_connect.dart';
import 'package:syntila_connect/src/server_api.dart';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:test/test.dart';

void main() {
  test('errors become stable codes without provider output', () {
    final failure = outcomeForError(
      WorkerFailure(
        code: 'provider_unavailable',
        message: 'down',
        retryable: true,
      ),
      cancelled: false,
    );
    expect(failure.kind, TerminalKind.failed);
    expect(failure.payload, containsPair('errorCode', 'provider_unavailable'));
    expect(failure.payload, containsPair('retryable', true));
    expect(
      outcomeForError(TimeoutException('x'), cancelled: false).payload,
      containsPair('errorCode', 'timeout'),
    );
    final unknown = outcomeForError(
      StateError('/home/me/secret'),
      cancelled: false,
    );
    expect(unknown.payload.toString(), isNot(contains('/home/me')));
    expect(
      outcomeForError(StateError('x'), cancelled: true).kind,
      TerminalKind.cancelled,
    );
  });

  group('launcher', () {
    late Directory dir;
    setUp(
      () async =>
          dir = await Directory.systemTemp.createTemp('syntila-engine-'),
    );
    tearDown(() => dir.delete(recursive: true));

    CliEngineLauncher launcher(String executable, ProfileResolver resolver) =>
        CliEngineLauncher(
          supervisor: CliWorkerEngineSupervisor(engineExecutable: executable),
          engineExecutable: executable,
          resolveProfile: resolver,
          workerId: 'wrk-1',
          stateDirectory: Directory('${dir.path}/state'),
          workRoot: Directory('${dir.path}/work'),
        );

    test('probe reports a missing Engine executable', () async {
      expect(
        await launcher('${dir.path}/missing', (_) async => null).probe(),
        'engine_unavailable',
      );
      final present = File('${dir.path}/engine')..writeAsStringSync('x');
      expect(await launcher(present.path, (_) async => null).probe(), isNull);
    });

    test(
      'a Profile that is not available locally fails closed without starting anything',
      () async {
        final run = await launcher('${dir.path}/engine', (_) async => null)
            .launch(
              const EngineRequest(
                assignmentId: 'a1',
                attemptId: 'att',
                payload: {
                  'snapshot': {'objective': 'hi'},
                },
              ),
            );
        final outcome = await run.outcome;
        expect(await (run as EngineStartEvidence).providerStarted, isFalse);
        expect(outcome.kind, TerminalKind.failed);
        expect(outcome.payload, containsPair('errorCode', 'worker_not_ready'));
        expect(Directory('${dir.path}/work').existsSync(), isFalse);
      },
    );

    test('runs the real generic Engine with a controlled provider', () async {
      final repo = Directory.current.parent.parent.path;
      final dart = Platform.resolvedExecutable;
      final provider =
          '${dir.path}/fixture-provider${Platform.isWindows ? '.exe' : ''}';
      final build = await Process.run(dart, [
        'compile',
        'exe',
        '$repo/packages/tool-profile/test/fixtures/fixture_provider.dart',
        '-o',
        provider,
      ]);
      expect(build.exitCode, 0, reason: '${build.stderr}');
      final profile =
          jsonDecode(
                await File(
                  '$repo/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final canonical = canonicalJson(profile);
      final profileFile = File('${dir.path}/profile.json');
      await profileFile.writeAsString(canonical);
      final candidate = WorkerProfileSnapshotAdmission(
        profile: profile,
        workerTypeId: 'fixture-worker',
        revision: 1,
        payloadDigest: profileDigest(utf8.encode(canonical)),
      );
      final supervisor = CliWorkerEngineSupervisor(
        engineExecutable: dart,
        engineArgumentsPrefix: [
          '-DENGINE_VERSION=1.4.0',
          '$repo/engines/cli_worker/bin/syntila_cli_worker.dart',
        ],
        environmentOverrides: {
          'PATH':
              '${dir.path}${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}',
          'HOME': dir.path,
        },
      );
      final launcher = CliEngineLauncher(
        supervisor: supervisor,
        engineExecutable: dart,
        resolveProfile: (_) async =>
            (candidate: candidate, profileFile: profileFile),
        workerId: 'worker-test',
        stateDirectory: Directory('${dir.path}/state'),
        workRoot: Directory('${dir.path}/work'),
      );
      final activity = <String>[];
      final run = await launcher.launch(
        EngineRequest(
          assignmentId: 'assignment-test',
          attemptId: 'attempt-test',
          payload: {
            'snapshot': {'sessionPolicy': 'stateless', 'objective': 'hello'},
            'input': {'prompt': 'hello'},
          },
          timeout: const Duration(seconds: 30),
          onActivity: (event) => activity.add(event.eventType),
        ),
      );
      final outcome = await run.outcome.timeout(const Duration(seconds: 40));
      expect(await (run as EngineStartEvidence).providerStarted, isTrue);
      expect(
        outcome.kind,
        TerminalKind.completed,
        reason: '${outcome.payload}',
      );
      // A writable step is told where to save images for the user.
      final text = (outcome.payload['output'] as Map)['text'] as String;
      expect(text, startsWith('fixture echo: hello'));
      expect(text, contains('/assignment-test/outputs'));
      expect(activity, contains('execution.started'));

      final failingLauncher = CliEngineLauncher(
        supervisor: supervisor,
        engineExecutable: dart,
        resolveProfile: (_) async =>
            (candidate: candidate, profileFile: profileFile),
        workerId: 'worker-test',
        stateDirectory: Directory('${dir.path}/state'),
        workRoot: Directory('${dir.path}/work'),
        placeInputs: (_, __) async =>
            throw ServerRefusal(404, '/private/secret'),
      );
      final failedInput = await failingLauncher.launch(
        const EngineRequest(
          assignmentId: 'assignment-input-failed',
          attemptId: 'attempt-input-failed',
          payload: {
            'snapshot': {'sessionPolicy': 'stateless', 'objective': 'hello'},
            'input': {'prompt': 'hello'},
          },
        ),
      );
      final failure = await failedInput.outcome;
      expect(failure.kind, TerminalKind.failed);
      expect(
        await (failedInput as EngineStartEvidence).providerStarted,
        isFalse,
      );
      final failureDetails = failure.payload['providerFailure'] as Map;
      expect(failureDetails['source'], 'agent');
      expect(
        failureDetails['providerErrorText'],
        'The request’s attachment could not be downloaded (HTTP 404).',
      );
      expect(failureDetails.toString(), isNot(contains('/private/secret')));

      // A Person Share (another person's Chat) is always read-only: it is
      // not offered a place to save files, whatever the snapshot says.
      final shared = await launcher.launch(
        EngineRequest(
          assignmentId: 'assignment-shared',
          attemptId: 'attempt-shared',
          payload: {
            'snapshot': {
              'sessionPolicy': 'stateless',
              'objective': 'hello',
              'personShare': true,
              'readOnly': false,
              'spaceFolderId': 'folder-of-the-owner',
            },
            'input': {'prompt': 'hello'},
          },
          timeout: const Duration(seconds: 30),
        ),
      );
      final sharedOutcome = await shared.outcome.timeout(
        const Duration(seconds: 40),
      );
      expect(sharedOutcome.kind, TerminalKind.completed);
      final sharedText =
          (sharedOutcome.payload['output'] as Map)['text'] as String;
      expect(sharedText, startsWith('fixture echo: hello'));
      expect(sharedText, isNot(contains('/outputs')));

      final invalid = await launcher.launch(
        const EngineRequest(
          assignmentId: 'assignment-other',
          attemptId: 'attempt-other',
          payload: {
            'snapshot': {
              'sessionPolicy': 'durable_session',
              'sessionKey': 'session-key',
              'workerSession': {
                'schemaVersion': 1,
                'id': 'session-id',
                'conversationId': 'conversation-id',
                'workerId': 'another-worker',
                'baseContextRevision': 0,
              },
            },
            'input': {'prompt': 'hello'},
          },
        ),
      );
      expect((await invalid.outcome).kind, TerminalKind.failed);
      expect(await (invalid as EngineStartEvidence).providerStarted, isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
