@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_mcp_worker_store/syntila_mcp_worker_store.dart';
import 'package:syntila_worker_agent/src/cli_engine.dart';
import 'package:syntila_worker_agent/src/engine.dart';
import 'package:syntila_worker_agent/src/journal.dart' show TerminalKind;
import 'package:syntila_worker_agent/src/mcp_worker_allow_list.dart';
import 'package:syntila_worker_agent/src/mcp_worker_runner.dart';
import 'package:test/test.dart';

import '../../workspace/test/support/external_worker_package.dart';

void main() {
  pinTests();
  test(
    'requires exact approval and inspected pins, then executes the fake MCP Worker through the Engine',
    () async {
      final root = await Directory.systemTemp.createTemp('mcp-agent-test-');
      addTearDown(() => root.delete(recursive: true));
      final repo = Directory.current.parent.parent.path;
      final engine = '$repo/engines/cli_worker/bin/syntila_cli_worker.dart';
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
          engineExecutable: Platform.resolvedExecutable,
          engineArgumentsPrefix: ['-DENGINE_VERSION=1.4.0', engine],
          processRegistryDirectory: Directory('${root.path}/processes'),
        ),
        engineExecutable: Platform.resolvedExecutable,
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
      await File(installed.executablePath).writeAsString('tampered');
      await expectLater(
        runner.prepare(pin),
        throwsA(isA<ExternalWorkerException>()),
      );
    },
  );
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
      expect(() => workerToolPins(tools), throwsA(isA<ExternalWorkerException>()));
    }
  });
}
