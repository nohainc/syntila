@Timeout(Duration(minutes: 8))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:syntila_workspace/local_worker_registry.dart';
import 'package:syntila_workspace/mcp_engine_probe.dart';
import 'package:syntila_workspace/plugin_engine_conformance.dart';
import 'package:syntila_workspace/plugin_mcp_inspect.dart';
import 'package:syntila_workspace/plugin_registry.dart';
import 'package:syntila_workspace/plugin_service.dart';
import 'package:syntila_workspace/plugin_store.dart';
import 'package:syntila_workspace/plugin_worker_runtime.dart';
import 'package:syntila_workspace/worker_readiness.dart';
import 'package:test/test.dart';

import 'support/plugin_fakes.dart';

/// An MCP Worker as a plugin package: import -> profile check through the real
/// Engine -> consent -> enable -> readiness -> an assignment, with only Cloud
/// faked. Compiles the current Engine and the reference Worker itself.
void main() {
  late Directory temp;
  late String engineBinary;
  late String package;

  Future<void> compile(String source, String output, String cwd) async {
    final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'compile',
          'exe',
          source,
          '-o',
          output,
        ],
        workingDirectory: cwd);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('mcp-plugin-e2e');
    engineBinary = '${temp.path}/engine';
    await compile(
      'bin/syntila_cli_worker.dart',
      engineBinary,
      '../../engines/cli_worker',
    );
    final worker = '${temp.path}/echo-worker';
    await compile(
      'echo_worker.dart',
      worker,
      '../../examples/mcp/echo_worker',
    );
    final bytes = File(worker).readAsBytesSync();
    package = '${temp.path}/package';
    Directory('$package/bin').createSync(recursive: true);
    File('$package/bin/run').writeAsBytesSync(bytes);
    File('$package/plugin.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'kind': 'mcp',
        'pluginId': 'echo-worker',
        'version': '1.0.0',
        'displayName': 'Echo MCP Worker',
        'description': 'End to end MCP Worker fixture.',
        'author': {'name': 'Syntila tests'},
        'protocol': {'min': '1.0', 'max': '1.0'},
        'artifacts': {
          currentPluginPlatform(): {
            'command': 'bin/run',
            'args': <String>[],
            'sha256': sha256.convert(bytes).toString(),
            'size': bytes.length,
          },
        },
        'capabilities': {'progress': true},
        'access': {
          'workRoot': 'write',
          'network': {'mode': 'none'},
          'subprocess': false,
          'env': <String>[],
        },
      }),
    );
    Process.runSync('chmod', ['755', '$package/bin/run']);
  });

  tearDownAll(() {
    Process.runSync('chmod', ['-R', 'u+w', temp.path]);
    temp.deleteSync(recursive: true);
  });

  test('import, check, register, enable and run an MCP Worker', () async {
    final state = Directory('${temp.path}/state/Plugins');
    final store = PluginStore(
      root: state,
      forbiddenRoots: ['${temp.path}/state'],
      clock: () => testStart,
    );
    final registry = PluginRegistry(File('${state.path}/registry.json'));
    final supervisor =
        CliWorkerEngineSupervisor(engineExecutable: engineBinary);
    final workers = LocalWorkerRegistry(
      dataDirectory: Directory('${temp.path}/workers')..createSync(),
      workspaceId: 'ws-1',
    );
    Directory engineState(String id) =>
        Directory('${state.path}/engine-state/$id');
    final runtime = PluginWorkerRuntime(
      store: store,
      registry: registry,
      engineStateDirectory: engineState,
      probe: ({
        required executor,
        required workerTypeId,
        required stateDirectory,
        required mode,
      }) =>
          supervisor.probe(
        null,
        pluginExecutor: executor,
        pluginWorkerTypeId: workerTypeId,
        stateDirectory: stateDirectory,
        mode: mode,
      ),
    );
    late final WorkerReadinessMonitor monitor;
    final service = WorkspacePluginService(
      store: store,
      registry: registry,
      cloud: FakePluginCloud(),
      conformance: EnginePluginConformance(
        supervisor: supervisor,
        store: store,
        engineStateDirectory: engineState,
      ),
      mcpInspect: EnginePluginMcpInspect(
        EngineMcpProbe(
          workingDirectory: Directory('${state.path}/mcp-probe'),
          locateEngine: () => (executable: engineBinary, argumentsPrefix: []),
        ),
      ),
      workerHost: LocalPluginWorkerHost(
        workers: workers,
        afterChange: (ref) => monitor.checkNow(
          mode: LocalWorkerProbeMode.passive,
          workerTypeId: ref,
          includeDisabled: true,
        ),
      ),
      clock: () => testStart,
    );
    monitor = WorkerReadinessMonitor(
      registry: workers,
      pluginAssessor: runtime.assess,
    );

    expect((await service.import(package))['pluginId'], 'echo-worker');

    // The profile check runs inside the Engine against the real binary.
    final report = await service.test('echo-worker');
    expect(report['passed'], isTrue, reason: '$report');
    expect(report['suiteVersion'], 'mcp-worker-profile-1');

    Future<Map<String, Object?>> accept(
      Future<Map<String, Object?>> Function(String? hash) call,
    ) async {
      final shown = await call(null);
      expect(shown['consentRequired'], isTrue);
      return call(shown['documentHash'] as String);
    }

    final consent = await service.register('echo-worker');
    final tools = ((consent['document'] as Map)['mcp'] as Map)['tools'] as List;
    expect([
      for (final t in tools) (t as Map)['name']
    ], [
      'syntila.execute',
      'syntila.probe',
    ]);
    await accept((h) => service.register('echo-worker', acceptHash: h));
    await accept((h) => service.enable('echo-worker', acceptHash: h));

    final worker = (await workers.list()).single;
    expect(
      worker.readinessState,
      WorkerReadinessState.ready,
      reason: jsonEncode(worker.toJson()),
    );

    final execution = await runtime.prepareExecution(worker.workerTypeId);
    expect(execution.executor.isMcp, isTrue);
    expect(execution.executor.toolPins.keys, contains('syntila.execute'));
    final progress = <String?>[];
    final result = await supervisor.execute(
      null,
      pluginExecutor: execution.executor,
      pluginWorkerTypeId: worker.workerTypeId,
      stateDirectory: engineState('echo-worker'),
      workingDirectory: Directory('${temp.path}/space')..createSync(),
      workerId: worker.id,
      maxConcurrentAssignments: 1,
      assignmentId: 'assignment-1',
      prompt: 'hello from the Space',
      timeout: const Duration(seconds: 60),
      executionPolicy: WorkerExecutionPolicy.providerDefault,
      onProgress: (p) => progress.add(p.message),
    );
    expect(result.output, startsWith('echo: hello from the Space'));
    expect(progress, contains('working'));

    // Tampering with the installed bytes is refused before anything runs.
    Process.runSync('chmod', ['-R', 'u+w', execution.plugin.directory.path]);
    File(execution.plugin.executablePath).writeAsStringSync('swapped');
    await expectLater(
      runtime.prepareExecution(worker.workerTypeId),
      throwsA(
        isA<PluginServiceException>().having(
          (e) => e.code,
          'code',
          'plugin_digest_mismatch',
        ),
      ),
    );
  });
}
