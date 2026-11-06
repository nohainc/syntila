import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test(
    'logical Codex selections invoke native model plus separate effort',
    () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp('native-model-');
      final provider = File('${root.path}/provider.dart');
      await provider.writeAsString(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  if (args.contains('--version')) { stdout.writeln('0.160.0'); return; }
  if (args.contains('app-server')) {
    await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final request = jsonDecode(line) as Map;
      final result = request['method'] == 'initialize' ? <String,Object?>{} : {
        'data': [{'id':'logical-model','model':'native-model','displayName':'Model',
          'supportedReasoningEfforts':[{'reasoningEffort':'ultra'}], 'defaultReasoningEffort':'ultra'}],
        'nextCursor':null};
      stdout.writeln(jsonEncode({'id':request['id'],'result':result}));
    }
    return;
  }
  await stdin.drain<void>();
  final model = args[args.indexOf('--model') + 1];
  // Other `-c` overrides exist (the MCP isolation slot); effort is the one
  // that sets model_reasoning_effort.
  final effortIndex = [
    for (var i = 0; i < args.length - 1; i++)
      if (args[i] == '-c' && args[i + 1].startsWith('model_reasoning_effort'))
        i,
  ].firstOrNull ?? -1;
  final effort = effortIndex < 0 ? 'omitted' : args[effortIndex + 1];
  stdout.writeln(jsonEncode({'type':'thread.started','thread_id':'native-fixture'}));
  stdout.writeln(jsonEncode({'type':'item.completed','item':{'type':'agent_message','text':'$model|$effort'}}));
  stdout.writeln(jsonEncode({'type':'turn.completed'}));
}
''');
      final profile =
          jsonDecode(
                await File(
                  '$repository/apps/profile_lab/assets/profiles/chatgpt.json',
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
        'app-server',
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
          '1.1.0',
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
        while (await lines.moveNext().timeout(const Duration(seconds: 20))) {
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
            workerTypeId: 'chatgpt',
            expectedEngineVersion: '1.1.0',
            profileDefinitionId: 'chatgpt-codex',
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
      expect(probe.modelCatalog!.models.single.id, 'logical-model');
      expect(probe.modelCatalog!.models.single.nativeId, 'native-model');
      for (final effort in <String?>['ultra', null]) {
        final result = await exchange(
          ExecuteRequest(
            requestId: 'execute-${effort ?? 'auto'}',
            assignmentId: 'assignment',
            prompt: 'echo',
            model: 'logical-model',
            reasoningEffort: effort,
            sessionPolicy: WorkerSessionPolicy.stateless,
            timeoutMs: 10000,
            executionPolicy: WorkerExecutionPolicy.providerDefault,
          ),
        );
        expect(result, isA<WorkerResult>());
        expect(
          (result as WorkerResult).output,
          'native-model|${effort == null ? 'omitted' : 'model_reasoning_effort="ultra"'}',
        );
      }
    },
  );
}
