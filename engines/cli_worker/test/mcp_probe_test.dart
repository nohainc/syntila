@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/mcp_probe.dart';
import 'package:syntila_cli_worker_engine/src/external_worker_process_host.dart';
import 'package:test/test.dart';

const fixturePath =
    '../../packages/syntila_mcp_protocol/test/fixtures/echo_server.dart';

late String dartDigest;

Map<String, Object?> probeRequest({String? sha, String mode = 'normal'}) => {
  'server': {
    'name': 'echo',
    'command': Platform.resolvedExecutable,
    'arguments': [File(fixturePath).absolute.path, mode],
    'environment': {'TOKEN': 'x'},
  },
  'commandSha256': sha ?? dartDigest,
  'workingDirectory': Directory.systemTemp.path,
};

void main() {
  setUpAll(() async {
    dartDigest = await ExternalWorkerProcessHost().sha256OfFile(
      Platform.resolvedExecutable,
    );
  });

  test('lists tools of a healthy server without calling any', () async {
    final result = await runMcpProbe(probeRequest());
    expect(result['ok'], isTrue);
    final names = [
      for (final t in result['tools']! as List) (t as Map)['name'],
    ];
    expect(names, ['echo', 'slow', 'mutate']);
  });

  test('refuses a command whose digest differs from the pin', () async {
    final result = await runMcpProbe(probeRequest(sha: '0' * 64));
    expect(result['ok'], isFalse);
    expect(result['code'], 'plugin_digest_mismatch');
  });

  test('reports a server that never completes the handshake', () async {
    final result = await runMcpProbe(probeRequest(mode: 'badversion'));
    expect(result['ok'], isFalse);
    expect(result['code'], 'mcp_version_unsupported');
  });

  test('rejects a malformed request without throwing', () async {
    final result = await runMcpProbe({
      'server': {'name': 'Bad Name', 'command': '/bin/x'},
      'commandSha256': 'x',
      'workingDirectory': '/tmp',
    });
    expect(result['ok'], isFalse);
    expect(result['code'], 'invalid_request');
  });

  test('--mcp-probe mode speaks one JSON line over stdio', () async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'bin/syntila_cli_worker.dart',
      mcpProbeFlag,
    ]);
    process.stdin.writeln(jsonEncode(probeRequest()));
    await process.stdin.flush();
    final out = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    expect(await process.exitCode, 0);
    expect(out, hasLength(1));
    final decoded = jsonDecode(out.single) as Map<String, Object?>;
    expect(decoded['ok'], isTrue);
    expect((decoded['tools']! as List), hasLength(3));
  });
}
