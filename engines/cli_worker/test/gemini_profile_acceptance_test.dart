@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test(
    'gemini-antigravity Profile reproduces the current Worker acceptance path',
    () async {
      final repository = Directory.current.parent.parent.path;
      final profile =
          jsonDecode(
                await File(
                  '$repository/packages/tool-profile/test/fixtures/gemini-antigravity.v1.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final provider = profile['providerTool']! as Map<String, Object?>;
      final providerScript =
          '$repository/packages/tool-profile/test/fixtures/provider-cli/antigravity_profile_provider.dart';
      provider['executableCandidates'] = ['dart'];
      (provider['discovery']! as Map<String, Object?>)['standardLocations'] =
          <String>[];
      (provider['versionProbe']! as Map<String, Object?>)['arguments'] = [
        'run',
        providerScript,
        '--version',
      ];
      provider['supportedVersions'] = [
        {'min': '0.0.0', 'maxExclusive': '2.0.0'},
      ];
      ((profile['model']! as Map<String, Object?>)['discovery']!
          as Map<String, Object?>)['arguments'] = [
        'run',
        providerScript,
        'models',
      ];
      final execution = profile['execution']! as Map<String, Object?>;
      execution['failureExtraction'] = {
        'nativeErrorCode': r'$.result.code',
        'providerErrorText': r'$.result.error',
        'failedRunResponse': r'$.result.response',
        'source': 'structured_error',
      };
      execution['arguments'] = [
        'run',
        providerScript,
        ...(execution['arguments']! as List<Object?>),
      ];

      profile['usage'] = {
        'arguments': ['run', providerScript, 'usage'],
        'timeoutMs': 60000,
      };
      final profileBytes = utf8.encode(jsonEncode(profile));
      final root = await Directory.systemTemp.createTemp('gemini-profile-');
      final profileFile = File('${root.path}/profile.json')
        ..writeAsBytesSync(profileBytes);
      final stateDirectory = await Directory('${root.path}/state').create();
      final providerHome = await Directory(
        '${root.path}/provider-home',
      ).create();
      final environment = <String, String>{
        ...Platform.environment,
        'PATH':
            '${File(Platform.resolvedExecutable).parent.path}${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}',
        'HOME': providerHome.path,
        'USERPROFILE': providerHome.path,
        'ProgramFiles': root.path,
        'TMP': root.path,
        'TEMP': root.path,
        'TMPDIR': root.path,
        'LANG': 'en_US.UTF-8',
        'LC_ALL': 'en_US.UTF-8',
        'SSL_CERT_FILE': '${root.path}/ca.pem',
        'SSL_CERT_DIR': '${root.path}/certs',
        'AGY_ADC_AUTH': 'agy-fixture-adc',
        'GEMINI_API_KEY': 'gemini-fixture-key',
        'GOOGLE_API_KEY': 'google-fixture-key',
        'GOOGLE_APPLICATION_CREDENTIALS': '/fixture/credentials.json',
        'GOOGLE_CLOUD_PROJECT': 'fixture-project',
        'GOOGLE_CLOUD_LOCATION': 'fixture-region',
        'GOOGLE_GEMINI_BASE_URL': 'https://fixture.invalid',
      };
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          '$repository/engines/cli_worker/bin/syntila_cli_worker.dart',
          '--profile',
          profileFile.path,
          '--engine-version',
          '1.2.0',
          '--state-directory',
          stateDirectory.path,
        ],
        workingDirectory: repository,
        environment: environment,
        runInShell: false,
      );
      final lines = StreamIterator<String>(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final engineStderr = StringBuffer();
      final stderrTask = process.stderr
          .transform(utf8.decoder)
          .listen(engineStderr.write);
      final allProgress = <WorkerProgress>[];
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await lines.cancel();
        await stderrTask.cancel();
        await root.delete(recursive: true);
      });

      Future<
        ({
          WorkerFrame terminal,
          List<WorkerProgress> progress,
          List<WorkerActivity> activities,
        })
      >
      exchange(WorkerFrame request) async {
        process.stdin.writeln(request.encode());
        await process.stdin.flush();
        final observedProgress = <WorkerProgress>[];
        final observedActivities = <WorkerActivity>[];
        while (await lines.moveNext().timeout(const Duration(seconds: 60))) {
          final frame = decodeWorkerFrame(lines.current);
          if (frame is WorkerProgress && frame.requestId == request.requestId) {
            observedProgress.add(frame);
            allProgress.add(frame);
            continue;
          }
          if (frame is WorkerActivity && frame.requestId == request.requestId) {
            observedActivities.add(frame);
            continue;
          }
          if (frame.requestId != request.requestId) continue;
          if (frame is WorkerResult ||
              frame is WorkerErrorFrame ||
              frame is ProbeResult ||
              frame is InitializeResult) {
            return (
              terminal: frame,
              progress: observedProgress,
              activities: observedActivities,
            );
          }
        }
        throw TimeoutException('Engine did not return ${request.requestId}');
      }

      final initialized = await exchange(
        InitializeRequest(
          requestId: 'gemini-profile-init',
          workerTypeId: 'gemini',
          expectedEngineVersion: '1.2.0',
          profileDefinitionId: 'gemini-antigravity',
          profileReleaseVersion: '1',
          profileDigest: sha256.convert(profileBytes).toString(),
          protocolVersion: providerFailureDetailsProtocolVersion,
        ),
      );
      expect(initialized.terminal, isA<InitializeResult>());
      final initializeResult = initialized.terminal as InitializeResult;
      expect(initializeResult.workerTypeId, 'gemini');
      expect(initializeResult.profileDefinitionId, 'gemini-antigravity');
      expect(initializeResult.profileReleaseVersion, '1');

      final failed = await exchange(
        ExecuteRequest(
          requestId: 'failure-with-response',
          assignmentId: 'failure-assignment',
          prompt: 'Failure with response',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.stateless,
          protocolVersion: providerFailureDetailsProtocolVersion,
        ),
      );
      final failure = failed.terminal as WorkerErrorFrame;
      expect(
        failure.providerFailure,
        containsPair('nativeErrorCode', 'OUTPUT_LIMIT'),
      );
      expect(
        failure.providerFailure,
        containsPair('providerErrorText', 'Output limit reached'),
      );
      expect(
        failure.providerFailure,
        containsPair('failedRunResponse', 'Partial answer'),
      );

      // A missing local settings file warns but does not block readiness.
      final missingConfig = await exchange(
        ProbeRequest(
          requestId: 'gemini-profile-passive-missing-config',
          mode: WorkerProbeMode.passive,
        ),
      );
      final missingResult = missingConfig.terminal as ProbeResult;
      expect(missingResult.ready, isTrue, reason: '${missingResult.toJson()}');
      expect(missingResult.providerToolVersion, '1.2.3');
      expect(
        missingResult.checks.any(
          (check) =>
              check.code == 'gemini_provider_config' &&
              check.status == ProbeCheckStatus.warning,
        ),
        isTrue,
        reason: '${missingResult.toJson()}',
      );

      final settings = File(
        '${providerHome.path}/.gemini/antigravity-cli/settings.json',
      );
      await settings.parent.create(recursive: true);
      await settings.writeAsString('{}');
      final emptyConfig = await exchange(
        ProbeRequest(
          requestId: 'gemini-profile-passive-empty-config',
          mode: WorkerProbeMode.passive,
        ),
      );
      expect((emptyConfig.terminal as ProbeResult).ready, isTrue);

      await settings.writeAsString('{"modelProvider":"unsupported"}');
      final unsupportedProvider = await exchange(
        ProbeRequest(
          requestId: 'gemini-profile-passive-unsupported-config',
          mode: WorkerProbeMode.passive,
        ),
      );
      final unsupportedResult = unsupportedProvider.terminal as ProbeResult;
      expect(unsupportedResult.ready, isFalse);
      expect(unsupportedResult.issueCode, WorkerIssueCode.providerFailure);

      await settings.writeAsString('{"modelProvider":"gemini"}');
      final configuredProvider = await exchange(
        ProbeRequest(
          requestId: 'gemini-profile-passive-gemini-config',
          mode: WorkerProbeMode.passive,
        ),
      );
      expect((configuredProvider.terminal as ProbeResult).ready, isTrue);
      await settings.writeAsString('{}');

      final liveProbe = await exchange(
        ProbeRequest(
          requestId: 'gemini-profile-live',
          mode: WorkerProbeMode.live,
          timeoutMs: 30000,
        ),
      );
      final liveResult = liveProbe.terminal as ProbeResult;
      expect(liveResult.ready, isTrue, reason: '${liveResult.toJson()}');
      expect(
        liveResult.checks
            .singleWhere((check) => check.code == 'provider_live_execution')
            .status,
        ProbeCheckStatus.passed,
      );

      final stateless = await exchange(
        ExecuteRequest(
          requestId: 'gemini-profile-stateless',
          assignmentId: 'gemini-stateless',
          prompt: 'Say OK',
          model: 'gemini-3.8-flash',
          reasoningEffort: 'high',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ),
      );
      expect(
        stateless.terminal,
        isA<WorkerResult>(),
        reason: '${stateless.terminal.toJson()} stderr=$engineStderr',
      );
      expect((stateless.terminal as WorkerResult).output, 'Gemini answer');
      expect(
        stateless.activities
            .where((item) => item.eventType == 'message.updated')
            .map((item) => item.percentage),
        contains(40),
      );
      expect(
        stateless.activities.map((item) => [item.eventType, item.status]),
        containsAll([
          ['execution.started', 'running'],
          ['model.status', 'running'],
          ['tool.started', 'running'],
          ['tool.completed', 'completed'],
          ['execution.completed', 'completed'],
        ]),
      );
      expect(
        stateless.activities
            .where((item) => item.eventType == 'tool.started')
            .map((item) => item.activityId),
        containsAll(['tool-call-1', 'tool-call-2']),
      );
      expect(
        stateless.activities
            .where((item) => item.eventType == 'message.updated')
            .map((item) => item.title),
        containsAll(['provider_response_received', 'provider_working']),
      );

      final statelessWithContext = await exchange(
        ExecuteRequest(
          requestId: 'gemini-stateless-context',
          assignmentId: 'gemini-stateless-context',
          prompt: 'Context stateless',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.stateless,
          statelessContext: ConversationBootstrap(
            conversationId: 'C',
            contextRevision: 0,
            turnRevision: 1,
            throughSequence: 0,
            text: jsonEncode({
              'schemaVersion': 1,
              'kind': 'StatelessContext',
              'conversationId': 'C',
              'throughSequence': 0,
              'history': [],
              'context': {
                'workflowState': {
                  'revision': 0,
                  'sequence': 0,
                  'value': {
                    'workflowId': 'chat',
                    'workflowVersion': 1,
                    'status': 'running',
                  },
                },
              },
            }),
          ),
        ),
      );
      expect(
        statelessWithContext.terminal,
        isA<WorkerResult>(),
        reason: '${statelessWithContext.terminal.toJson()}',
      );
      expect(
        (statelessWithContext.terminal as WorkerResult).output,
        'Gemini answer',
      );

      final durableStart = await exchange(
        ExecuteRequest(
          requestId: 'gemini-profile-durable-start',
          assignmentId: 'gemini-durable-start',
          prompt: 'Start durable',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.durableSession,
          sessionKey: 'gemini-session-1',
        ),
      );
      expect(
        durableStart.terminal,
        isA<WorkerResult>(),
        reason: '${durableStart.terminal.toJson()} stderr=$engineStderr',
      );
      expect((durableStart.terminal as WorkerResult).output, 'Gemini answer');
      final storedSession = stateDirectory
          .listSync()
          .whereType<File>()
          .singleWhere(
            (file) => file.uri.pathSegments.last.startsWith('session-'),
          );
      expect(
        (jsonDecode(await storedSession.readAsString()) as Map)['sessionId'],
        'fixture-conversation-1',
      );

      final durableResume = await exchange(
        ExecuteRequest(
          requestId: 'gemini-profile-durable-resume',
          assignmentId: 'gemini-durable-resume',
          prompt: 'Continue durable',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.durableSession,
          sessionKey: 'gemini-session-1',
        ),
      );
      expect(
        durableResume.terminal,
        isA<WorkerResult>(),
        reason: '${durableResume.terminal.toJson()} stderr=$engineStderr',
      );
      expect((durableResume.terminal as WorkerResult).output, 'Gemini answer');

      final rejectedResume = await exchange(
        ExecuteRequest(
          requestId: 'gemini-profile-durable-mismatch',
          assignmentId: 'gemini-durable-mismatch',
          prompt: 'Continue safely',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.durableSession,
          sessionKey: 'gemini-session-1',
        ),
      );
      expect(
        (rejectedResume.terminal as WorkerErrorFrame).code,
        WorkerIssueCode.providerFailure,
        reason: '${rejectedResume.terminal.toJson()}',
      );

      final conflictingSession = await exchange(
        ExecuteRequest(
          requestId: 'gemini-profile-session-conflict',
          assignmentId: 'gemini-session-conflict',
          prompt: 'Conflicting session',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ),
      );
      expect(
        (conflictingSession.terminal as WorkerErrorFrame).code,
        WorkerIssueCode.providerFailure,
        reason: '${conflictingSession.terminal.toJson()}',
      );

      final authFailure = await exchange(
        ExecuteRequest(
          requestId: 'gemini-profile-auth-error',
          assignmentId: 'gemini-auth-error',
          prompt: 'Provider auth failure',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ),
      );
      expect(
        (authFailure.terminal as WorkerErrorFrame).code,
        WorkerIssueCode.providerAuthenticationRequired,
        reason: '${authFailure.terminal.toJson()}',
      );

      final permissionFailure = await exchange(
        ExecuteRequest(
          requestId: 'gemini-profile-permission-error',
          assignmentId: 'gemini-permission-error',
          prompt: 'Provider permission failure',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ),
      );
      expect(
        (permissionFailure.terminal as WorkerErrorFrame).code,
        WorkerIssueCode.permissionDenied,
        reason: '${permissionFailure.terminal.toJson()}',
      );

      final quotaFailure = await exchange(
        ExecuteRequest(
          requestId: 'gemini-profile-quota-error',
          assignmentId: 'gemini-quota-error',
          prompt: 'Provider quota exhausted',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ),
      );
      expect(
        (quotaFailure.terminal as WorkerErrorFrame).code,
        WorkerIssueCode.quotaExhausted,
        reason: '${quotaFailure.terminal.toJson()}',
      );

      final missingTerminal = await exchange(
        ExecuteRequest(
          requestId: 'gemini-profile-missing-terminal',
          assignmentId: 'gemini-missing-terminal',
          prompt: 'Missing terminal',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ),
      );
      expect(
        (missingTerminal.terminal as WorkerErrorFrame).code,
        WorkerIssueCode.providerFailure,
        reason: '${missingTerminal.terminal.toJson()}',
      );
      expect(allProgress, isNotEmpty);
    },
  );
}
