@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:syntila_workspace/local_worker_registry.dart';
import 'package:syntila_workspace/plugin_engine_conformance.dart';
import 'package:syntila_workspace/plugin_entitlement.dart';
import 'package:syntila_workspace/plugin_registry.dart';
import 'package:syntila_workspace/plugin_service.dart';
import 'package:syntila_workspace/plugin_store.dart';
import 'package:syntila_workspace/plugin_worker_runtime.dart';
import 'package:syntila_workspace/worker_readiness.dart';
import 'package:test/test.dart';

import 'support/plugin_fakes.dart';

/// Service store -> registry -> real compiled Engine -> real plugin process,
/// with only Cloud faked. This is the path an assignment takes after Cloud has
/// scheduled a plugin Worker.
void main() {
  final engine = File('assets/engines/syntila-agent').absolute;
  late Directory temp;
  late String pluginBinary;
  late String package;

  setUpAll(() async {
    if (!engine.existsSync()) {
      markTestSkipped(
          'The generic Engine is not built (run validate:workspace).');
      return;
    }
    temp = Directory.systemTemp.createTempSync('plugin-e2e');
    pluginBinary = '${temp.path}/reference';
    final compiled = await Process.run(
      Platform.resolvedExecutable,
      [
        'compile',
        'exe',
        'test/fixtures/reference_plugin.dart',
        '-o',
        pluginBinary,
      ],
      workingDirectory: '../../packages/syntila_plugin_conformance',
    );
    expect(compiled.exitCode, 0,
        reason: '${compiled.stdout}${compiled.stderr}');

    final bytes = File(pluginBinary).readAsBytesSync();
    package = '${temp.path}/package';
    Directory('$package/bin').createSync(recursive: true);
    File('$package/bin/run').writeAsBytesSync(bytes);
    File('$package/plugin.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'pluginId': 'ref-plugin',
        'version': '1.0.0',
        'displayName': 'Reference',
        'description': 'End to end fixture.',
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
    if (engine.existsSync()) {
      Process.runSync('chmod', ['-R', 'u+w', temp.path]);
      temp.deleteSync(recursive: true);
    }
  });

  test(
    'import, conformance, register, enable and run a plugin through the Engine',
    () async {
      final state = Directory('${temp.path}/state/Plugins');
      final store = PluginStore(
        root: state,
        forbiddenRoots: ['${temp.path}/state'],
        clock: () => testStart,
      );
      final registry = PluginRegistry(File('${state.path}/registry.json'));
      final entitlement = PluginEntitlementStore(
        file: File('${state.path}/entitlement.json'),
        verifier: PluginLeaseVerifier({
          pluginEntitlementPublisher: {'ent-1': testLeasePublicKey},
        }),
        workspaceId: 'ws-1',
        installationId: 'inst-1',
        clock: () => testStart,
      );
      final supervisor = CliWorkerEngineSupervisor(
        engineExecutable: engine.path,
      );
      final workers = LocalWorkerRegistry(
        dataDirectory: Directory('${temp.path}/workers')..createSync(),
        workspaceId: 'ws-1',
      );
      final runtime = PluginWorkerRuntime(
        store: store,
        registry: registry,
        entitlement: entitlement,
        engineStateDirectory: (id) =>
            Directory('${state.path}/engine-state/$id'),
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
        entitlement: entitlement,
        cloud: FakePluginCloud(),
        conformance: EnginePluginConformance(
          supervisor: supervisor,
          store: store,
          engineStateDirectory: (id) =>
              Directory('${state.path}/engine-state/$id'),
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

      // Import copies the package into the digest-addressed read-only store.
      final imported = await service.import(package);
      expect(imported['pluginId'], 'ref-plugin');

      // The conformance suite runs inside the Engine against the real binary.
      final report = await service.test('ref-plugin');
      final failed = (report['cases'] as List).where(
        (c) => (c as Map)['status'] == 'failed',
      );
      expect(failed, isEmpty, reason: '$failed');
      expect(report['passed'], isTrue);

      Future<void> accept(
        Future<Map<String, Object?>> Function(String? hash) call,
      ) async {
        final shown = await call(null);
        await call(shown['documentHash'] as String);
      }

      await accept((h) => service.register('ref-plugin', acceptHash: h));
      await accept((h) => service.enable('ref-plugin', acceptHash: h));

      // The enabled plugin is an ordinary local Worker, probed through the
      // Engine, and ready without any Tool Profile or catalog.
      final worker = (await workers.list()).single;
      expect(worker.workerTypeId, 'plugin-3fa91c04b2d7');
      expect(worker.readinessState, WorkerReadinessState.ready);

      // An assignment: verified at the moment of use, then run by the Engine.
      final execution = await runtime.prepareExecution(worker.workerTypeId);
      final progress = <String?>[];
      final result = await supervisor.execute(
        null,
        pluginExecutor: execution.executor,
        pluginWorkerTypeId: worker.workerTypeId,
        stateDirectory: Directory('${state.path}/engine-state/ref-plugin'),
        workingDirectory: Directory('${temp.path}/space')..createSync(),
        workerId: worker.id,
        maxConcurrentAssignments: 1,
        assignmentId: 'assignment-1',
        prompt: 'hello from the Space',
        timeout: const Duration(seconds: 60),
        executionPolicy: WorkerExecutionPolicy.providerDefault,
        onProgress: (p) => progress.add(p.message),
      );
      expect(result.output, startsWith('echo:'));
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
    },
  );
}
