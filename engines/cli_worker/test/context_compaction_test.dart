import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

const _sessionId = '11111111-1111-4111-8111-111111111111';

/// Drives the Engine with the Claude starter Profile against a fake CLI. The
/// fake logs every invocation and answers "/compact" according to [compact]:
/// `ok` like Claude Code (no answer, same session) or `fail` with an error.
Future<_Harness> _start({
  required String compact,
  bool overflowOnPrompt = false,
}) async {
  final repository = Directory.current.parent.parent.path;
  final root = await Directory.systemTemp.createTemp('context-compaction-');
  final profile =
      jsonDecode(
            await File(
              '$repository/apps/profile_lab/assets/profiles/claude.json',
            ).readAsString(),
          )
          as Map<String, Object?>;
  final providerPath = '${root.path}/provider.dart';
  final logPath = '${root.path}/invocations.jsonl';
  await File(providerPath).writeAsString('''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln('2.1.308 (Claude Code)');
    return;
  }
  final prompt = await utf8.decodeStream(stdin);
  File('$logPath').writeAsStringSync(
    jsonEncode({'args': args, 'prompt': prompt}) + '\\n',
    mode: FileMode.append,
  );
  void emit(Object value) => stdout.writeln(jsonEncode(value));
  emit({'type': 'system', 'subtype': 'init', 'session_id': '$_sessionId'});
  if (prompt.trim() == '/compact') {
    emit({
      'type': 'result',
      'is_error': ${compact == 'fail'},
      'result': ${compact == 'fail' ? "'Conversation too long'" : "''"},
      'session_id': '$_sessionId',
    });
    exitCode = ${compact == 'fail' ? 1 : 0};
    return;
  }
  if ($overflowOnPrompt) {
    emit({
      'type': 'result',
      'is_error': true,
      'result': 'Prompt is too long',
      'session_id': '$_sessionId',
    });
    exitCode = 1;
    return;
  }
  emit({
    'type': 'result',
    'is_error': false,
    'result': 'answer',
    'session_id': '$_sessionId',
  });
}
''');
  final provider = profile['providerTool']! as Map<String, Object?>;
  provider['executableCandidates'] = ['dart'];
  (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
      <String>[];
  (provider['versionProbe']! as Map<String, Object?>)['arguments'] = [
    'run',
    providerPath,
    '--version',
  ];
  (profile['execution']! as Map<String, Object?>)['arguments'] = [
    'run',
    providerPath,
    {'sessionResumeArguments': true},
    {'autoCompactionArguments': true},
  ];
  final bytes = utf8.encode(jsonEncode(profile));
  final profileFile = File('${root.path}/profile.json');
  await profileFile.writeAsBytes(bytes);
  final state = await Directory('${root.path}/state').create();
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      '$repository/engines/cli_worker/bin/syntila_cli_worker.dart',
      '--profile',
      profileFile.path,
      '--engine-version',
      '1.0.0',
      '--state-directory',
      state.path,
    ],
    workingDirectory: repository,
    environment: {
      ...Platform.environment,
      'PATH':
          '${File(Platform.resolvedExecutable).parent.path}'
          '${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}',
    },
  );
  final lines = StreamIterator<String>(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  final harness = _Harness(process, lines, root, File(logPath));
  addTearDown(harness.close);
  process.stdin.writeln(
    InitializeRequest(
      requestId: 'compaction-init',
      workerTypeId: 'claude',
      expectedEngineVersion: '1.0.0',
      profileDefinitionId: 'claude-code',
      profileReleaseVersion: '${profile['releaseVersion']}',
      profileDigest: sha256.convert(bytes).toString(),
    ).encode(),
  );
  await process.stdin.flush();
  expect(await lines.moveNext().timeout(const Duration(seconds: 10)), isTrue);
  expect(decodeWorkerFrame(lines.current), isA<InitializeResult>());
  return harness;
}

class _Harness {
  _Harness(this.process, this.lines, this.root, this.log);

  final Process process;
  final StreamIterator<String> lines;
  final Directory root;
  final File log;
  var _sequence = 0;

  Future<WorkerFrame> execute({bool compactContext = false}) async {
    _sequence += 1;
    process.stdin.writeln(
      ExecuteRequest(
        requestId: 'execute-$_sequence',
        assignmentId: 'assignment-$_sequence',
        prompt: 'Continue',
        timeoutMs: 20000,
        sessionPolicy: WorkerSessionPolicy.durableSession,
        sessionKey: 'thread-session',
        compactContext: compactContext,
      ).encode(),
    );
    await process.stdin.flush();
    while (await lines.moveNext().timeout(const Duration(seconds: 30))) {
      final frame = decodeWorkerFrame(lines.current);
      if (frame is WorkerErrorFrame || frame is WorkerResult) return frame;
    }
    throw StateError('Engine closed without a terminal frame');
  }

  Future<List<Map<String, Object?>>> invocations() async => [
    for (final line in await log.readAsLines())
      jsonDecode(line) as Map<String, Object?>,
  ];

  Future<void> close() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await lines.cancel();
    await root.delete(recursive: true);
  }
}

void main() {
  test('a Profile overflow marker fails with context_limit_exceeded', () async {
    final harness = await _start(compact: 'ok', overflowOnPrompt: true);
    final terminal = await harness.execute();
    expect(terminal, isA<WorkerErrorFrame>());
    expect(
      (terminal as WorkerErrorFrame).code,
      WorkerIssueCode.contextLimitExceeded,
    );
  });

  test('every run keeps the CLI auto-compaction on', () async {
    final harness = await _start(compact: 'ok');
    expect(await harness.execute(), isA<WorkerResult>());
    final args = (await harness.invocations()).single['args'] as List;
    expect(args, containsAllInOrder(['--autocompact', 'auto']));
  });

  test(
    'compactContext compacts the resumed session, then runs the prompt',
    () async {
      final harness = await _start(compact: 'ok');
      expect(await harness.execute(), isA<WorkerResult>());
      final terminal = await harness.execute(compactContext: true);
      expect(terminal, isA<WorkerResult>());
      final calls = (await harness.invocations()).skip(1).toList();
      expect(calls.map((call) => (call['prompt'] as String).trim()), [
        '/compact',
        'Continue',
      ]);
      for (final call in calls) {
        expect(call['args'], containsAllInOrder(['--resume', _sessionId]));
      }
    },
  );

  test('a failed compaction stops before the prompt', () async {
    final harness = await _start(compact: 'fail');
    expect(await harness.execute(), isA<WorkerResult>());
    final terminal = await harness.execute(compactContext: true);
    expect(terminal, isA<WorkerErrorFrame>());
    terminal as WorkerErrorFrame;
    expect(terminal.code, WorkerIssueCode.contextLimitExceeded);
    expect(terminal.message, contains('could not compact'));
    final prompts = (await harness.invocations())
        .skip(1)
        .map((call) => (call['prompt'] as String).trim());
    expect(prompts, ['/compact']);
  });
}
