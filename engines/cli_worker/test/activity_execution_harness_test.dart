import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// End-to-end harness for the generic Engine boundary. The provider is a
/// fixture CLI, but the test exercises the real Engine process, Profile
/// interpreter, JSONL stream, activity frames and terminal reconciliation.
final class _FixtureEngine {
  _FixtureEngine._({
    required this.root,
    required this.process,
    required this.lines,
    required this.stderr,
  });

  final Directory root;
  final Process process;
  final StreamIterator<String> lines;
  final StringBuffer stderr;

  static Future<_FixtureEngine> start(String repository) async {
    final root = await Directory.systemTemp.createTemp('syntila-activity-e2e-');
    final profile =
        jsonDecode(
              await File(
                '$repository/packages/tool-profile/test/fixtures/chatgpt-codex.v1.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    final provider = profile['providerTool']! as Map<String, Object?>;
    provider['executableCandidates'] = ['dart'];
    (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
        <String>[];
    (provider['versionProbe']! as Map<String, Object?>)['arguments'] = [
      'run',
      '$repository/packages/tool-profile/test/fixtures/provider-cli/activity_profile_provider.dart',
      '--version',
    ];
    provider['supportedVersions'] = [
      {'min': '0.0.0', 'maxExclusive': '2.0.0'},
    ];
    final execution = profile['execution']! as Map<String, Object?>;
    execution['arguments'] = <Object?>[
      'run',
      '$repository/packages/tool-profile/test/fixtures/provider-cli/activity_profile_provider.dart',
    ];
    execution['output'] = {'mode': 'jsonl'};
    final environment = profile['environment']! as Map<String, Object?>;
    (environment['set']! as Map<String, Object?>)['PATH'] =
        '${File(Platform.resolvedExecutable).parent.path}'
        '${Platform.isWindows ? ';' : ':'}'
        '${Platform.environment['PATH'] ?? ''}';
    final profileBytes = utf8.encode(jsonEncode(profile));
    final profileFile = File('${root.path}/profile.json')
      ..writeAsBytesSync(profileBytes);
    final state = await Directory('${root.path}/state').create();
    final dartBin = File(Platform.resolvedExecutable).parent.path;
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
            '$dartBin${Platform.isWindows ? ';' : ':'}'
            '${Platform.environment['PATH'] ?? ''}',
        'OPENAI_API_KEY': 'fixture-key',
      },
      runInShell: false,
    );
    final lines = StreamIterator<String>(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final stderr = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    final harness = _FixtureEngine._(
      root: root,
      process: process,
      lines: lines,
      stderr: stderr,
    );
    final initialized = await harness.exchange(
      InitializeRequest(
        requestId: 'fixture-init',
        workerTypeId: 'chatgpt',
        expectedEngineVersion: '1.0.0',
        profileDefinitionId: 'chatgpt-codex',
        profileReleaseVersion: '1',
        profileDigest: sha256.convert(profileBytes).toString(),
      ),
    );
    expect(initialized.terminal, isA<InitializeResult>());
    return harness;
  }

  Future<({WorkerFrame terminal, List<WorkerActivity> activities})> execute(
    String requestId,
    String scenario,
  ) async {
    final result = await exchange(
      ExecuteRequest(
        requestId: requestId,
        assignmentId: 'assignment-$requestId',
        prompt: scenario,
        timeoutMs: 30_000,
        sessionPolicy: WorkerSessionPolicy.stateless,
      ),
    );
    return result;
  }

  Future<({WorkerFrame terminal, List<WorkerActivity> activities})> exchange(
    WorkerFrame request,
  ) async {
    process.stdin.writeln(request.encode());
    await process.stdin.flush();
    final activities = <WorkerActivity>[];
    try {
      while (await lines.moveNext().timeout(const Duration(seconds: 20))) {
        final frame = decodeWorkerFrame(lines.current);
        if (frame.requestId != request.requestId) continue;
        if (frame is WorkerActivity) {
          activities.add(frame);
          continue;
        }
        if (frame is WorkerResult ||
            frame is WorkerErrorFrame ||
            frame is InitializeResult ||
            frame is ProbeResult) {
          return (terminal: frame, activities: activities);
        }
      }
    } on TimeoutException {
      throw StateError('Fixture Engine timed out: ${stderr.toString()}');
    }
    throw StateError('Fixture Engine closed before terminal frame');
  }

  Future<void> close() async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(const Duration(seconds: 10));
    await lines.cancel();
    await root.delete(recursive: true);
  }
}

void main() {
  final repository = Directory.current.parent.parent.path;

  test(
    'fixture CLI covers high-frequency, delayed, large and failed outcomes',
    () async {
      final harness = await _FixtureEngine.start(repository);
      addTearDown(harness.close);

      final frequent = await harness.execute(
        'high-frequency',
        'high-frequency',
      );
      expect(
        frequent.terminal,
        isA<WorkerResult>(),
        reason: '${frequent.terminal.toJson()}',
      );
      expect(frequent.activities.length, greaterThan(1000));
      final milestones = frequent.activities.where(
        (item) => item.details?['source'] == 'profile.milestone',
      );
      expect(milestones, isNotEmpty);
      expect(
        milestones.map((item) => item.title),
        everyElement(isNot(startsWith('provider_'))),
      );
      final sequences = frequent.activities
          .map((item) => item.sequence)
          .toList();
      var previousSequence = 0;
      final strictlyIncreasing = sequences.every((value) {
        final valid = value > previousSequence;
        previousSequence = value;
        return valid;
      });
      expect(strictlyIncreasing, isTrue);
      expect(frequent.activities.last.eventType, 'execution.completed');

      final delayed = await harness.execute('delayed', 'delayed');
      expect(
        delayed.terminal,
        isA<WorkerResult>(),
        reason: '${delayed.terminal.toJson()}',
      );
      expect(
        delayed.activities.any((item) => item.activityId == 'delayed-tool'),
        isTrue,
      );

      final large = await harness.execute('large', 'large');
      expect(
        large.terminal,
        isA<WorkerResult>(),
        reason: '${large.terminal.toJson()}',
      );
      expect(
        (large.terminal as WorkerResult).output.length,
        greaterThan(100 * 1024),
      );

      final failed = await harness.execute('failed', 'fail');
      expect(failed.terminal, isA<WorkerErrorFrame>());
      expect(
        (failed.terminal as WorkerErrorFrame).code,
        WorkerIssueCode.providerFailure,
      );
      expect(failed.activities.last.eventType, 'execution.failed');

      final missingTerminal = await harness.execute(
        'missing-terminal',
        'no-terminal',
      );
      expect(missingTerminal.terminal, isA<WorkerErrorFrame>());
      expect(harness.stderr.toString(), contains('missing_terminal_event'));
    },
  );

  test('two fixture Workers execute concurrently without cross-talk', () async {
    final first = await _FixtureEngine.start(repository);
    final second = await _FixtureEngine.start(repository);
    addTearDown(() async {
      await first.close();
      await second.close();
    });

    final results = await Future.wait([
      first.execute('concurrent-a', 'delayed'),
      second.execute('concurrent-b', 'high-frequency'),
    ]);
    expect(
      results[0].terminal,
      isA<WorkerResult>(),
      reason: '${results[0].terminal.toJson()}',
    );
    expect(
      results[1].terminal,
      isA<WorkerResult>(),
      reason: '${results[1].terminal.toJson()}',
    );
    expect(
      results[0].activities.every((item) => item.requestId == 'concurrent-a'),
      isTrue,
    );
    expect(
      results[1].activities.every((item) => item.requestId == 'concurrent-b'),
      isTrue,
    );
  });
}
