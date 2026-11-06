import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/mcp_tool_call_mode.dart';
import 'package:syntila_cli_worker_engine/src/plugin_host.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:test/test.dart';

import 'support/fake_mcp_http.dart';
import 'support/plugin_test_binaries.dart';

void main() {
  late FakeMcpHttp fake;

  Map<String, Object?> request() => {
    'remote': {
      'endpoint': fake.endpoint.toString(),
      'allowInsecureLoopback': true,
    },
    'tool': 'echo',
    'arguments': {'text': 'hello'},
    'timeoutMs': 5000,
    'toolPins': {
      'echo': toolDefinitionHash({
        'name': 'echo',
        'description': 'echoes',
        'inputSchema': {'type': 'object'},
      }),
    },
  };

  setUp(() async {
    fake = FakeMcpHttp();
    await fake.start();
  });
  tearDown(() => fake.stop());

  test(
    'runs a pinned remote call and returns its structured envelope',
    () async {
      final result = await runMcpToolCall(request());
      expect(result['state'], 'completed');
      expect(
        (((result['result'] as Map)['content'] as List).first as Map)['text'],
        'json: hello',
      );
      expect(
        fake.seen.where((s) => s.body?['method'] == 'tools/call'),
        hasLength(1),
      );
    },
  );

  test('rejects missing or stale consent pins before a tool call', () async {
    final missing = request()..['toolPins'] = <String, String>{};
    expect((await runMcpToolCall(missing))['state'], 'rejected');
    final stale = request()..['toolPins'] = {'echo': 'a' * 64};
    expect((await runMcpToolCall(stale))['code'], 'definition_changed');
    expect(fake.seen.where((s) => s.body?['method'] == 'tools/call'), isEmpty);
  });

  test('Engine process accepts one call over stdin', () async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'bin/syntila_cli_worker.dart',
      mcpToolCallFlag,
    ]);
    process.stdin.writeln(jsonEncode(request()));
    await process.stdin.close();
    final lines = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    expect(await process.exitCode, 0);
    expect(lines, hasLength(1));
    expect((jsonDecode(lines.single) as Map)['state'], 'completed');
  });

  test('Engine accepts cancellation in the same input chunk', () async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'bin/syntila_cli_worker.dart',
      mcpToolCallFlag,
    ]);
    process.stdin.write('${jsonEncode(request())}\n{"cancel":true}\n');
    await process.stdin.flush();
    final lines = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    await process.stdin.close();
    expect(await process.exitCode, 0);
    final result = jsonDecode(lines.single) as Map;
    expect(result['state'], 'rejected');
    expect(result['code'], 'cancelled_before_dispatch');
    expect(fake.seen.where((s) => s.body?['method'] == 'tools/call'), isEmpty);
  });

  test('compiled Engine supervises a local pinned server', () async {
    final engine = (await PluginTestBinaries.ensure()).engine;
    final server = File(
      '../../packages/syntila_mcp_protocol/test/fixtures/echo_server.dart',
    ).absolute.path;
    final sha = await PluginHost().sha256OfFile(Platform.resolvedExecutable);
    final local = request()
      ..remove('remote')
      ..['server'] = {
        'name': 'echo',
        'command': Platform.resolvedExecutable,
        'arguments': [server, 'normal'],
      }
      ..['commandSha256'] = sha
      ..['workingDirectory'] = Directory.systemTemp.path
      ..['timeoutMs'] = 30000;
    final process = await Process.start(engine, [mcpToolCallFlag]);
    process.stdin.writeln(jsonEncode(local));
    await process.stdin.close();
    final lines = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    expect(await process.exitCode, 0);
    expect(lines, hasLength(1));
    final result = jsonDecode(lines.single) as Map;
    expect(result['state'], 'completed', reason: result.toString());
    expect(
      (((result['result'] as Map)['content'] as List).first as Map)['text'],
      'hello',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
