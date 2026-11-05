import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:test/test.dart';

class ProcessTransport implements McpTransport {
  ProcessTransport(this.process)
      : lines = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream() {
    process.stderr.transform(utf8.decoder).listen(stderrText.add);
  }
  final Process process;
  final stderrText = <String>[];
  @override
  final Stream<String> lines;
  @override
  void send(String line) => process.stdin.writeln(line);
  @override
  Future<void> close() async {
    process.kill();
    await process.exitCode;
  }
}

Future<McpClient> start(String mode) async {
  final p = await Process.start(Platform.resolvedExecutable,
      ['run', 'test/fixtures/echo_server.dart', mode]);
  return McpClient(ProcessTransport(p));
}

void main() {
  test('negotiates version and reads server metadata', () async {
    final c = await start('normal');
    addTearDown(c.close);
    await c.initialize();
    expect(McpLimits.supportedProtocolVersions, contains(c.negotiatedVersion));
    expect(c.initializeMeta['syntila.worker'], '1');
    expect(c.serverInfo['name'], 'echo');
  });

  test('rejects an unsupported server protocol version', () async {
    final c = await start('badversion');
    await expectLater(
        c.initialize(),
        throwsA(isA<McpException>()
            .having((e) => e.code, 'code', McpFailure.versionUnsupported)));
  });

  test('lists tools across pages and calls with progress', () async {
    final c = await start('normal');
    addTearDown(c.close);
    await c.initialize();
    final tools = await c.listTools();
    expect(tools.map((t) => t['name']), ['echo', 'slow']);
    final seen = <String?>[];
    final res = await c
        .callTool('echo', {'text': 'hi'}, onProgress: (p, t, m) => seen.add(m))
        .result;
    expect((res['content'] as List).first['text'], 'hi');
    expect(seen, ['half']);
  });

  test('timeout sends notifications/cancelled and fails with mcp_timeout',
      () async {
    final p = await Process.start(Platform.resolvedExecutable,
        ['run', 'test/fixtures/echo_server.dart', 'normal']);
    final transport = ProcessTransport(p);
    final c = McpClient(transport);
    addTearDown(c.close);
    await c.initialize();
    final call =
        c.callTool('slow', {}, timeout: const Duration(milliseconds: 300));
    await expectLater(
        call.result,
        throwsA(isA<McpException>()
            .having((e) => e.code, 'code', McpFailure.timeout)));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(transport.stderrText.join(), contains('cancelled:'));
  });

  test('server crash fails the pending call with mcp_server_crashed', () async {
    final c = await start('crash');
    addTearDown(c.close);
    await c.initialize();
    await expectLater(
        c.callTool('echo', {}).result,
        throwsA(isA<McpException>()
            .having((e) => e.code, 'code', McpFailure.serverCrashed)));
  });

  test('oversize result is rejected', () async {
    final c = await start('huge');
    addTearDown(c.close);
    await c.initialize();
    await expectLater(
        c.callTool('echo', {}).result,
        throwsA(isA<McpException>().having((e) => e.code, 'code',
            anyOf(McpFailure.resultTooLarge, McpFailure.protocolViolation))));
  });

  test('refuses server-initiated sampling and records it', () async {
    final c = await start('sampling');
    addTearDown(c.close);
    await c.initialize();
    await c.callTool('echo', {'text': 'ok'}).result;
    expect(c.unsupportedRequests, ['sampling/createMessage']);
  });

  group('ToolPins', () {
    Map<String, Object?> t(String n, String d) => {
          'name': n,
          'description': d,
          'inputSchema': {'type': 'object'},
        };

    test('hash ignores cosmetic fields and key order', () {
      final a = {
        ...t('x', 'd'),
        'title': 'Pretty',
        '_meta': {'a': 1}
      };
      final b = {
        'inputSchema': {'type': 'object'},
        'description': 'd',
        'name': 'x',
      };
      expect(toolDefinitionHash(a), toolDefinitionHash(b));
    });

    test('changed description blocks the tool; unchanged stays allowed', () {
      final pins = ToolPins.fromTools([t('a', '1'), t('b', '1')]);
      final now = [t('a', 'EVIL'), t('b', '1')];
      final d = pins.diff(now);
      expect(d.changed, ['a']);
      expect(d.blocksCalls, isTrue);
      expect(pins.allows('a', now), isFalse);
      expect(pins.allows('b', now), isTrue);
    });

    test('added tools are not callable until consented', () {
      final pins = ToolPins.fromTools([t('a', '1')]);
      final now = [t('a', '1'), t('new', 'x')];
      expect(pins.diff(now).added, ['new']);
      expect(pins.allows('new', now), isFalse);
    });

    test('removed tools are reported without blocking', () {
      final pins = ToolPins.fromTools([t('a', '1'), t('b', '1')]);
      final d = pins.diff([t('a', '1')]);
      expect(d.removed, ['b']);
      expect(d.blocksCalls, isFalse);
    });
  });

  group('codec', () {
    test('rejects oversize and malformed frames', () {
      expect(() => decodeMessage('x' * (McpLimits.maxFrameBytes + 1)),
          throwsA(isA<McpException>()));
      expect(() => decodeMessage('not json'), throwsA(isA<McpException>()));
      expect(() => decodeMessage('{"id":1}'), throwsA(isA<McpException>()));
    });

    test('classifies messages', () {
      expect(decodeMessage('{"jsonrpc":"2.0","id":1,"method":"ping"}'),
          isA<JsonRpcRequest>());
      expect(decodeMessage('{"jsonrpc":"2.0","method":"x"}'),
          isA<JsonRpcNotification>());
      expect(decodeMessage('{"jsonrpc":"2.0","id":1,"result":{}}'),
          isA<JsonRpcResponse>());
      expect(
          decodeMessage(
              '{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"m"}}'),
          isA<JsonRpcError>());
    });
  });
}
