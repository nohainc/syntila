@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:syntila_cli_worker_engine/src/plugin_host.dart';
import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

late Directory root;
late String engineBinary;
late String fixture;
late String fixtureDigest;
const workerTypeId = 'plugin-3fa91c04b2d7';

Future<void> compile(String source, String output) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    source,
    '-o',
    output,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
}

WorkerExecutor executor({List<String> arguments = const []}) => WorkerExecutor(
  pluginId: 'fixture-plugin',
  version: '1.0.0',
  manifestDigest: 'a' * 64,
  artifactSha256: fixtureDigest,
  executable: fixture,
  dataDirectory: root.path,
  arguments: arguments,
);

Directory temp(String name) => Directory.systemTemp.createTempSync(name);

void main() {
  setUpAll(() async {
    root = temp('plugin-supervisor');
    fixture = '${root.path}/fixture';
    engineBinary = '${root.path}/engine';
    await compile('test/fixtures/plugin_fixture.dart', fixture);
    await compile('bin/syntila_cli_worker.dart', engineBinary);
    fixtureDigest = await PluginHost().sha256OfFile(fixture);
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  CliWorkerEngineSupervisor supervisor() =>
      CliWorkerEngineSupervisor(engineExecutable: engineBinary);

  test('probes a plugin through the shared supervisor', () async {
    final result = await supervisor().probe(
      null,
      pluginExecutor: executor(),
      pluginWorkerTypeId: workerTypeId,
      stateDirectory: temp('state'),
      mode: WorkerProbeMode.passive,
    );
    expect(result.ready, isTrue);
  });

  test(
    'executes a plugin assignment with slots, progress and result',
    () async {
      final progress = <String?>[];
      var started = false;
      final result = await supervisor().execute(
        null,
        pluginExecutor: executor(),
        pluginWorkerTypeId: workerTypeId,
        stateDirectory: temp('state'),
        workingDirectory: temp('work'),
        workerId: 'worker-1',
        maxConcurrentAssignments: 1,
        assignmentId: 'asg-1',
        prompt: 'ping',
        timeout: const Duration(seconds: 30),
        executionPolicy: WorkerExecutionPolicy.providerDefault,
        onExecutionStarted: () => started = true,
        onProgress: (p) => progress.add(p.message),
      );
      expect(result.output, contains('ping'));
      expect(started, isTrue);
      expect(progress, contains('working'));
    },
  );

  test('surfaces a plugin failure as a stable Worker error', () async {
    await expectLater(
      supervisor().execute(
        null,
        pluginExecutor: executor(arguments: ['--fault=error']),
        pluginWorkerTypeId: workerTypeId,
        stateDirectory: temp('state'),
        workingDirectory: temp('work'),
        workerId: 'worker-1',
        maxConcurrentAssignments: 1,
        assignmentId: 'asg-2',
        prompt: 'x',
        timeout: const Duration(seconds: 30),
      ),
      throwsA(
        isA<CliWorkerEngineProbeException>().having(
          (e) => e.issueCode,
          'issueCode',
          WorkerIssueCode.providerAuthenticationRequired,
        ),
      ),
    );
  });

  test(
    'a target must be either a Profile or a plugin, never both or neither',
    () {
      expect(
        () => supervisor().probe(
          null,
          stateDirectory: temp('state'),
          mode: WorkerProbeMode.passive,
        ),
        throwsArgumentError,
      );
    },
  );
}
