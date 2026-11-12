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
    'all combined Gemini pairs invoke exact native slugs without separate effort',
    () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp('native-model-');
      final provider = File('${root.path}/provider.dart');
      await provider.writeAsString(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  if (args.contains('--version')) { stdout.writeln('1.3.3'); return; }
  if (args.contains('models')) {
    if (File('${Platform.script.toFilePath()}.offline').existsSync()) { stderr.writeln('temporary discovery failure'); exit(2); }
    for (final version in ['3.8','3.7','3.6','3.1']) {
      for (final effort in version == '3.1' ? ['low','high'] : ['low','medium','high']) {
        final kind = version == '3.1' ? 'pro' : 'flash';
        final label = effort[0].toUpperCase() + effort.substring(1);
        stdout.writeln('gemini-$version-$kind-$effort\tGemini $version ${kind[0].toUpperCase()}${kind.substring(1)} ($label)');
      }
    }
    return;
  }
  final input = await stdin.transform(utf8.decoder).join();
  if (input.contains("reject-model")) { stderr.writeln("unsupported model"); exit(2); }
  final model = args[args.indexOf('--model') + 1];
  if (input.contains('deny-write')) {
    stdout.writeln(jsonEncode({'event':'result','result':{'status':'SUCCESS','response':'I will create the files.','conversation_id':'fixture','denied_actions':[{'action':'write_file','display_name':'WriteToFile'}]}}));
    return;
  }
  if (input.contains('deny-command-answer')) {
    stdout.writeln(jsonEncode({'event':'result','result':{'status':'SUCCESS','response':'plan from read_file','conversation_id':'fixture','denied_actions':[{'action':'run_command'}]}}));
    return;
  }
  if (input.contains('deny-command-empty')) {
    final retry = input.contains('Note from Syntila');
    stdout.writeln(jsonEncode({'event':'result','result':{'status':'SUCCESS','response': retry ? 'answered without rg' : '','conversation_id':'fixture','denied_actions': retry ? [] : [{'action':'run_command'}]}}));
    return;
  }
  if (input.contains('empty-once')) {
    final marker = File('${Platform.script.toFilePath()}.empty-seen');
    final first = !marker.existsSync();
    if (first) marker.writeAsStringSync('seen');
    stdout.writeln(jsonEncode({'event':'result','result':{'status':'SUCCESS','response': first ? '' : 'hi again','conversation_id':'fixture'}}));
    return;
  }
  if (input.contains('empty-always')) {
    stdout.writeln(jsonEncode({'event':'result','result':{'status':'SUCCESS','response':'','conversation_id':'fixture'}}));
    return;
  }
  if (input.contains('empty-denied')) {
    stdout.writeln(jsonEncode({'event':'result','result':{'status':'SUCCESS','response':'done','conversation_id':'fixture','denied_actions':[]}}));
    return;
  }
  stdout.writeln(jsonEncode({'event':'result','result':{'status':'SUCCESS','response':'$model|${args.contains('--effort')}','conversation_id':'fixture'}}));
}
''');
      final profile =
          jsonDecode(
                await File(
                  '$repository/apps/profile_lab/assets/profiles/gemini.json',
                ).readAsString(),
              )
              as Map;
      final tool = profile['providerTool'] as Map;
      tool['executableCandidates'] = ['dart'];
      (tool['discovery'] as Map)['standardLocations'] = <String>[];
      (tool['versionProbe'] as Map)['arguments'] = [
        'run',
        provider.path,
        '--version',
      ];
      (profile['probe'] as Map)['passive'] = {'checks': [], 'configChecks': []};
      (profile['model'] as Map)['discovery']['arguments'] = [
        'run',
        provider.path,
        'models',
      ];
      final execution = profile['execution'] as Map;
      execution['arguments'] = [
        'run',
        provider.path,
        ...execution['arguments'] as List,
      ];
      final bytes = utf8.encode(jsonEncode(profile));
      final profileFile = File('${root.path}/profile.json');
      await profileFile.writeAsBytes(bytes);
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          '$repository/engines/cli_worker/bin/syntila_cli_worker.dart',
          '--profile',
          profileFile.path,
          '--engine-version',
          '1.3.0',
          '--state-directory',
          '${root.path}/state',
        ],
        workingDirectory: repository,
        environment: {
          ...Platform.environment,
          'PATH':
              '${File(Platform.resolvedExecutable).parent.path}:${Platform.environment['PATH'] ?? ''}',
        },
      );
      final stderrDrain = process.stderr.drain<void>();
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await lines.cancel();
        await stderrDrain;
        await root.delete(recursive: true);
      });
      Future<WorkerFrame> exchange(WorkerFrame request) async {
        process.stdin.writeln(request.encode());
        await process.stdin.flush();
        while (await lines.moveNext().timeout(const Duration(seconds: 60))) {
          final response = decodeWorkerFrame(lines.current);
          if (response.requestId == request.requestId &&
              response is! WorkerProgress &&
              response is! WorkerActivity)
            return response;
        }
        throw StateError('No response');
      }

      expect(
        await exchange(
          InitializeRequest(
            requestId: 'init',
            workerTypeId: 'gemini',
            expectedEngineVersion: '1.3.0',
            profileDefinitionId: 'gemini-antigravity',
            profileReleaseVersion: '${profile['releaseVersion']}',
            profileDigest: sha256.convert(bytes).toString(),
          ),
        ),
        isA<InitializeResult>(),
      );
      final probe =
          await exchange(
                ProbeRequest(requestId: 'probe', mode: WorkerProbeMode.passive),
              )
              as ProbeResult;
      expect(probe.modelCatalog!.schemaVersion, 2);

      expect(probe.modelCatalog!.models.length, 4);
      final changedCatalog = await exchange(
        ExecuteRequest(
          requestId: 'changed-catalog',
          assignmentId: 'assignment',
          prompt: 'echo',
          model: 'gemini-3.8-flash',
          reasoningEffort: 'high',
          catalogRevision: 'b' * 64,
          sessionPolicy: WorkerSessionPolicy.stateless,
          timeoutMs: 10000,
        ),
      );
      expect(changedCatalog, isA<WorkerErrorFrame>());
      expect(
        (changedCatalog as WorkerErrorFrame).message,
        contains('catalog changed'),
      );
      for (final model in probe.modelCatalog!.models) {
        final missing = await exchange(
          ExecuteRequest(
            requestId: 'missing-${model.id}',
            assignmentId: 'assignment',
            prompt: 'echo',
            model: model.id,
            sessionPolicy: WorkerSessionPolicy.stateless,
            timeoutMs: 10000,
            executionPolicy: WorkerExecutionPolicy.providerDefault,
          ),
        );
        expect(missing, isA<WorkerErrorFrame>());
        for (final effort in model.supportedReasoningEfforts) {
          final result = await exchange(
            ExecuteRequest(
              requestId: '${model.id}-$effort',
              assignmentId: 'assignment',
              prompt: 'echo',
              model: model.id,
              reasoningEffort: effort,
              sessionPolicy: WorkerSessionPolicy.stateless,
              timeoutMs: 10000,
              executionPolicy: WorkerExecutionPolicy.providerDefault,
            ),
          );
          expect(result, isA<WorkerResult>());
          expect((result as WorkerResult).output, '${model.id}-$effort|false');
          final invocationKey = sha256
              .convert(utf8.encode('${model.id}-$effort'))
              .toString();
          final audit =
              jsonDecode(
                    await File(
                      '${root.path}/state/execution-selections/$invocationKey.json',
                    ).readAsString(),
                  )
                  as Map;
          expect(audit['modelId'], model.id);
          expect(audit['effort'], effort);
          expect(audit['resolvedNativeModelId'], '${model.id}-$effort');
          expect(audit['profileDigest'], sha256.convert(bytes).toString());
          expect(audit['catalogRevision'], matches(RegExp(r'^[a-f0-9]{64}$')));
          final observation =
              jsonDecode(
                    await File(
                      '${root.path}/state/execution-selections/$invocationKey.completion.json',
                    ).readAsString(),
                  )
                  as Map;
          expect(observation['acceptedModelId'], isNull);
          expect(observation['selectionObservation'], 'unavailable');
        }
      }
      final rejected = await exchange(
        ExecuteRequest(
          requestId: 'reject',
          assignmentId: 'assignment',
          prompt: 'reject-model',
          model: 'gemini-3.8-flash',
          reasoningEffort: 'high',
          sessionPolicy: WorkerSessionPolicy.stateless,
          timeoutMs: 10000,
          executionPolicy: WorkerExecutionPolicy.providerDefault,
        ),
      );
      expect(rejected, isA<WorkerErrorFrame>());
      // A turn that reports SUCCESS but denied an action did not do the work.
      final denied = await exchange(
        ExecuteRequest(
          requestId: 'denied',
          assignmentId: 'assignment',
          prompt: 'deny-write',
          model: 'gemini-3.8-flash',
          reasoningEffort: 'low',
          sessionPolicy: WorkerSessionPolicy.stateless,
          timeoutMs: 10000,
          executionPolicy: WorkerExecutionPolicy.providerDefault,
        ),
      );
      expect(denied, isA<WorkerErrorFrame>());
      expect(
        (denied as WorkerErrorFrame).code,
        WorkerIssueCode.permissionDenied,
      );
      // Read-only: a denied command with a real answer keeps the answer.
      final commandDenied = await exchange(
        ExecuteRequest(
          requestId: 'deny-command-answer',
          assignmentId: 'assignment',
          prompt: 'deny-command-answer',
          model: 'gemini-3.8-flash',
          reasoningEffort: 'low',
          sessionPolicy: WorkerSessionPolicy.stateless,
          timeoutMs: 10000,
          executionPolicy: WorkerExecutionPolicy.providerDefault,
        ),
      );
      expect(commandDenied, isA<WorkerResult>());
      // Read-only: a denied command with no answer is retried once with a note.
      final commandDeniedEmpty = await exchange(
        ExecuteRequest(
          requestId: 'deny-command-empty',
          assignmentId: 'assignment',
          prompt: 'deny-command-empty',
          model: 'gemini-3.8-flash',
          reasoningEffort: 'low',
          sessionPolicy: WorkerSessionPolicy.stateless,
          timeoutMs: 20000,
          executionPolicy: WorkerExecutionPolicy.providerDefault,
        ),
      );
      expect(commandDeniedEmpty, isA<WorkerResult>());
      // Write steps are not forgiven: the denied command may hide unfinished work.
      final writeStepDenied = await exchange(
        ExecuteRequest(
          requestId: 'deny-command-answer-write',
          assignmentId: 'assignment',
          prompt: 'deny-command-answer',
          model: 'gemini-3.8-flash',
          reasoningEffort: 'low',
          sessionPolicy: WorkerSessionPolicy.stateless,
          timeoutMs: 10000,
          executionPolicy: WorkerExecutionPolicy.restricted,
        ),
      );
      expect(writeStepDenied, isA<WorkerErrorFrame>());
      final emptyDenied = await exchange(
        ExecuteRequest(
          requestId: 'empty-denied',
          assignmentId: 'assignment',
          prompt: 'empty-denied',
          model: 'gemini-3.8-flash',
          reasoningEffort: 'low',
          sessionPolicy: WorkerSessionPolicy.stateless,
          timeoutMs: 10000,
          executionPolicy: WorkerExecutionPolicy.providerDefault,
        ),
      );
      expect(emptyDenied, isA<WorkerResult>());
      // An empty "success" is retried once; a second empty answer is a clear
      // error rather than a generic provider failure.
      final retried = await exchange(
        ExecuteRequest(
          requestId: 'empty-once',
          assignmentId: 'assignment',
          prompt: 'empty-once',
          model: 'gemini-3.8-flash',
          reasoningEffort: 'low',
          sessionPolicy: WorkerSessionPolicy.stateless,
          timeoutMs: 20000,
          executionPolicy: WorkerExecutionPolicy.providerDefault,
        ),
      );
      expect(retried, isA<WorkerResult>());
      final stillEmpty = await exchange(
        ExecuteRequest(
          requestId: 'empty-always',
          assignmentId: 'assignment',
          prompt: 'empty-always',
          model: 'gemini-3.8-flash',
          reasoningEffort: 'low',
          sessionPolicy: WorkerSessionPolicy.stateless,
          timeoutMs: 20000,
          executionPolicy: WorkerExecutionPolicy.providerDefault,
        ),
      );
      expect(stillEmpty, isA<WorkerErrorFrame>());
      expect(
        (stillEmpty as WorkerErrorFrame).message,
        contains('empty answer'),
      );
      final refreshed =
          await exchange(
                ProbeRequest(
                  requestId: 'refresh',
                  mode: WorkerProbeMode.passive,
                ),
              )
              as ProbeResult;
      final family = refreshed.modelCatalog!.models.firstWhere(
        (m) => m.id == 'gemini-3.8-flash',
      );
      expect(family.status, 'verified');
      expect(family.supportedReasoningEfforts, ['low', 'medium']);
      expect(family.variantStatuses['high'], 'unavailable');
      expect(
        family
            .toJson(schemaVersion: 2, includeNativeId: false)
            .containsKey('variantStatuses'),
        isFalse,
      );
      final offline = File('${provider.path}.offline');
      await offline.writeAsString('offline');
      final staleProbe =
          await exchange(
                ProbeRequest(
                  requestId: 'stale-refresh',
                  mode: WorkerProbeMode.passive,
                ),
              )
              as ProbeResult;
      expect(staleProbe.modelCatalog!.stale, isTrue);
      expect(
        staleProbe.modelCatalog!.catalogRevision,
        refreshed.modelCatalog!.catalogRevision,
      );
      await offline.delete();
      final recovery =
          await exchange(
                ProbeRequest(
                  requestId: 'recovered-refresh',
                  mode: WorkerProbeMode.passive,
                ),
              )
              as ProbeResult;
      expect(recovery.modelCatalog!.stale, isFalse);
      expect(
        recovery.modelCatalog!.catalogRevision,
        staleProbe.modelCatalog!.catalogRevision,
      );
    },
  );
}
