@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/mcp_host.dart';
import 'package:syntila_cli_worker_engine/src/mcp_worker_runner.dart';
import 'package:syntila_cli_worker_engine/src/plugin_host.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

import 'support/plugin_test_binaries.dart';

const workerPath =
    '../../packages/syntila_plugin_sdk/test/fixtures/sdk_mcp_worker.dart';

late String dartDigest;
late String engineBinary;
late Directory root;
final plugins = PluginHost();

McpServerSpec spec({ToolPins? pins}) => McpServerSpec(
  serverId: 'sdk-echo',
  workspaceId: 'ws1',
  requireWorkerProfile: true,
  pins: pins,
  launch: PluginLaunch(
    executable: Platform.resolvedExecutable,
    arguments: [File(workerPath).absolute.path],
    artifactSha256: dartDigest,
    pluginId: 'sdk-echo',
    version: '1.0.0',
    dataDirectory: root.path,
    workingDirectory: root.path,
    environment: PluginHost.buildEnvironment(),
    hostVersion: '1.4.0',
  ),
);

PluginRunRequest request(
  String prompt, {
  String? sessionKey,
  String mode = 'new',
}) => PluginRunRequest(
  executeId: 'e1',
  prompt: prompt,
  access: 'read_only',
  deadline: const Duration(seconds: 60),
  model: 'echo:1',
  sessionKey: sessionKey,
  sessionMode: mode,
);

void main() {
  late McpHost host;
  late McpWorkerRunner runner;

  Future<McpServerSpec> consented() async {
    final lease = await host.acquire(spec());
    final pins = ToolPins.fromTools(lease.tools);
    lease.release();
    return spec(pins: pins);
  }

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('mcp-sdk-worker');
    dartDigest = await plugins.sha256OfFile(Platform.resolvedExecutable);
    engineBinary = (await PluginTestBinaries.ensure()).engine;
  });
  tearDownAll(() => root.deleteSync(recursive: true));
  setUp(() {
    host = McpHost(pluginHost: plugins);
    runner = McpWorkerRunner(host);
  });
  tearDown(() => host.closeAll());

  test('an SDK Worker passes the profile checks end to end', () async {
    final s = await consented();
    final ready = await runner.probe(s, 'live') as PluginProbeSuccess;
    expect(ready.state, 'ready');
    expect(ready.checks.single['message'], 'live check');
    expect(ready.capabilities['modelDiscovery'], isTrue);
    final models = await runner.models(s) as PluginModelsSuccess;
    expect(models.models.single['id'], 'echo:1');
  });

  test(
    'execute: progress with percentages, model, read-only and session',
    () async {
      final s = await consented();
      final progress = <(int?, String)>[];
      final created =
          await runner.run(
                s,
                request('hello', sessionKey: 's1'),
                onProgress: (p, m) => progress.add((p, m)),
              )
              as PluginRunSuccess;
      expect(created.output, contains('sdk echo: hello'));
      expect(created.output, contains('model echo:1'));
      expect(created.output, contains('readOnly true'));
      expect(created.sessionState, 'created');
      expect(progress.map((p) => p.$2), ['step one', 'step two']);
      expect(progress.map((p) => p.$1), [25, 75]);
      final resumed =
          await runner.run(
                s,
                request('again', sessionKey: 's1', mode: 'resume'),
              )
              as PluginRunSuccess;
      expect(resumed.sessionState, 'resumed');
    },
  );

  test('a cooperative cancel ends the run promptly without a kill', () async {
    final s = await consented();
    final cancel = Completer<void>();
    final clock = Stopwatch()..start();
    final running = runner.run(s, request('WAIT'), cancel: cancel.future);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    cancel.complete();
    final outcome = await running as PluginRunFailure;
    expect(outcome.code, 'cancelled');
    // Far below the 5 s grace: the Worker answered the cancel itself.
    expect(
      clock.elapsed,
      lessThan(McpLimits.cancelGrace + const Duration(seconds: 3)),
    );
    expect(
      clock.elapsed - const Duration(milliseconds: 800),
      lessThan(const Duration(seconds: 3)),
    );
  });

  test('a PluginFailure keeps its code and retryable flag', () async {
    final failure =
        await runner.run(await consented(), request('FAIL'))
            as PluginRunFailure;
    expect(failure.code, 'rate_limited');
    expect(failure.retryable, isTrue);
    expect(failure.fromPlugin, isTrue);
  });

  test('the Engine gives an MCP Worker its data directory', () async {
    final state = Directory.systemTemp.createTempSync('mcp-sdk-state');
    final data = Directory('${root.path}/data')..createSync();
    final lease = await host.acquire(spec());
    final pins = {
      for (final e in ToolPins.fromTools(lease.tools).hashes.entries)
        e.key: e.value,
    };
    lease.release();
    final executor = WorkerExecutor(
      pluginId: 'sdk-echo',
      version: '1.0.0',
      manifestDigest: 'a' * 64,
      artifactSha256: dartDigest,
      executable: Platform.resolvedExecutable,
      dataDirectory: data.path,
      arguments: [File(workerPath).absolute.path],
      protocol: 'mcp',
      toolPins: pins,
    );
    final process = await Process.start(engineBinary, [
      '--plugin',
      '--engine-version',
      '1.4.0',
      '--state-directory',
      state.path,
    ], workingDirectory: root.path);
    final frames = StreamIterator(
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map(decodeWorkerFrame),
    );
    addTearDown(() async {
      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 20));
    });
    process.stdin.writeln(
      InitializeRequest(
        requestId: 'i',
        workerTypeId: 'plugin-3fa91c04b2d7',
        expectedEngineVersion: '1.4.0',
        profileDefinitionId: 'plugin-sdk-echo',
        profileReleaseVersion: '1.0.0',
        profileDigest: executor.manifestDigest,
        executor: executor,
        protocolVersion: mcpExecutorProtocolVersion,
      ).encode(),
    );
    expect(await frames.moveNext(), isTrue);
    expect(frames.current, isA<InitializeResult>());
    process.stdin.writeln(
      ExecuteRequest(
        requestId: 'r',
        assignmentId: 'a',
        prompt: 'DATA please',
        timeoutMs: 60000,
        sessionPolicy: WorkerSessionPolicy.stateless,
        executionPolicy: WorkerExecutionPolicy.providerDefault,
        executor: executor,
        protocolVersion: mcpExecutorProtocolVersion,
      ).encode(),
    );
    WorkerFrame last;
    do {
      expect(
        await frames.moveNext().timeout(const Duration(seconds: 60)),
        isTrue,
      );
      last = frames.current;
    } while (last is! WorkerResult && last is! WorkerErrorFrame);
    expect(last, isA<WorkerResult>(), reason: '$last');
    expect((last as WorkerResult).output, 'data=${data.path}');
  });
}
