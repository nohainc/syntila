@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/plugin_engine.dart';
import 'package:syntila_cli_worker_engine/src/plugin_host.dart';
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

late Directory root;
late String engineBinary;
late String fixture;
late String fixtureDigest;

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

WorkerExecutor executor({List<String> arguments = const [], String? digest}) =>
    WorkerExecutor(
      pluginId: 'fixture-plugin',
      version: '1.0.0',
      manifestDigest: 'a' * 64,
      artifactSha256: digest ?? fixtureDigest,
      executable: fixture,
      dataDirectory: root.path,
      arguments: arguments,
    );

/// One plugin-mode Engine process spoken to over stdio, as the Service will.
class EngineProcess {
  EngineProcess._(this.process, this.frames);
  final Process process;
  final StreamIterator<WorkerFrame> frames;

  static Future<EngineProcess> start() async {
    final work = Directory.systemTemp.createTempSync('plugin-engine-work');
    final state = Directory.systemTemp.createTempSync('plugin-engine-state');
    final process = await Process.start(engineBinary, [
      '--plugin',
      '--engine-version',
      '1.4.0',
      '--state-directory',
      state.path,
    ], workingDirectory: work.path);
    final frames = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(decodeWorkerFrame);
    return EngineProcess._(process, StreamIterator(frames));
  }

  void send(WorkerFrame frame) => process.stdin.writeln(frame.encode());

  Future<WorkerFrame> next() async {
    expect(
      await frames.moveNext().timeout(const Duration(seconds: 30)),
      isTrue,
    );
    return frames.current;
  }

  /// Frames up to and including the terminal result or error.
  Future<List<WorkerFrame>> untilTerminal() async {
    final seen = <WorkerFrame>[];
    while (true) {
      final frame = await next();
      seen.add(frame);
      if (frame is WorkerResult || frame is WorkerErrorFrame) return seen;
    }
  }

  Future<void> close() async {
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 10));
  }
}

InitializeRequest initialize(WorkerExecutor e) => InitializeRequest(
  requestId: 'init-1',
  workerTypeId: 'plugin-3fa91c04b2d7',
  expectedEngineVersion: '1.4.0',
  profileDefinitionId: 'plugin-fixture-plugin',
  profileReleaseVersion: '1.0.0',
  profileDigest: e.manifestDigest,
  executor: e,
  protocolVersion: pluginExecutorProtocolVersion,
);

ExecuteRequest execute(
  WorkerExecutor e, {
  String prompt = 'hi',
  WorkerExecutionPolicy policy = WorkerExecutionPolicy.providerDefault,
}) => ExecuteRequest(
  requestId: 'req-1',
  assignmentId: 'asg-1',
  prompt: prompt,
  timeoutMs: 20000,
  sessionPolicy: WorkerSessionPolicy.stateless,
  executionPolicy: policy,
  executor: e,
  protocolVersion: pluginExecutorProtocolVersion,
);

void main() {
  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('plugin-engine');
    fixture = '${root.path}/fixture';
    engineBinary = '${root.path}/engine';
    await compile('test/fixtures/plugin_fixture.dart', fixture);
    await compile('bin/syntila_cli_worker.dart', engineBinary);
    fixtureDigest = await PluginHost().sha256OfFile(fixture);
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  test('initializes, probes and executes a plugin end to end', () async {
    final engine = await EngineProcess.start();
    final e = executor();
    engine.send(initialize(e));
    final init = await engine.next();
    expect(init, isA<InitializeResult>());
    expect(
      (init as InitializeResult).profileDefinitionId,
      'plugin-fixture-plugin',
    );

    engine.send(
      ProbeRequest(requestId: 'probe-1', mode: WorkerProbeMode.passive),
    );
    final probe = await engine.next();
    expect(probe, isA<ProbeResult>());
    expect((probe as ProbeResult).ready, isTrue);

    engine.send(execute(e, prompt: 'hello'));
    final frames = await engine.untilTerminal();
    expect(
      frames.whereType<WorkerProgress>().map((p) => p.message),
      contains(workerProviderExecutionStartedMessage),
    );
    final result = frames.last as WorkerResult;
    expect(result.output, contains('echo: '));
    expect(result.output, contains('hello'));
    await engine.close();
  });

  test('rejects work before initialization', () async {
    final engine = await EngineProcess.start();
    engine.send(execute(executor()));
    final frame = await engine.next();
    expect(frame, isA<WorkerErrorFrame>());
    await engine.close();
  });

  test(
    'refuses an execute whose executor differs from the admitted one',
    () async {
      final engine = await EngineProcess.start();
      engine.send(initialize(executor()));
      await engine.next();
      engine.send(execute(executor(digest: 'c' * 64)));
      final frame = await engine.next() as WorkerErrorFrame;
      expect(frame.code, WorkerIssueCode.profileIdentityMismatch);
      await engine.close();
    },
  );

  test('a swapped artifact is refused before any plugin code runs', () async {
    final engine = await EngineProcess.start();
    final wrong = executor(digest: 'd' * 64);
    engine.send(initialize(wrong));
    await engine.next();
    engine.send(execute(wrong));
    final error = (await engine.untilTerminal()).last as WorkerErrorFrame;
    expect(error.code, WorkerIssueCode.profileIdentityMismatch);
    expect(error.diagnostics, contains('plugin_digest_mismatch'));
    await engine.close();
  });

  test('maps a plugin sign-in error to the stable provider code', () async {
    final engine = await EngineProcess.start();
    final e = executor(arguments: ['--fault=error']);
    engine.send(initialize(e));
    await engine.next();
    engine.send(execute(e));
    final error = (await engine.untilTerminal()).last as WorkerErrorFrame;
    expect(error.code, WorkerIssueCode.providerAuthenticationRequired);
    expect(error.retryable, isFalse);
    await engine.close();
  });

  test('a plugin that crashes is a retryable provider failure', () async {
    final engine = await EngineProcess.start();
    final e = executor(arguments: ['--fault=crash']);
    engine.send(initialize(e));
    await engine.next();
    engine.send(execute(e));
    final error = (await engine.untilTerminal()).last as WorkerErrorFrame;
    expect(error.code, WorkerIssueCode.providerFailure);
    expect(error.retryable, isTrue);
    expect(error.diagnostics, contains('plugin_crashed'));
    await engine.close();
  });

  group('options and mapping', () {
    test('parses plugin mode and rejects incomplete options', () {
      final state = Directory.systemTemp.path;
      expect(
        PluginEngineOptions.isPluginMode([
          '--plugin',
          '--engine-version',
          '1.4.0',
        ]),
        isTrue,
      );
      final options = PluginEngineOptions.parse([
        '--plugin',
        '--engine-version',
        '1.4.0',
        '--state-directory',
        state,
      ]);
      expect(options.engineVersion, '1.4.0');
      for (final bad in <List<String>>[
        ['--engine-version', '1.4.0', '--state-directory', state],
        ['--plugin', '--engine-version', 'dev', '--state-directory', state],
        [
          '--plugin',
          '--engine-version',
          '1.4.0',
          '--state-directory',
          'relative',
        ],
        ['--plugin', '--profile', '/p', '--engine-version', '1.4.0'],
      ]) {
        expect(
          () => PluginEngineOptions.parse(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('maps host and plugin failures onto existing stable codes', () {
      (String, bool) map(
        String code, {
        bool plugin = false,
        bool retry = false,
      }) => PluginEngine.mapFailure(
        PluginRunFailure(
          code: code,
          message: '',
          fromPlugin: plugin,
          retryable: retry,
        ),
      );
      expect(map('timeout'), (WorkerIssueCode.deadlineExceeded, true));
      expect(map('cancelled', plugin: true), (
        WorkerIssueCode.cancelled,
        false,
      ));
      expect(map('rate_limited', plugin: true), (
        WorkerIssueCode.quotaExhausted,
        true,
      ));
      expect(map('session_not_found', plugin: true), (
        WorkerIssueCode.sessionResumeFailed,
        true,
      ));
      expect(map('internal', plugin: true, retry: true), (
        WorkerIssueCode.providerFailure,
        true,
      ));
      expect(map(PluginHostFailure.protocolViolation), (
        WorkerIssueCode.providerFailure,
        false,
      ));
      expect(map(PluginHostFailure.identityMismatch), (
        WorkerIssueCode.profileIdentityMismatch,
        false,
      ));
      for (final code in [
        'cancelled',
        'timeout',
        'sign_in_required',
        'not_ready',
        'rate_limited',
        'unsupported_policy',
        'session_not_found',
        'invalid_request',
        'internal',
      ]) {
        expect(
          WorkerIssueCode.isKnown(map(code, plugin: true).$1),
          isTrue,
          reason: code,
        );
      }
    });
  });
}
