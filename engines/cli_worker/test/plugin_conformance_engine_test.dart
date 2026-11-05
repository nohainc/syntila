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
  List<String> pluginArguments, {
  WorkerExecutor? admittedExecutor,
  Map<String, Object?> capabilities = const {'progress': true},
}) async {
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
  addTearDown(() async {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 10));
    await frames.cancel();
    work.deleteSync(recursive: true);
    state.deleteSync(recursive: true);
  });
  final e = admittedExecutor ?? executor(pluginArguments);
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
      declaredCapabilities: capabilities,
      declaresResume: capabilities['sessionResume'] == true,
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
      expect(result.suiteVersion, '1.1.0');
      expect(
        progress.map((p) => p.message),
        contains('conformance:handshake.identity:passed'),
      );
    },
  );

  test('SDK echo passes every case through the Engine host', () async {
    final example = Directory('../../examples/plugins/echo_dart').absolute;
    final dependencies = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
    ], workingDirectory: example.path);
    expect(dependencies.exitCode, 0, reason: '${dependencies.stderr}');
    final binary = '${root.path}/sdk-echo${Platform.isWindows ? '.exe' : ''}';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/echo_dart.dart',
      '-o',
      binary,
    ], workingDirectory: example.path);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}${compiled.stderr}',
    );
    final (_, result) = await runConformance(
      const [],
      admittedExecutor: WorkerExecutor(
        pluginId: 'echo-dart',
        version: '1.0.0',
        manifestDigest: 'b' * 64,
        artifactSha256: await PluginHost().sha256OfFile(binary),
        executable: binary,
        dataDirectory: root.path,
      ),
      capabilities: const {'progress': true, 'sessionResume': true},
    );
    expect(result.cases, hasLength(21));
    expect(
      result.cases
          .where((c) => c.status != 'passed')
          .map((c) => '${c.id}: ${c.status}: ${c.detail}'),
      isEmpty,
    );
    expect(result.passed, isTrue);
  });

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
