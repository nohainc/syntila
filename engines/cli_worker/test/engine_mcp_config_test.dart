import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'passes consented MCP servers through a private per-execution config',
    () async {
      final repository = Directory.current.parent.parent.path;
      final state = await Directory.systemTemp.createTemp('syntila-mcp-');
      addTearDown(() => state.delete(recursive: true));
      final providerDirectory = Directory('${state.path}/provider-bin')
        ..createSync();
      final providerExecutable = File(
        '${providerDirectory.path}/fixture-provider'
        '${Platform.isWindows ? '.exe' : ''}',
      );
      final build = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        '$repository/packages/tool-profile/test/fixtures/fixture_provider.dart',
        '-o',
        providerExecutable.path,
      ], workingDirectory: repository);
      expect(build.exitCode, 0, reason: '${build.stderr}');

      final base =
          jsonDecode(
                await File(
                  '$repository/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
                ).readAsString(),
              )
              as Map<String, Object?>;
      final execution = Map<String, Object?>.from(base['execution'] as Map);
      execution['arguments'] = [
        {'sandboxPolicyMapping': true},
        'echo',
        '{{prompt}}',
        {
          'mcpConfigArguments': [
            '--mcp-config',
            '{{mcpConfigPath}}',
            '--strict-mcp-config',
          ],
        },
        {'providerTimeoutArguments': true},
      ];
      final profileBytes = utf8.encode(
        jsonEncode({...base, 'execution': execution}),
      );
      final profileFile = File('${state.path}/profile.json')
        ..writeAsBytesSync(profileBytes);

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
              '${providerDirectory.path}${Platform.isWindows ? ';' : ':'}'
              '${Platform.environment['PATH'] ?? ''}',
        },
      );
      final lines = StreamIterator<String>(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await lines.cancel();
      });
      Future<WorkerFrame> send(WorkerFrame frame) async {
        process.stdin.writeln(frame.encode());
        await process.stdin.flush();
        while (await lines.moveNext().timeout(const Duration(seconds: 60))) {
          final next = decodeWorkerFrame(lines.current);
          if (next is WorkerProgress || next is WorkerActivity) continue;
          return next;
        }
        throw StateError('Engine closed before a terminal frame');
      }

      expect(
        await send(
          InitializeRequest(
            requestId: 'init',
            workerTypeId: base['logicalWorkerTypeId']! as String,
            expectedEngineVersion: '1.0.0',
            profileDefinitionId: base['profileDefinitionId']! as String,
            profileReleaseVersion: '7',
            profileDigest: sha256.convert(profileBytes).toString(),
          ),
        ),
        isA<InitializeResult>(),
      );
      ExecuteRequest execute(String id, List<McpServerLaunch> servers) =>
          ExecuteRequest(
            requestId: id,
            assignmentId: 'fixture-assignment',
            prompt: 'hello',
            timeoutMs: 60000,
            sessionPolicy: WorkerSessionPolicy.stateless,
            mcpServers: servers,
          );

      final withMcp =
          await send(
                execute('with', [
                  McpServerLaunch(
                    name: 'files',
                    command: '/usr/bin/true',
                    arguments: ['--root', '/tmp/a b'],
                    environment: {'TOKEN': 'secret-value'},
                  ),
                ]),
              )
              as WorkerResult;
      expect(
        withMcp.output,
        contains(
          '"mcpServers":{"files":{"command":"/usr/bin/true",'
          '"args":["--root","/tmp/a b"],"env":{"TOKEN":"secret-value"}}}',
        ),
      );
      final path = RegExp(r'file: (\S+)').firstMatch(withMcp.output)!.group(1)!;
      if (!Platform.isWindows) {
        expect(withMcp.output, contains('mode: 600'));
      }
      // The config (which can hold credentials) is gone once the run ends.
      expect(File(path).existsSync(), isFalse);
      expect(Directory(File(path).parent.path).existsSync(), isFalse);

      final without = await send(execute('without', const [])) as WorkerResult;
      expect(without.output, contains('\"mcpServers\":{}'));
      expect(without.output, contains(' | strict'));
      final emptyPath = RegExp(
        r'file: (\S+)',
      ).firstMatch(without.output)!.group(1)!;
      expect(File(emptyPath).existsSync(), isFalse);
      await process.stdin.close();
    },
  );
}
