import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test('chatgpt-codex Profile reproduces the current Worker acceptance path', () async {
    final repository = Directory.current.parent.parent.path;
    final profile =
        jsonDecode(
              await File(
                '$repository/packages/tool-profile/test/fixtures/chatgpt-codex.v1.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    final provider = profile['providerTool']! as Map<String, Object?>;
    const providerScript =
        'packages/tool-profile/test/fixtures/provider-cli/codex_profile_provider.dart';
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
    final passive =
        (profile['probe']! as Map<String, Object?>)['passive']!
            as Map<String, Object?>;
    passive['checks'] = [
      {
        'id': 'authentication',
        'arguments': ['run', providerScript, 'login', 'status'],
        'timeoutMs': 10000,
        'successExitCodes': [0],
        'failureIssueCode': 'provider_authentication_required',
      },
    ];
    final execution = profile['execution']! as Map<String, Object?>;
    execution['failureExtraction'] = {
      'providerErrorText': r'$.error.message',
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
    final root = await Directory.systemTemp.createTemp('codex-profile-');
    final profileFile = File('${root.path}/profile.json')
      ..writeAsBytesSync(profileBytes);
    final stateDirectory = await Directory('${root.path}/state').create();
    final providerHome = await Directory('${root.path}/provider-home').create();
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
            '${File(Platform.resolvedExecutable).parent.path}${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}',
        'HOME': providerHome.path,
        'CODEX_HOME': '${providerHome.path}/.codex',
        'OPENAI_API_KEY': 'codex-fixture-key',
      },
      runInShell: false,
    );
    final lines = StreamIterator<String>(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final engineStderr = StringBuffer();
    final stderrTask = process.stderr
        .transform(utf8.decoder)
        .listen(engineStderr.write);
    final progress = <WorkerProgress>[];
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
      while (await lines.moveNext().timeout(const Duration(seconds: 35))) {
        final frame = decodeWorkerFrame(lines.current);
        if (frame is WorkerProgress && frame.requestId == request.requestId) {
          observedProgress.add(frame);
          progress.add(frame);
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
        requestId: 'codex-profile-init',
        workerTypeId: 'chatgpt',
        expectedEngineVersion: '1.0.0',
        profileDefinitionId: 'chatgpt-codex',
        profileReleaseVersion: '1',
        profileDigest: sha256.convert(profileBytes).toString(),
        protocolVersion: providerFailureDetailsProtocolVersion,
      ),
    );
    expect(initialized.terminal, isA<InitializeResult>());

    final passiveProbe = await exchange(
      ProbeRequest(
        requestId: 'codex-profile-passive',
        mode: WorkerProbeMode.passive,
      ),
    );
    final passiveResult = passiveProbe.terminal as ProbeResult;
    expect(passiveResult.ready, isTrue, reason: '${passiveResult.toJson()}');
    expect(passiveResult.providerToolVersion, '1.2.3');
    expect(
      passiveResult.checks.map((check) => check.code),
      containsAll(['provider_tool_version', 'authentication']),
    );

    final liveProbe = await exchange(
      ProbeRequest(
        requestId: 'codex-profile-live',
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
        requestId: 'codex-profile-stateless',
        assignmentId: 'codex-stateless',
        prompt: 'Say OK',
        model: 'gpt-test',
        timeoutMs: 10000,
        sessionPolicy: WorkerSessionPolicy.stateless,
      ),
    );
    expect((stateless.terminal as WorkerResult).output, 'Codex answer');
    expect(
      stateless.activities
          .where((item) => item.eventType == 'message.updated')
          .map((item) => item.percentage),
      containsAll([10, 45]),
    );
    expect(
      stateless.activities.map((item) => [item.eventType, item.status]),
      containsAll([
        ['execution.started', 'running'],
        ['model.started', 'running'],
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

    final durableStart = await exchange(
      ExecuteRequest(
        requestId: 'codex-profile-durable-start',
        assignmentId: 'codex-durable-start',
        prompt: 'Start durable',
        timeoutMs: 10000,
        sessionPolicy: WorkerSessionPolicy.durableSession,
        sessionKey: 'logical-session-1',
      ),
    );
    expect(
      durableStart.terminal,
      isA<WorkerResult>(),
      reason: '${durableStart.terminal.toJson()}',
    );
    expect((durableStart.terminal as WorkerResult).output, 'Codex answer');
    final storedSession = stateDirectory
        .listSync()
        .whereType<File>()
        .singleWhere(
          (file) => file.uri.pathSegments.last.startsWith('session-'),
        );
    expect(
      (jsonDecode(await storedSession.readAsString()) as Map)['sessionId'],
      'fake-session-1',
    );

    final durableResume = await exchange(
      ExecuteRequest(
        requestId: 'codex-profile-durable-resume',
        assignmentId: 'codex-durable-resume',
        prompt: 'Continue durable',
        timeoutMs: 10000,
        sessionPolicy: WorkerSessionPolicy.durableSession,
        sessionKey: 'logical-session-1',
      ),
    );
    expect((durableResume.terminal as WorkerResult).output, 'Codex answer');

    final effortScope = WorkerSessionContext(
      id: 'effort-session',
      conversationId: 'effort-conversation',
      workerId: 'effort-worker',
      baseContextRevision: 0,
    );
    for (final effort in ['medium', 'high']) {
      final changedEffort = await exchange(
        ExecuteRequest(
          requestId: 'effort-$effort',
          assignmentId: 'effort-$effort',
          prompt: effort == 'medium'
              ? 'Start medium effort'
              : 'Continue high effort',
          model: 'gpt-test',
          reasoningEffort: effort,
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.durableSession,
          sessionKey: 'effort-logical-session',
          workerSession: effortScope,
        ),
      );
      expect(
        changedEffort.terminal,
        isA<WorkerResult>(),
        reason: '${changedEffort.terminal.toJson()} stderr=$engineStderr',
      );
      final metadata = stateDirectory
          .listSync()
          .whereType<File>()
          .where((file) => file.uri.pathSegments.last.startsWith('session-'))
          .map((file) => jsonDecode(file.readAsStringSync()) as Map)
          .singleWhere(
            (state) => state['sessionKey'] == 'effort-logical-session',
          );
      expect(metadata['sessionId'], 'fake-session-1');
      expect(metadata['workerSession'], containsPair('id', 'effort-session'));
      expect(
        metadata['workerSession'],
        containsPair('conversationId', 'effort-conversation'),
      );
      expect(
        metadata['workerSession'],
        containsPair('lastModelId', 'gpt-test'),
      );
      expect(metadata['workerSession'], containsPair('lastEffort', effort));
    }

    final missingBootstrap = await exchange(
      ExecuteRequest(
        requestId: 'codex-profile-missing-bootstrap',
        assignmentId: 'codex-missing-bootstrap',
        prompt: 'Continue without canonical context',
        timeoutMs: 10000,
        sessionPolicy: WorkerSessionPolicy.durableSession,
        sessionKey: 'missing-bootstrap-session',
        workerSession: WorkerSessionContext(
          id: 'missing-bootstrap-worker-session',
          conversationId: 'missing-bootstrap-conversation',
          workerId: 'effort-worker',
          baseContextRevision: 1,
        ),
      ),
    );
    final missingBootstrapError = missingBootstrap.terminal as WorkerErrorFrame;
    expect(missingBootstrapError.code, WorkerIssueCode.sessionResumeFailed);
    expect(
      jsonDecode(missingBootstrapError.diagnostics!) as Map,
      containsPair('stage', 'conversation_routing'),
    );
    expect(missingBootstrap.progress, isEmpty);

    final rejectedResume = await exchange(
      ExecuteRequest(
        requestId: 'codex-profile-durable-mismatch',
        assignmentId: 'codex-durable-mismatch',
        prompt: 'Continue safely',
        timeoutMs: 10000,
        sessionPolicy: WorkerSessionPolicy.durableSession,
        sessionKey: 'logical-session-1',
      ),
    );
    expect(
      (rejectedResume.terminal as WorkerErrorFrame).code,
      WorkerIssueCode.providerFailure,
      reason:
          '${rejectedResume.terminal.toJson()} diagnostics=${(rejectedResume.terminal as WorkerErrorFrame).diagnostics}',
    );

    final permissionFailure = await exchange(
      ExecuteRequest(
        requestId: 'codex-profile-permission-error',
        assignmentId: 'codex-permission-error',
        prompt: 'Permission failure',
        timeoutMs: 10000,
        sessionPolicy: WorkerSessionPolicy.stateless,
      ),
    );
    expect(
      (permissionFailure.terminal as WorkerErrorFrame).code,
      WorkerIssueCode.permissionDenied,
      reason:
          '${permissionFailure.terminal.toJson()} diagnostics=${(permissionFailure.terminal as WorkerErrorFrame).diagnostics}',
    );
    final providerEventFailure = await exchange(
      ExecuteRequest(
        requestId: 'codex-profile-provider-event-error',
        assignmentId: 'codex-provider-event-error',
        prompt: 'Provider event failure',
        timeoutMs: 10000,
        sessionPolicy: WorkerSessionPolicy.stateless,
        protocolVersion: providerFailureDetailsProtocolVersion,
      ),
    );
    expect(
      (providerEventFailure.terminal as WorkerErrorFrame).code,
      WorkerIssueCode.permissionDenied,
      reason:
          '${providerEventFailure.terminal.toJson()} diagnostics=${(providerEventFailure.terminal as WorkerErrorFrame).diagnostics} stderr=$engineStderr',
    );
    final details =
        (providerEventFailure.terminal as WorkerErrorFrame).providerFailure;
    expect(details?['providerErrorText'], 'permission denied by sandbox');
    expect(details?['source'], 'structured_error');
    expect(details?.containsKey('nativeErrorCode'), isFalse);
    expect(progress, isNotEmpty);
  });
}
