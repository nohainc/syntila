@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:syntila_cli_worker_engine/src/engine_session_store.dart';
import 'package:test/test.dart';

void main() {
  test(
    'durable sessions resume only across declared Profile format compatibility',
    () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp(
        'engine-session-release-compatibility-',
      );
      final stateDirectory = await Directory('${root.path}/state').create();
      final providerHome = await Directory(
        '${root.path}/provider-home',
      ).create();
      addTearDown(() => root.delete(recursive: true));

      Future<WorkerResult?> executeRelease({
        required int releaseVersion,
        required String sessionFormatId,
        required List<String> compatibleFormatIds,
        required String requestId,
        required String prompt,
        String? model,
        bool modelSwitchSupported = true,
        String sessionKey = 'direct-and-work-session',
        ConversationBootstrap? bootstrap,
        bool expectFailure = false,
        bool sessionBusy = false,
        String workerId = "worker-fixture",
      }) async {
        final profile =
            jsonDecode(
                  await File(
                    '$repository/packages/tool-profile/test/fixtures/gemini-antigravity.v1.json',
                  ).readAsString(),
                )
                as Map<String, Object?>;
        // Session compatibility uses synthetic model IDs; discovery is not
        // part of this test's contract.
        final modelMetadata = profile['model']! as Map<String, Object?>;
        modelMetadata.remove('discovery');
        modelMetadata.remove('selectionMapping');
        modelMetadata.remove('selectionMode');
        (profile['engineCompatibility']! as Map<String, Object?>)['min'] =
            '1.0.0';
        profile['releaseVersion'] = releaseVersion;
        (profile['model'] as Map)['executionOptions'] = {
          'schemaVersion': 1,
          'discovery': 'profile_catalog',
          'modelSwitchSupported': modelSwitchSupported,
          'effortSupported': false,
        };
        final session = profile['session']! as Map<String, Object?>;
        session['formatId'] = sessionFormatId;
        session['compatibleFormatIds'] = compatibleFormatIds;
        final provider = profile['providerTool']! as Map<String, Object?>;
        const providerScript =
            'packages/tool-profile/test/fixtures/provider-cli/antigravity_profile_provider.dart';
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
        final execution = profile['execution']! as Map<String, Object?>;
        execution['arguments'] = [
          'run',
          providerScript,
          ...(execution['arguments']! as List<Object?>),
        ];
        final profileBytes = utf8.encode(jsonEncode(profile));
        final profileFile = File('${root.path}/profile-$releaseVersion.json')
          ..writeAsBytesSync(profileBytes);
        final heldSession = sessionBusy
            ? await EngineSessionStore(stateDirectory).acquireExecution(
                sessionKey: sessionKey,
                workerTypeId: 'gemini',
                profileDefinitionId: 'gemini-antigravity',
                providerToolIdentity: provider['name'] as String,
              )
            : null;
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
          },
          runInShell: false,
        );
        final lines = StreamIterator<String>(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );
        final engineStderr = StringBuffer();
        final stderrTask = process.stderr
            .transform(utf8.decoder)
            .listen(engineStderr.write);

        Future<WorkerFrame> exchange(WorkerFrame request) async {
          process.stdin.writeln(request.encode());
          await process.stdin.flush();
          while (await lines.moveNext().timeout(const Duration(seconds: 35))) {
            final frame = decodeWorkerFrame(lines.current);
            if (frame.requestId == request.requestId &&
                (frame is InitializeResult ||
                    frame is WorkerResult ||
                    frame is WorkerErrorFrame)) {
              return frame;
            }
          }
          throw TimeoutException('Engine did not return ${request.requestId}');
        }

        try {
          final initialized = await exchange(
            InitializeRequest(
              requestId: '$requestId-init',
              workerTypeId: 'gemini',
              expectedEngineVersion: '1.0.0',
              profileDefinitionId: 'gemini-antigravity',
              profileReleaseVersion: '$releaseVersion',
              profileDigest: sha256.convert(profileBytes).toString(),
            ),
          );
          expect(initialized, isA<InitializeResult>());
          final result = await exchange(
            ExecuteRequest(
              requestId: requestId,
              assignmentId: requestId,
              prompt: prompt,
              timeoutMs: 10000,
              sessionPolicy: WorkerSessionPolicy.durableSession,
              sessionKey: sessionKey,
              model: model,
              workerSession: WorkerSessionContext(
                id: 'worker-session-fixture',
                conversationId: 'conversation-fixture',
                workerId: workerId,
                baseContextRevision: bootstrap?.contextRevision ?? 0,
                bootstrap: bootstrap,
              ),
            ),
          );
          if (expectFailure) {
            expect(result, isA<WorkerErrorFrame>());
            if (sessionBusy) {
              expect(
                (result as WorkerErrorFrame).code,
                WorkerIssueCode.providerUnavailable,
              );
            }
            return null;
          }
          expect(
            result,
            isA<WorkerResult>(),
            reason: '${result.toJson()} stderr=$engineStderr',
          );
          // A stored native handle does not authorize another Conversation or
          // certify ingestion of a newer canonical context revision.
          for (final invalidScope in [
            WorkerSessionContext(
              id: 'worker-session-fixture',
              conversationId: 'conversation-other',
              workerId: 'worker-fixture',
              baseContextRevision: 0,
            ),
            WorkerSessionContext(
              id: 'worker-session-fixture',
              conversationId: 'conversation-fixture',
              workerId: 'worker-fixture',
              baseContextRevision: (bootstrap?.turnRevision ?? 0) + 1,
            ),
          ]) {
            final rejected = await exchange(
              ExecuteRequest(
                requestId:
                    '$requestId-rejected-${invalidScope.baseContextRevision}',
                assignmentId: requestId,
                prompt: 'Must not reach provider',
                timeoutMs: 10000,
                sessionPolicy: WorkerSessionPolicy.durableSession,
                sessionKey: sessionKey,
                workerSession: invalidScope,
              ),
            );
            expect(rejected, isA<WorkerErrorFrame>());
            expect(
              (rejected as WorkerErrorFrame).code,
              WorkerIssueCode.sessionResumeFailed,
            );
          }
          return result as WorkerResult;
        } finally {
          await process.stdin.close();
          await process.exitCode.timeout(const Duration(seconds: 10));
          await lines.cancel();
          await stderrTask.cancel();
          await heldSession?.release();
        }
      }

      final first = await executeRelease(
        releaseVersion: 1,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: const ['antigravity-conversation-v1'],
        requestId: 'release-1-start',
        prompt: 'Start model A',
        model: 'model-A',
      );
      expect(first!.output, 'Gemini answer');

      // The fixture requires the exact new prompt, same model argument, and
      // original native resume handle. Replayed history would fail its checks.
      final continued = await executeRelease(
        releaseVersion: 1,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: const ['antigravity-conversation-v1'],
        requestId: 'release-1-next-turn',
        prompt: 'Continue model A',
        model: 'model-A',
      );
      expect(continued!.output, 'Gemini answer');

      final compatible = await executeRelease(
        releaseVersion: 2,
        sessionFormatId: 'antigravity-conversation-v2',
        compatibleFormatIds: const [
          'antigravity-conversation-v1',
          'antigravity-conversation-v2',
        ],
        requestId: 'release-2-resume',
        prompt: 'Continue model B',
        model: 'model-B',
      );
      expect(compatible!.output, 'Gemini answer');
      final compatibleStateFile = stateDirectory
          .listSync()
          .whereType<File>()
          .singleWhere(
            (file) => file.uri.pathSegments.last.startsWith('session-'),
          );
      final compatibleState =
          jsonDecode(await compatibleStateFile.readAsString()) as Map;
      expect(compatibleState['profileReleaseVersion'], 2);
      expect(compatibleState['sessionFormatId'], 'antigravity-conversation-v2');
      expect(
        (compatibleState['workerSession'] as Map)['lastModelId'],
        'model-B',
      );
      expect(
        (compatibleState['workerSession'] as Map)['id'],
        'worker-session-fixture',
      );
      expect(
        (compatibleState['workerSession'] as Map)['nativeSessionId'],
        'fixture-conversation-1',
      );

      final incompatible = await executeRelease(
        releaseVersion: 3,
        sessionFormatId: 'antigravity-conversation-v3',
        compatibleFormatIds: const ['antigravity-conversation-v3'],
        requestId: 'release-3-fresh-session',
        prompt: 'Continue after incompatible upgrade',
      );
      expect(incompatible!.output, 'Gemini answer');
      final sessionFiles = stateDirectory.listSync().whereType<File>().where(
        (file) => file.uri.pathSegments.last.startsWith('session-'),
      );
      expect(sessionFiles, hasLength(1));
      expect(
        jsonDecode(await sessionFiles.single.readAsString())['sessionId'],
        'fixture-conversation-3',
      );

      await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'no-switch-start',
        prompt: 'Start model A',
        model: 'model-A',
        modelSwitchSupported: false,
        sessionKey: 'no-switch-scope',
      );
      await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'no-switch-failed',
        prompt: 'Switch without resume failure',
        model: 'model-B',
        modelSwitchSupported: false,
        sessionKey: 'no-switch-scope',
        expectFailure: true,
        bootstrap: ConversationBootstrap(
          conversationId: 'conversation-fixture',
          contextRevision: 0,
          throughSequence: 2,
          text: jsonEncode({
            'history': [
              {'kind': 'user_message', 'text': 'Start model A'},
              {'kind': 'worker_response', 'text': 'Gemini answer'},
            ],
          }),
        ),
      );
      final preserved = stateDirectory
          .listSync()
          .whereType<File>()
          .where((file) => file.uri.pathSegments.last.startsWith('session-'))
          .map((file) => jsonDecode(file.readAsStringSync()) as Map)
          .singleWhere((state) => state['sessionKey'] == 'no-switch-scope');
      expect(preserved['sessionId'], 'fixture-conversation-1');
      expect(
        preserved['workerSession'],
        containsPair('lastModelId', 'model-A'),
      );
      final reconstructed = await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'no-switch-reconstruct',
        prompt: 'Switch without resume',
        model: 'model-B',
        modelSwitchSupported: false,
        sessionKey: 'no-switch-scope',
        bootstrap: ConversationBootstrap(
          conversationId: 'conversation-fixture',
          contextRevision: 0,
          throughSequence: 2,
          text: jsonEncode({
            'history': [
              {'kind': 'user_message', 'text': 'Start model A'},
              {'kind': 'worker_response', 'text': 'Gemini answer'},
            ],
          }),
        ),
      );
      expect(reconstructed!.output, 'Gemini answer');
      final replacement = stateDirectory
          .listSync()
          .whereType<File>()
          .where((file) => file.uri.pathSegments.last.startsWith('session-'))
          .map((file) => jsonDecode(file.readAsStringSync()) as Map)
          .singleWhere((state) => state['sessionKey'] == 'no-switch-scope');
      expect(replacement['sessionId'], 'fixture-conversation-3');
      expect(
        replacement['workerSession'],
        containsPair('conversationId', 'conversation-fixture'),
      );
      expect(
        replacement['workerSession'],
        containsPair('lastModelId', 'model-B'),
      );
      final next = await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'no-switch-next',
        prompt: 'Continue reconstructed',
        model: 'model-B',
        modelSwitchSupported: false,
        sessionKey: 'no-switch-scope',
        bootstrap: ConversationBootstrap(
          conversationId: 'conversation-fixture',
          contextRevision: 0,
          throughSequence: 3,
          text: '{"history":["This must not be replayed"]}',
        ),
      );
      expect(next!.output, 'Gemini answer');

      final priorHistory = <Map<String, Object?>>[
        {
          'sequence': 1,
          'contextRevision': 1,
          'kind': 'user_message',
          'text': 'Earlier question',
        },
        {
          'sequence': 2,
          'contextRevision': 1,
          'kind': 'worker_response',
          'text': 'ChatGPT answer',
        },
      ];
      ConversationBootstrap contextSnapshot(
        int revision,
        List<Map<String, Object?>> history,
      ) => ConversationBootstrap(
        conversationId: 'conversation-fixture',
        contextRevision: revision,
        turnRevision: revision + 1,
        throughSequence: history.last['sequence'] as int,
        text: jsonEncode({
          'conversationId': 'conversation-fixture',
          'throughSequence': history.last['sequence'],
          'history': history,
        }),
      );
      final bootstrappedWorker = await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'other-worker-bootstrap',
        prompt: 'Bootstrap other worker',
        model: 'model-A',
        sessionKey: 'other-worker-scope',
        workerId: 'worker-gemini',
        bootstrap: contextSnapshot(1, priorHistory),
      );
      expect(bootstrappedWorker!.output, 'Gemini answer');
      final ownHistory = [
        ...priorHistory,
        {
          'sequence': 3,
          'contextRevision': 2,
          'kind': 'user_message',
          'text': 'Bootstrap other worker',
        },
        {
          'sequence': 4,
          'contextRevision': 2,
          'metadata': {'workerSessionId': 'worker-session-fixture'},
          'kind': 'worker_response',
          'text': 'Gemini answer',
        },
      ];
      final currentWorker = await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'other-worker-current',
        prompt: 'Continue current worker',
        model: 'model-A',
        sessionKey: 'other-worker-scope',
        workerId: 'worker-gemini',
        bootstrap: contextSnapshot(2, ownHistory),
      );
      expect(currentWorker!.output, 'Gemini answer');
      final expandedHistory = [
        ...ownHistory,
        {
          'sequence': 5,
          'contextRevision': 3,
          'kind': 'user_message',
          'text': 'Continue current worker',
        },
        {
          'sequence': 6,
          'contextRevision': 3,
          'metadata': {'workerSessionId': 'worker-session-fixture'},
          'kind': 'worker_response',
          'text': 'Gemini answer',
        },
        {
          'sequence': 7,
          'contextRevision': 4,
          'kind': 'user_message',
          'text': 'Other Worker follow-up',
        },
        {
          'sequence': 8,
          'contextRevision': 4,
          'kind': 'worker_response',
          'text': 'New ChatGPT answer',
        },
      ];
      await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'other-worker-failed-sync',
        prompt: 'Sync returning worker failure',
        model: 'model-A',
        sessionKey: 'other-worker-scope',
        workerId: 'worker-gemini',
        bootstrap: contextSnapshot(4, expandedHistory),
        expectFailure: true,
      );
      final stillBehind = stateDirectory
          .listSync()
          .whereType<File>()
          .where((file) => file.uri.pathSegments.last.startsWith('session-'))
          .map((file) => jsonDecode(file.readAsStringSync()) as Map)
          .singleWhere((state) => state['sessionKey'] == 'other-worker-scope');
      expect(
        stillBehind['workerSession'],
        containsPair('synchronizedContextRevision', 3),
      );
      expect(
        stillBehind['workerSession'],
        containsPair('synchronizedHistorySequence', 4),
      );
      final returningWorker = await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'other-worker-sync',
        prompt: 'Sync returning worker',
        model: 'model-A',
        sessionKey: 'other-worker-scope',
        workerId: 'worker-gemini',
        bootstrap: contextSnapshot(4, expandedHistory),
      );
      expect(returningWorker!.output, 'Gemini answer');
      final synchronized = stateDirectory
          .listSync()
          .whereType<File>()
          .where((file) => file.uri.pathSegments.last.startsWith('session-'))
          .map((file) => jsonDecode(file.readAsStringSync()) as Map)
          .singleWhere((state) => state['sessionKey'] == 'other-worker-scope');
      expect(synchronized['sessionId'], 'fixture-conversation-1');
      expect(
        synchronized['workerSession'],
        containsPair('synchronizedContextRevision', 5),
      );
      expect(
        synchronized['workerSession'],
        containsPair('synchronizedHistorySequence', 8),
      );
      for (final failReplacement in [false, true]) {
        final scope =
            'reconstruction-${failReplacement ? 'failure' : 'success'}';
        await executeRelease(
          releaseVersion: 4,
          sessionFormatId: 'antigravity-conversation-v1',
          compatibleFormatIds: ['antigravity-conversation-v1'],
          requestId: '$scope-start',
          prompt: 'Start model A',
          model: 'model-A',
          sessionKey: scope,
        );
        final reconstructed = await executeRelease(
          releaseVersion: 4,
          sessionFormatId: 'antigravity-conversation-v1',
          compatibleFormatIds: ['antigravity-conversation-v1'],
          requestId: '$scope-recover',
          prompt: failReplacement
              ? 'Recover unavailable failure'
              : 'Recover unavailable',
          model: 'model-A',
          sessionKey: scope,
          bootstrap: contextSnapshot(1, priorHistory),
          expectFailure: failReplacement,
        );
        final state = stateDirectory
            .listSync()
            .whereType<File>()
            .where((f) => f.uri.pathSegments.last.startsWith('session-'))
            .map((f) => jsonDecode(f.readAsStringSync()) as Map)
            .singleWhere((s) => s['sessionKey'] == scope);
        if (failReplacement) {
          expect(reconstructed, isNull);
          expect(state['workerSession'], containsPair('status', 'invalidated'));
          expect(
            state['workerSession'],
            containsPair('synchronizedContextRevision', 0),
          );
        } else {
          expect(reconstructed!.output, 'Gemini answer');
          expect(state['sessionId'], 'replacement-conversation');
          expect(state['workerSession'], containsPair('status', 'active'));
          expect(
            state['workerSession'],
            containsPair('synchronizedContextRevision', 2),
          );
        }
      }
      const missingContextScope = 'reconstruction-missing-context';
      await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'missing-context-start',
        prompt: 'Start model A',
        model: 'model-A',
        sessionKey: missingContextScope,
      );
      await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'missing-context-failure',
        prompt: 'Recover unavailable',
        model: 'model-A',
        sessionKey: missingContextScope,
        expectFailure: true,
      );
      final unavailableState = stateDirectory
          .listSync()
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.startsWith('session-'))
          .map((f) => jsonDecode(f.readAsStringSync()) as Map)
          .singleWhere((s) => s['sessionKey'] == missingContextScope);
      expect(
        unavailableState['workerSession'],
        containsPair('status', 'invalidated'),
      );
      final afterRestart = await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'missing-context-restored',
        prompt: 'Recover unavailable',
        model: 'model-A',
        sessionKey: missingContextScope,
        bootstrap: contextSnapshot(1, priorHistory),
      );
      expect(afterRestart!.output, 'Gemini answer');
      await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'busy-native-session',
        prompt: 'Must not reach provider',
        model: 'model-A',
        sessionKey: missingContextScope,
        bootstrap: contextSnapshot(2, priorHistory),
        sessionBusy: true,
        expectFailure: true,
      );

      // A restored Cloud can change a logical reference while keeping the
      // same owner. Rebuild from canonical context, never resume that handle.
      final driftedFile = stateDirectory
          .listSync()
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.startsWith('session-'))
          .singleWhere(
            (f) =>
                (jsonDecode(f.readAsStringSync()) as Map)['sessionKey'] ==
                missingContextScope,
          );
      final drifted = jsonDecode(driftedFile.readAsStringSync()) as Map;
      (drifted['workerSession'] as Map)['id'] = 'old-logical-reference';
      await driftedFile.writeAsString(jsonEncode(drifted));
      final recoveredReference = await executeRelease(
        releaseVersion: 4,
        sessionFormatId: 'antigravity-conversation-v1',
        compatibleFormatIds: ['antigravity-conversation-v1'],
        requestId: 'same-owner-reference-recovery',
        prompt: 'Recover unavailable',
        model: 'model-A',
        sessionKey: missingContextScope,
        bootstrap: contextSnapshot(1, priorHistory),
      );
      expect(recoveredReference!.output, 'Gemini answer');
      final recoveredState =
          jsonDecode(await driftedFile.readAsString()) as Map;
      expect(
        (recoveredState['workerSession'] as Map)['id'],
        'worker-session-fixture',
      );
      expect(
        stateDirectory.listSync().whereType<File>().any(
          (f) => f.path.contains('.recovery-'),
        ),
        isTrue,
      );
    },
  );
}
