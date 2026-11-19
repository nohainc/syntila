import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('maps malformed provider JSONL to a safe provider failure', () async {
    final repository = Directory.current.parent.parent.path;
    final profile =
        jsonDecode(
              await File(
                '$repository/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    ((profile['execution'] as Map<String, Object?>)['output']
            as Map<String, Object?>)['mode'] =
        'jsonl';
    final profileBytes = utf8.encode(jsonEncode(profile));
    final root = await Directory.systemTemp.createTemp(
      'syntila-malformed-jsonl-',
    );
    final profileFile = File('${root.path}/profile.json')
      ..writeAsBytesSync(profileBytes);
    final stateDirectory = await Directory('${root.path}/state').create();
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '$repository/engines/cli_worker/bin/syntila_cli_worker.dart',
        '--profile',
        profileFile.path,
        '--engine-version',
        '1.0.0',
        '--state-directory',
        stateDirectory.path,
      ],
      workingDirectory: repository,
      environment: {
        ...Platform.environment,
        'PATH':
            '${File(Platform.resolvedExecutable).parent.path}:${Platform.environment['PATH'] ?? ''}',
      },
      runInShell: false,
    );
    final lines = StreamIterator<String>(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    addTearDown(() async {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await lines.cancel();
      await root.delete(recursive: true);
    });

    process.stdin.writeln(
      InitializeRequest(
        requestId: 'malformed-init',
        workerTypeId: 'fixture-worker',
        expectedEngineVersion: '1.0.0',
        profileDefinitionId: 'fixture-cli',
        profileReleaseVersion: '1',
        profileDigest: _sha256(profileBytes),
      ).encode(),
    );
    await process.stdin.flush();
    expect(await lines.moveNext().timeout(const Duration(seconds: 10)), isTrue);
    expect(decodeWorkerFrame(lines.current), isA<InitializeResult>());

    process.stdin.writeln(
      ExecuteRequest(
        requestId: 'malformed-execute',
        assignmentId: 'fixture-assignment',
        prompt: 'plain text is not JSONL',
        timeoutMs: 10000,
        sessionPolicy: WorkerSessionPolicy.stateless,
      ).encode(),
    );
    await process.stdin.flush();
    final failure = await _nextTerminalFrame(lines) as WorkerErrorFrame;
    expect(failure.code, WorkerIssueCode.providerFailure);
  });

  test(
    'third testing CLI integrates through a Tool Profile and generic Engine',
    () async {
      final repository = Directory.current.parent.parent.path;
      final profilePath =
          '$repository/packages/tool-profile/test/fixtures/fixture-cli.v1.json';
      final enginePath =
          '$repository/engines/cli_worker/bin/syntila_cli_worker.dart';
      final profileBytes = await File(profilePath).readAsBytes();
      final stateDirectory = await Directory.systemTemp.createTemp(
        'syntila-engine-state-',
      );
      final providerDirectory = Directory('${stateDirectory.path}/provider-bin')
        ..createSync();
      final providerExecutable = File(
        '${providerDirectory.path}/fixture-provider'
        '${Platform.isWindows ? '.exe' : ''}',
      );
      final providerBuild = await Process.run(
        Platform.resolvedExecutable,
        [
          'compile',
          'exe',
          '$repository/packages/tool-profile/test/fixtures/fixture_provider.dart',
          '-o',
          providerExecutable.path,
        ],
        workingDirectory: repository,
        runInShell: false,
      );
      expect(providerBuild.exitCode, 0, reason: '${providerBuild.stderr}');
      final profileJson =
          jsonDecode(utf8.decode(profileBytes)) as Map<String, Object?>;
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          enginePath,
          '--profile',
          profilePath,
          '--engine-version',
          '1.0.0',
          '--state-directory',
          stateDirectory.path,
        ],
        workingDirectory: repository,
        environment: {
          ...Platform.environment,
          'PATH':
              '${providerDirectory.path}${Platform.isWindows ? ';' : ':'}'
              '${Platform.environment['PATH'] ?? ''}',
        },
        runInShell: false,
      );
      final lines = StreamIterator<String>(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await lines.cancel();
        await stateDirectory.delete(recursive: true);
      });

      final initialize = InitializeRequest(
        requestId: 'engine-init-1',
        workerTypeId: profileJson['logicalWorkerTypeId']! as String,
        expectedEngineVersion: '1.0.0',
        profileDefinitionId: profileJson['profileDefinitionId']! as String,
        // The resolved publication revision is independent of the legacy
        // releaseVersion field inside the behavior JSON.
        profileReleaseVersion: '7',
        profileDigest: _sha256(profileBytes),
      );
      process.stdin.writeln(initialize.encode());
      await process.stdin.flush();
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      final initialized = decodeWorkerFrame(lines.current);
      expect(initialized, isA<InitializeResult>());
      expect(
        (initialized as InitializeResult).profileDefinitionId,
        'fixture-cli',
      );
      expect(initialized.capabilities, contains(providerTimingCapability));
      expect(initialized.workerTypeId, 'fixture-worker');
      expect(initialized.profileRevision, '7');

      process.stdin.writeln(
        ProbeRequest(
          requestId: 'engine-probe-1',
          mode: WorkerProbeMode.passive,
        ).encode(),
      );
      await process.stdin.flush();
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 20)),
        isTrue,
      );
      final probe = decodeWorkerFrame(lines.current) as ProbeResult;
      expect(probe.ready, isTrue, reason: '${probe.toJson()}');
      expect(probe.providerToolName, 'Fixture CLI');
      expect(probe.providerToolVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));

      process.stdin.writeln(
        ProbeRequest(
          requestId: 'engine-live-probe-1',
          mode: WorkerProbeMode.live,
          timeoutMs: 30000,
        ).encode(),
      );
      await process.stdin.flush();
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 35)),
        isTrue,
      );
      final liveProbe = decodeWorkerFrame(lines.current) as ProbeResult;
      expect(liveProbe.ready, isTrue, reason: '${liveProbe.toJson()}');
      expect(
        liveProbe.checks
            .singleWhere((check) => check.code == 'provider_live_execution')
            .status,
        ProbeCheckStatus.passed,
      );

      process.stdin.writeln(
        ExecuteRequest(
          requestId: 'engine-execute-1',
          providerTiming: true,
          assignmentId: 'fixture-assignment',
          prompt: 'hello engine',
          timeoutMs: 60000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ).encode(),
      );
      await process.stdin.flush();
      var providerStartObserved = false;
      final lifecycleMarkers = <String>[];
      final result =
          await _nextTerminalFrame(
                lines,
                onProgress: (progress) {
                  providerStartObserved |=
                      progress.message == workerProviderExecutionStartedMessage;
                  if (progress.message != null)
                    lifecycleMarkers.add(progress.message!);
                },
              )
              as WorkerResult;
      expect(providerStartObserved, isTrue);
      expect(lifecycleMarkers, contains(workerProviderFirstOutputMessage));
      expect(lifecycleMarkers, contains(workerProviderProcessExitedMessage));
      expect(
        lifecycleMarkers.any(
          (m) => m.startsWith(workerProviderLastOutputAgePrefix),
        ),
        isTrue,
      );
      expect(result.output, 'fixture echo: hello engine');

      final marker = '${stateDirectory.path}/shell-injection-marker';
      final hostilePrompt = "'; touch $marker; #";
      process.stdin.writeln(
        ExecuteRequest(
          requestId: 'engine-shell-injection',
          assignmentId: 'fixture-assignment',
          prompt: hostilePrompt,
          timeoutMs: 60000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ).encode(),
      );
      await process.stdin.flush();
      final legacyMarkers = <String>[];
      final hostileResult =
          await _nextTerminalFrame(
                lines,
                onProgress: (progress) {
                  if (progress.message != null)
                    legacyMarkers.add(progress.message!);
                },
              )
              as WorkerResult;
      expect(legacyMarkers, isNot(contains(workerProviderFirstOutputMessage)));
      expect(
        legacyMarkers,
        isNot(contains(workerProviderProcessExitedMessage)),
      );
      expect(
        legacyMarkers.any(
          (m) => m.startsWith(workerProviderLastOutputAgePrefix),
        ),
        isFalse,
      );
      expect(hostileResult.output, 'fixture echo: $hostilePrompt');
      expect(File(marker).existsSync(), isFalse);
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
    },
  );
}

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

Future<WorkerFrame> _nextTerminalFrame(
  StreamIterator<String> lines, {
  void Function(WorkerProgress progress)? onProgress,
}) async {
  while (await lines.moveNext().timeout(const Duration(seconds: 60))) {
    final frame = decodeWorkerFrame(lines.current);
    if (frame is WorkerProgress) {
      onProgress?.call(frame);
      continue;
    }
    if (frame is WorkerActivity) {
      continue;
    }
    return frame;
  }
  throw StateError('CLI Worker Engine closed before a terminal frame');
}
