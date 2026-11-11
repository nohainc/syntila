@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/external_worker_conversation.dart';
import 'package:syntila_cli_worker_engine/src/external_worker_process_host.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

import 'support/external_worker_test_binaries.dart';

const workerPath = '../../examples/mcp/echo_worker/echo_worker.dart';

late Directory root;
late String dartDigest;
late String engineBinary;

Map<String, String> pins() => {
  for (final name in ['syntila.execute', 'syntila.probe'])
    name: toolDefinitionHash({
      'name': name,
      'description': 'Syntila Worker tool $name',
      'inputSchema': {'type': 'object'},
    }),
};

WorkerExecutor executor({
  Map<String, String>? toolPins,
  String mode = 'normal',
}) => WorkerExecutor(
  pluginId: 'echo-worker',
  version: '1.0.0',
  manifestDigest: 'a' * 64,
  artifactSha256: dartDigest,
  executable: Platform.resolvedExecutable,
  dataDirectory: root.path,
  arguments: [File(workerPath).absolute.path, mode],
  protocol: 'mcp',
  toolPins: toolPins ?? pins(),
);

class EngineProcess {
  EngineProcess._(this.process, this.frames);
  final Process process;
  final StreamIterator<WorkerFrame> frames;

  static Future<EngineProcess> start() async {
    final state = Directory.systemTemp.createTempSync('mcp-engine-state');
    final process = await Process.start(engineBinary, [
      '--plugin',
      '--engine-version',
      '1.4.0',
      '--state-directory',
      state.path,
    ], workingDirectory: root.path);
    final frames = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(decodeWorkerFrame);
    return EngineProcess._(process, StreamIterator(frames));
  }

  void send(WorkerFrame frame) => process.stdin.writeln(frame.encode());

  Future<WorkerFrame> next() async {
    expect(
      await frames.moveNext().timeout(const Duration(seconds: 60)),
      isTrue,
    );
    return frames.current;
  }

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
    await process.exitCode.timeout(const Duration(seconds: 20));
  }
}

InitializeRequest initialize(WorkerExecutor e) => InitializeRequest(
  requestId: 'init-1',
  workerTypeId: 'plugin-3fa91c04b2d7',
  expectedEngineVersion: '1.4.0',
  profileDefinitionId: 'plugin-echo-worker',
  profileReleaseVersion: '1.0.0',
  profileDigest: e.manifestDigest,
  executor: e,
  protocolVersion: mcpExecutorProtocolVersion,
);

ExecuteRequest execute(WorkerExecutor e, {String prompt = 'hi'}) =>
    ExecuteRequest(
      requestId: 'req-1',
      assignmentId: 'asg-1',
      prompt: prompt,
      timeoutMs: 30000,
      sessionPolicy: WorkerSessionPolicy.stateless,
      executionPolicy: WorkerExecutionPolicy.restricted,
      executor: e,
      protocolVersion: mcpExecutorProtocolVersion,
    );

void main() {
  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('mcp-executor');
    dartDigest = await ExternalWorkerProcessHost().sha256OfFile(
      Platform.resolvedExecutable,
    );
    engineBinary = (await ExternalWorkerTestBinaries.ensure()).engine;
  });
  tearDownAll(() => root.deleteSync(recursive: true));

  test('an MCP executor needs protocol 4.3 on every frame that carries it', () {
    final e = executor();
    expect(
      () => ExecuteRequest(
        requestId: 'r',
        assignmentId: 'a',
        prompt: 'x',
        timeoutMs: 1000,
        sessionPolicy: WorkerSessionPolicy.stateless,
        executor: e,
        protocolVersion: pluginExecutorProtocolVersion,
      ),
      throwsFormatException,
    );
    expect(
      () => InitializeRequest(
        requestId: 'i',
        workerTypeId: 'plugin-3fa91c04b2d7',
        expectedEngineVersion: '1.4.0',
        profileDefinitionId: 'plugin-echo-worker',
        profileReleaseVersion: '1.0.0',
        profileDigest: e.manifestDigest,
        executor: e,
        protocolVersion: pluginExecutorProtocolVersion,
      ),
      throwsFormatException,
    );
  });

  test(
    'runs an assignment on an MCP Worker through the plugin-mode Engine',
    () async {
      final engine = await EngineProcess.start();
      addTearDown(engine.close);
      final e = executor();
      engine.send(initialize(e));
      expect(await engine.next(), isA<InitializeResult>());
      engine.send(execute(e, prompt: 'hello'));
      final frames = await engine.untilTerminal();
      final last = frames.last;
      expect(
        last,
        isA<WorkerResult>(),
        reason: last is WorkerErrorFrame
            ? '${last.code}: ${last.message} / ${last.diagnostics}'
            : null,
      );
      final result = last as WorkerResult;
      expect(result.output, startsWith('echo: hello'));
      final messages = [
        for (final f in frames.whereType<WorkerProgress>()) f.message,
      ];
      expect(messages, contains('working'));
    },
  );

  test('a probe publishes the models an MCP Worker discovers', () async {
    final engine = await EngineProcess.start();
    addTearDown(engine.close);
    final e = executor(
      mode: 'models',
      toolPins: {
        ...pins(),
        'syntila.models': toolDefinitionHash({
          'name': 'syntila.models',
          'description': 'Syntila Worker tool syntila.models',
          'inputSchema': {'type': 'object'},
        }),
      },
    );
    engine.send(initialize(e));
    expect(await engine.next(), isA<InitializeResult>());
    engine.send(ProbeRequest(requestId: 'probe-1', mode: WorkerProbeMode.live));
    final result = await engine.next();
    expect(result, isA<ProbeResult>(), reason: '${result.toJson()}');
    final probe = result as ProbeResult;
    expect(probe.ready, isTrue, reason: '${probe.toJson()}');
    final catalog = probe.modelCatalog!;
    expect(catalog.profileDigest, e.manifestDigest);
    expect(catalog.providerToolVersion, e.version);
    expect(
      [for (final m in catalog.models) m.id],
      ['echo-small', 'echo-large'],
    );
  });

  test(
    'a read-only request sends the conversation as turns and says so',
    () async {
      final engine = await EngineProcess.start();
      addTearDown(engine.close);
      final e = executor();
      engine.send(initialize(e));
      expect(await engine.next(), isA<InitializeResult>());
      engine.send(
        ExecuteRequest(
          requestId: 'req-1',
          assignmentId: 'asg-1',
          prompt: 'REPORT_CONVERSATION and you?',
          timeoutMs: 30000,
          sessionPolicy: WorkerSessionPolicy.stateless,
          executionPolicy: WorkerExecutionPolicy.providerDefault,
          statelessContext: ConversationBootstrap(
            conversationId: 'conversation-1',
            contextRevision: 2,
            throughSequence: 9,
            text: jsonEncode({
              'conversationId': 'conversation-1',
              'throughSequence': 9,
              'history': [
                {'sequence': 1, 'kind': 'workflow_event', 'text': null},
                {'sequence': 2, 'kind': 'user_message', 'text': 'hi'},
                {'sequence': 5, 'kind': 'worker_response', 'text': 'Hello!'},
              ],
              'workflowExecutionContext': {'status': 'running'},
            }),
          ),
          executor: e,
          protocolVersion: mcpExecutorProtocolVersion,
        ),
      );
      final last = (await engine.untilTerminal()).last;
      expect(
        last,
        isA<WorkerResult>(),
        reason: last is WorkerErrorFrame ? '${last.code}: ${last.message}' : '',
      );
      final output = (last as WorkerResult).output;
      expect(output, startsWith('conversation: '));
      expect(jsonDecode(output.substring('conversation: '.length)), {
        'messages': [
          {'role': 'user', 'text': 'hi'},
          {'role': 'assistant', 'text': 'Hello!'},
        ],
        'request': 'REPORT_CONVERSATION and you?',
        'instructions': [externalWorkerReadOnlyInstruction],
      });
    },
  );

  test(
    'a tool whose definition differs from the consented pin is refused',
    () async {
      final engine = await EngineProcess.start();
      addTearDown(engine.close);
      final stale = pins()..['syntila.execute'] = 'f' * 64;
      final e = executor(toolPins: stale);
      engine.send(initialize(e));
      expect(await engine.next(), isA<InitializeResult>());
      engine.send(execute(e));
      final error = (await engine.untilTerminal()).last as WorkerErrorFrame;
      expect(
        error.code,
        WorkerIssueCode.profileIdentityMismatch,
        reason: '${error.message} / ${error.diagnostics}',
      );
    },
  );

  test('a local MCP Worker receives the admitted working directory', () async {
    final engine = await EngineProcess.start();
    addTearDown(engine.close);
    final e = executor();
    engine.send(initialize(e));
    expect(await engine.next(), isA<InitializeResult>());
    engine.send(execute(e, prompt: 'REPORT_WORKING_DIRECTORY'));
    final result = (await engine.untilTerminal()).last as WorkerResult;
    expect(
      result.output,
      'workingDirectory: ${root.resolveSymbolicLinksSync()}',
    );
  });

  test('a worker error keeps its stable mapping', () async {
    final engine = await EngineProcess.start();
    addTearDown(engine.close);
    final e = executor();
    engine.send(initialize(e));
    expect(await engine.next(), isA<InitializeResult>());
    engine.send(execute(e, prompt: 'FAIL'));
    final error = (await engine.untilTerminal()).last as WorkerErrorFrame;
    expect(
      error.code,
      WorkerIssueCode.quotaExhausted,
      reason: '${error.message} / ${error.diagnostics}',
    );
    expect(error.retryable, isTrue);
  });

  test(
    'NDJSON executors and frames are unchanged (no protocol/toolPins keys)',
    () {
      final ndjson = WorkerExecutor(
        pluginId: 'fixture-plugin',
        version: '1.0.0',
        manifestDigest: 'a' * 64,
        artifactSha256: 'b' * 64,
        executable: '/bin/x',
        dataDirectory: '/tmp',
      );
      expect(ndjson.toJson().containsKey('protocol'), isFalse);
      expect(ndjson.toJson().containsKey('toolPins'), isFalse);
      expect(WorkerExecutor.fromJson(ndjson.toJson()).isMcp, isFalse);
      expect(
        () => WorkerExecutor(
          pluginId: 'fixture-plugin',
          version: '1.0.0',
          manifestDigest: 'a' * 64,
          artifactSha256: 'b' * 64,
          executable: '/bin/x',
          dataDirectory: '/tmp',
          toolPins: {'t': 'c' * 64},
        ),
        throwsFormatException,
      );
    },
  );
}
