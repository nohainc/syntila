import 'dart:async';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_worker_agent/syntila_worker_agent.dart';
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
                payload: {'prompt': 'hi'},
              ),
            );
        final outcome = await run.outcome;
        expect(outcome.kind, TerminalKind.failed);
        expect(outcome.payload, containsPair('errorCode', 'worker_not_ready'));
        expect(Directory('${dir.path}/work').existsSync(), isFalse);
      },
    );
  });

  test('the new config keys validate', () {
    final config = const AgentConfig()
        .set('engineExecutable', '/opt/syntila/engine')
        .set('workRoot', '/work');
    expect(config.engineExecutable, '/opt/syntila/engine');
    expect(config.toJson(), containsPair('workRoot', '/work'));
    expect(() => config.set('workRoot', ''), throwsFormatException);
  });
}
