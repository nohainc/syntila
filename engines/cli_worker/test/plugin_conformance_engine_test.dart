@Timeout(Duration(minutes: 6))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/plugin_host.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

import 'support/plugin_test_binaries.dart';

late Directory root;
late String engineBinary;
late String referencePlugin;
late String referenceDigest;

WorkerExecutor executor(List<String> arguments) => WorkerExecutor(
  pluginId: 'ref-plugin',
  version: '1.0.0',
  manifestDigest: 'a' * 64,
  artifactSha256: referenceDigest,
  executable: referencePlugin,
  dataDirectory: root.path,
  arguments: arguments,
);

Future<(List<WorkerProgress>, ConformanceResult)> runConformance(
  List<String> pluginArguments,
) async {
  final work = Directory.systemTemp.createTempSync('conf-engine-work');
  final state = Directory.systemTemp.createTempSync('conf-engine-state');
  final process = await Process.start(engineBinary, [
    '--plugin',
    '--engine-version',
    '1.4.0',
    '--state-directory',
    state.path,
  ], workingDirectory: work.path);
  final frames = StreamIterator(
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(decodeWorkerFrame),
  );
  final e = executor(pluginArguments);
  process.stdin.writeln(
    InitializeRequest(
      requestId: 'init-1',
      workerTypeId: 'plugin-3fa91c04b2d7',
      expectedEngineVersion: '1.4.0',
      profileDefinitionId: 'plugin-ref-plugin',
      profileReleaseVersion: '1.0.0',
      profileDigest: e.manifestDigest,
      executor: e,
      protocolVersion: pluginExecutorProtocolVersion,
    ).encode(),
  );
  expect(await frames.moveNext(), isTrue);
  expect(frames.current, isA<InitializeResult>());
  process.stdin.writeln(
    ConformanceRequest(
      requestId: 'conf-1',
      declaredCapabilities: const {'progress': true},
    ).encode(),
  );
  final progress = <WorkerProgress>[];
  while (await frames.moveNext().timeout(const Duration(minutes: 4))) {
    final frame = frames.current;
    if (frame is WorkerProgress) progress.add(frame);
    if (frame is ConformanceResult) {
      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 10));
      return (progress, frame);
    }
    if (frame is WorkerErrorFrame) fail('unexpected error ${frame.code}');
  }
  fail('Engine closed before the conformance result');
}

void main() {
  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('conf-engine');
    final binaries = await PluginTestBinaries.ensure();
    engineBinary = binaries.engine;
    referencePlugin = binaries.reference;
    referenceDigest = await PluginHost().sha256OfFile(referencePlugin);
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  test(
    'runs the conformance suite inside the Engine and streams progress',
    () async {
      final (progress, result) = await runConformance(const []);
      final failed = result.cases.where((c) => c.status == 'failed');
      expect(failed.map((c) => '${c.id}: ${c.detail}'), isEmpty);
      expect(result.passed, isTrue);
      expect(result.suiteVersion, '1.0.0');
      expect(
        progress.map((p) => p.message),
        contains('conformance:handshake.identity:passed'),
      );
    },
  );

  test(
    'reports a protocol fault as a failed case, not an Engine error',
    () async {
      final (_, result) = await runConformance(const ['--fault=two-terminals']);
      expect(result.passed, isFalse);
      expect(
        result.cases
            .singleWhere((c) => c.id == 'execute.single_terminal_frame')
            .status,
        'failed',
      );
    },
  );
}
