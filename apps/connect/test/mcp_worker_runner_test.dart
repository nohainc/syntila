@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_mcp_worker_store/syntila_mcp_worker_store.dart';
import 'package:syntila_connect/src/cli_engine.dart';
import 'package:syntila_connect/src/engine.dart';
import 'package:syntila_connect/src/journal.dart' show TerminalKind;
import 'package:syntila_connect/src/mcp_worker_allow_list.dart';
import 'package:syntila_connect/src/mcp_worker_runner.dart';
import 'package:test/test.dart';

import 'support/external_worker_package.dart';

void main() {
  pinTests();
  test(
    'requires exact approval and inspected pins, then executes the fake MCP Worker through the Engine',
    () async {
      final root = await Directory.systemTemp.createTemp('mcp-agent-test-');
      addTearDown(() async {
        if (!Platform.isWindows && root.existsSync()) {
          await Process.run('chmod', ['-R', 'u+w', root.path]);
        }
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final repo = Directory.current.parent.parent.path;
      final engine = '$repo/engines/cli_worker/bin/syntila_cli_worker.dart';
      final engineBinary = await _ensureEngineBinary(repo);
      final worker = '$repo/examples/mcp/echo_worker/echo_worker.dart';
      final source = writeExternalWorkerPackage(
        root,
        body: '#!/bin/sh\nexec "${Platform.resolvedExecutable}" "$worker"\n',
      );
      final store = ExternalWorkerStore(
        root: Directory('${root.path}/store'),
        platform: 'linux-x64',
      );
      final installed = await store.import(source);
      final allow = McpWorkerAllowList(File('${root.path}/approved.json'));
      final runner = McpWorkerRunner(
        store: store,
        allowList: allow,
        pinsFile: File('${root.path}/pins.json'),
      );
      final pin = {
        'id': installed.pluginId,
        'version': installed.version,
        'manifestDigest': installed.manifestDigest,
      };
      await expectLater(
        runner.prepare(pin),
        throwsA(
          isA<ExternalWorkerException>().having(
            (e) => e.code,
            'code',
            'mcp_worker_not_approved',
          ),
        ),
      );
      await allow.approve(
        installed.pluginId,
        installed.version,
        installed.manifestDigest,
      );
      await expectLater(
        runner.prepare(pin),
        throwsA(
          isA<ExternalWorkerException>().having(
            (e) => e.code,
            'code',
            'plugin_conformance_required',
          ),
        ),
      );
      expect(await runner.runnable(), isEmpty);
      final inspection = McpEngineInspection(
        locateEngine: () => (
          executable: Platform.resolvedExecutable,
          argumentsPrefix: [engine],
        ),
        workingDirectory: Directory('${root.path}/probe'),
      );
      await runner.record(installed, await inspection.inspectWorker(installed));
      expect(await runner.runnable(), [
        {
          'id': installed.pluginId,
          'version': installed.version,
          'manifestDigest': installed.manifestDigest,
        },
      ]);
      expect(
        (await runner.prepare(pin)).toolPins.keys,
        containsAll(['syntila.execute', 'syntila.probe']),
      );
      final launcher = CliEngineLauncher(
        supervisor: CliWorkerEngineSupervisor(
          engineExecutable: engineBinary,
          processRegistryDirectory: Directory('${root.path}/processes'),
        ),
        engineExecutable: engineBinary,
        resolveProfile: (_) async => null,
        workerId: 'worker-1',
        stateDirectory: Directory('${root.path}/state'),
        workRoot: Directory('${root.path}/work'),
        mcpWorkerRunner: runner,
      );
      final run = await launcher.launch(
        EngineRequest(
          assignmentId: 'assignment-1',
          attemptId: 'attempt-1',
          payload: {
            'snapshot': {
              'plugin': pin,
              'workerTypeId': 'plugin-3fa91c04b2d7',
              'sessionPolicy': 'stateless',
              'objective': 'hello',
            },
          },
        ),
      );
      final outcome = await run.outcome.timeout(const Duration(seconds: 60));
      expect(
        outcome.kind,
        TerminalKind.completed,
        reason: '${outcome.payload}',
      );
      expect('${outcome.payload}', contains('echo: hello'));
      if (!Platform.isWindows) {
        await Process.run('chmod', ['u+w', installed.executablePath]);
      }
      await File(installed.executablePath).writeAsString('tampered');
      await expectLater(
        runner.prepare(pin),
        throwsA(isA<ExternalWorkerException>()),
      );
    },
  );
}

Future<String> _ensureEngineBinary(String repo) async {
  final cache = Directory('${Directory.current.path}/.dart_tool/mcp-test-bin')
    ..createSync(recursive: true);
  final suffix = Platform.isWindows ? '.exe' : '';
  final output = '${cache.path}/engine$suffix';
  final engineDir = '$repo/engines/cli_worker';
  var newest = DateTime.fromMillisecondsSinceEpoch(0);
  for (final dir in [
    '$engineDir/bin',
    '$engineDir/lib',
    '$repo/packages/syntila_cli_worker_runtime/lib',
    '$repo/packages/syntila_external_worker_conformance/lib',
    '$repo/packages/syntila_external_worker_protocol/lib',
    '$repo/packages/syntila_mcp_protocol/lib',
    '$repo/packages/syntila_worker_protocol/lib',
  ]) {
    final d = Directory(dir);
    if (!d.existsSync()) continue;
    for (final entity in d.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        final modified = entity.lastModifiedSync();
        if (modified.isAfter(newest)) newest = modified;
      }
    }
  }
  final file = File(output);
  if (!file.existsSync() || !file.lastModifiedSync().isAfter(newest)) {
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '-DENGINE_VERSION=1.4.0',
      'bin/syntila_cli_worker.dart',
      '-o',
      output,
    ], workingDirectory: engineDir);
    if (result.exitCode != 0) {
      throw StateError(
        'compile syntila_cli_worker.dart failed: ${result.stdout}${result.stderr}',
      );
    }
  }
  return output;
}

void pinTests() {
  Map<String, Object?> tool(String name) => {
    'name': name,
    'description': 'd',
    'inputSchema': {'type': 'object'},
  };

  test('tool pins need both Worker tools and no duplicates', () {
    expect(
      workerToolPins([tool('syntila.execute'), tool('syntila.probe')]).keys,
      containsAll(['syntila.execute', 'syntila.probe']),
    );
    for (final tools in [
      [tool('syntila.execute')],
      [tool('syntila.probe')],
      [tool('syntila.execute'), tool('syntila.probe'), tool('syntila.probe')],
      <Map<String, Object?>>[],
    ]) {
      expect(
        () => workerToolPins(tools),
        throwsA(isA<ExternalWorkerException>()),
      );
    }
  });
}
