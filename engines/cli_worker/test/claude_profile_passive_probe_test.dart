import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test('Claude starter passive probe only invokes the version command', () async {
    final repository = Directory.current.parent.parent.path;
    final root = await Directory.systemTemp.createTemp('claude-passive-');
    final profile =
        jsonDecode(
              await File(
                '$repository/apps/profile_lab/assets/profiles/claude.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    final logPath = '${root.path}/calls.jsonl';
    final providerPath = '${root.path}/provider.dart';
    await File(providerPath).writeAsString('''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  File(r'$logPath').writeAsStringSync(
    jsonEncode(args) + '\\n', mode: FileMode.append,
  );
  if (args.length == 1 && args.single == '--version') {
    stdout.writeln('2.1.287 (Claude Code)');
  } else {
    stderr.writeln('Unexpected command: passive probes must not invoke a model');
    exitCode = 1;
  }
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
    expect(await lines.moveNext().timeout(const Duration(seconds: 10)), isTrue);
    expect(decodeWorkerFrame(lines.current), isA<InitializeResult>());
    process.stdin.writeln(
      ProbeRequest(
        requestId: 'claude-passive',
        mode: WorkerProbeMode.passive,
      ).encode(),
    );
    await process.stdin.flush();
    expect(await lines.moveNext().timeout(const Duration(seconds: 20)), isTrue);
    final result = decodeWorkerFrame(lines.current) as ProbeResult;
    expect(result.ready, isTrue, reason: '${result.toJson()}');
    expect(result.issueCode, isNull);
    expect(result.providerToolVersion, '2.1.287');
    expect(await File(logPath).readAsLines(), [
      jsonEncode(['--version']),
    ]);
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
  });
}
