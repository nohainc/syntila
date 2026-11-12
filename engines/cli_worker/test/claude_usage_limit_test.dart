import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  for (final evidence in [
    'structured',
    'session-text',
    'other-quota',
    'success',
  ]) {
    test('Claude starter handles usage-limit evidence: $evidence', () async {
      final repository = Directory.current.parent.parent.path;
      final root = await Directory.systemTemp.createTemp('claude-passive-');
      final profile =
          jsonDecode(
                await File(
                  '$repository/apps/profile_lab/assets/profiles/claude.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final providerPath = '${root.path}/provider.dart';
      final events = [
        if (evidence == 'structured')
          {
            'type': 'assistant',
            'error': 'rate_limit',
            'message': {
              'content': [
                {
                  'type': 'text',
                  'text':
                      "You've hit your session limit · resets 9:10pm (Europe/Bratislava)",
                },
              ],
            },
          },
        {
          'type': 'result',
          'is_error': evidence != 'success',
          'result': switch (evidence) {
            'session-text' =>
              "You've hit your session limit · resets 9:10pm (Europe/Bratislava)",
            'other-quota' => 'insufficient_quota',
            'success' => 'An answer explaining rate limits.',
            _ => '',
          },
        },
      ];
      await File(providerPath).writeAsString(''' 
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  if (args.contains('--version')) {
    stdout.writeln('2.1.287 (Claude Code)');
    return;
  }
  for (final event in jsonDecode(utf8.decode(base64Decode('${base64.encode(utf8.encode(jsonEncode(events)))}'))) as List) {
    stdout.writeln(jsonEncode(event));
  }
  exitCode = ${evidence == 'success' ? 0 : 1};
}
''');
      // Replace only executable resolution/version transport; retain the
      // starter's model and probe declarations to catch unsupported discovery.
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
      ];
      (profile['model']! as Map<String, Object?>).remove('discovery');
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
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await lines.cancel();
        await root.delete(recursive: true);
      });
      process.stdin.writeln(
        InitializeRequest(
          requestId: 'claude-init',
          workerTypeId: 'claude',
          expectedEngineVersion: '1.0.0',
          profileDefinitionId: 'claude-code',
          profileReleaseVersion: '${profile['releaseVersion']}',
          profileDigest: sha256.convert(bytes).toString(),
        ).encode(),
      );
      await process.stdin.flush();
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      expect(decodeWorkerFrame(lines.current), isA<InitializeResult>());
      process.stdin.writeln(
        ExecuteRequest(
          requestId: 'quota-execute',
          assignmentId: 'quota-assignment',
          prompt: 'Continue',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ).encode(),
      );
      await process.stdin.flush();
      WorkerFrame? terminal;
      while (await lines.moveNext().timeout(const Duration(seconds: 20))) {
        final frame = decodeWorkerFrame(lines.current);
        if (frame is WorkerErrorFrame || frame is WorkerResult) {
          terminal = frame;
          break;
        }
      }
      if (evidence == 'success') {
        expect(terminal, isA<WorkerResult>());
      } else {
        expect(terminal, isA<WorkerErrorFrame>());
        expect((terminal as WorkerErrorFrame).code, 'quota_exhausted');
        expect(jsonEncode(terminal.toJson()), isNot(contains('9:10pm')));
      }
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
    });
  }
}
