import 'dart:convert';
import 'dart:io';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:test/test.dart';

class _ProcessTransport implements McpTransport {
  _ProcessTransport(this.process)
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

Future<(McpClient, _ProcessTransport)> start(
    String fixture, String mode) async {
  final p = await Process.start(Platform.resolvedExecutable,
      ['run', 'test/fixtures/$fixture.dart', mode]);
  final t = _ProcessTransport(p);
  final c = McpClient(t);
  addTearDown(c.close);
  return (c, t);
}

Matcher _failure(String code) =>
    isA<McpException>().having((e) => e.code, 'code', code);

void main() {
  group('version families', () {
    test('modern and legacy revisions are distinct and ordered', () {
      expect(McpLimits.modernProtocolVersions, ['2026-07-28']);
      expect(McpLimits.legacyProtocolVersions,
          ['2025-06-18', '2025-03-26', '2024-11-05']);
      expect(McpLimits.supportedProtocolVersions.first, '2026-07-28');
    });

    test('initialize alone never accepts a stateless version', () async {
      final (c, _) = await start('echo_server', 'normal');
      // The legacy handshake proposes a legacy revision.
      await c.initialize();
      expect(c.isModern, isFalse);
      expect(McpLimits.legacyProtocolVersions, contains(c.negotiatedVersion));
    });
  });

  group('every supported revision', () {
    for (final version in McpLimits.legacyProtocolVersions) {
      test('handshake server answering $version works', () async {
        final (c, _) = await start('echo_server', 'version=$version');
        await c.connect();
        expect(c.negotiatedVersion, version);
        expect(c.isModern, isFalse);
        expect((await c.listTools()).first['name'], 'echo');
        final res = await c.callTool('echo', {'text': version}).result;
        expect((res['content'] as List).single['text'], version);
      });
    }

    for (final version in McpLimits.modernProtocolVersions) {
      test('stateless server on $version works', () async {
        final (c, _) = await start('modern_server', 'normal');
        await c.connect();
        expect(c.negotiatedVersion, version);
        expect(c.isModern, isTrue);
      });
    }

    test('a stateless revision is never accepted by the handshake', () async {
      final (c, _) = await start('echo_server', 'version=2026-07-28');
      await expectLater(
          c.initialize(), throwsA(_failure(McpFailure.versionUnsupported)));
    });
  });

  group('stateless (2026-07-28)', () {
    test('discovers, lists and calls with per-request metadata', () async {
      final (c, t) = await start('modern_server', 'normal');
      await c.connect();
      expect(c.isModern, isTrue);
      expect(c.negotiatedVersion, '2026-07-28');
      expect(c.serverInfo['name'], 'modern');
      expect(c.initializeMeta['syntila.worker'], '1');
      expect(c.serverCapabilities, containsPair('tools', isA<Map>()));
      expect((await c.listTools()).map((x) => x['name']), ['echo', 'headered']);
      final seen = <String?>[];
      final res = await c
          .callTool('echo', {'text': 'hi'},
              onProgress: (p, tot, m) => seen.add(m))
          .result;
      expect((res['content'] as List).single['text'], 'hi');
      // Version, capabilities, client identity and the progress token travel
      // with the request itself.
      expect(res['echoedMeta'], [
        'io.modelcontextprotocol/clientCapabilities',
        'io.modelcontextprotocol/clientInfo',
        'io.modelcontextprotocol/protocolVersion',
        'progressToken',
      ]);
      // resultType is consumed by the client, never passed downstream.
      expect(res.containsKey('resultType'), isFalse);
      expect(t.stderrText.join(), isNot(contains('initialize-seen')));
    });

    test('ping does nothing: it does not exist in stateless revisions',
        () async {
      final (c, _) = await start('modern_server', 'normal');
      await c.connect();
      await c.ping();
    });

    test('input_required fails with a stable diagnostic', () async {
      final (c, _) = await start('modern_server', 'input_required');
      await c.connect();
      await expectLater(c.callTool('echo', {}).result,
          throwsA(_failure(McpFailure.interactionRequired)));
    });

    test('an unknown resultType is a protocol violation', () async {
      final (c, _) = await start('modern_server', 'badtype');
      await expectLater(
          c.connect(), throwsA(_failure(McpFailure.protocolViolation)));
    });

    test('a stateless-only mode refuses a handshake server', () async {
      final (c, _) = await start('echo_server', 'normal');
      await expectLater(c.connect(mode: McpProtocolMode.modern),
          throwsA(_failure(McpFailure.versionUnsupported)));
    });

    test('legacy mode never sends discover', () async {
      final (c, _) = await start('modern_server', 'normal');
      // The stateless server has no initialize, so legacy mode fails; the point
      // is that it did not try discover first.
      await expectLater(c.connect(mode: McpProtocolMode.legacy),
          throwsA(isA<McpException>()));
    });

    test('a server with no common version fails, with no downgrade', () async {
      final (c, t) = await start('modern_server', 'versions');
      await expectLater(
          c.connect(), throwsA(_failure(McpFailure.versionUnsupported)));
      expect(t.stderrText.join(), isNot(contains('initialize-seen')));
    });

    test('a recognized modern error never falls back to initialize', () async {
      final (c, t) = await start('modern_server', 'unsupported');
      await expectLater(
          c.connect(),
          throwsA(isA<McpException>()
              .having((e) => e.code, 'code', McpFailure.versionUnsupported)
              .having((e) => e.message, 'message', contains('2030-01-01'))));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(t.stderrText.join(), isNot(contains('initialize-seen')));
    });
  });

  group('auto negotiation with a handshake server', () {
    test('method-not-found on discover falls back to initialize', () async {
      final (c, _) = await start('echo_server', 'normal');
      await c.connect();
      expect(c.isModern, isFalse);
      expect(McpLimits.legacyProtocolVersions, contains(c.negotiatedVersion));
      expect((await c.listTools()).first['name'], 'echo');
      await c.ping();
      final res = await c.callTool('echo', {'text': 'ok'}).result;
      expect((res['content'] as List).single['text'], 'ok');
    });

    test('a bad legacy version is still rejected', () async {
      final (c, _) = await start('echo_server', 'badversion');
      await expectLater(
          c.connect(), throwsA(_failure(McpFailure.versionUnsupported)));
    });
  });

  group('tool definition pinning', () {
    test('legacy and stateless definitions hash identically', () {
      const legacy = {
        'name': 'echo',
        'description': 'echoes',
        'inputSchema': {'type': 'object'},
      };
      final modern = {
        ...legacy,
        'title': 'Echo',
        'icons': [
          {'src': 'x'}
        ],
        'execution': {'taskSupport': 'optional'},
        '_meta': {'a': 1},
      };
      expect(toolDefinitionHash(modern), toolDefinitionHash(legacy));
    });

    test('golden vectors are stable (existing consent pins stay valid)', () {
      expect(
          toolDefinitionHash({
            'name': 'echo',
            'description': 'echoes',
            'inputSchema': {'type': 'object'},
          }),
          '607036ef8216f8319e330907f2dd25592d2cedcafad97ca43b9dc514c272b06d');
      expect(
          toolDefinitionHash({
            'annotations': {'readOnlyHint': true},
            'outputSchema': {'type': 'object'},
            'inputSchema': {
              'required': ['a'],
              'properties': {
                'b': {'type': 'string'},
                'a': {'minimum': 1, 'type': 'integer'},
              },
              'type': 'object',
            },
            'description': 'ü "q"\n',
            'name': 'é',
          }),
          '7f3d24199a43f822fb77032130031e0ac2960f9d4ed96155a79f3bb25f186ba4');
    });

    test('a schema keyword change (x-mcp-header) changes the hash', () {
      Map<String, Object?> def(Object? extra) => {
            'name': 't',
            'inputSchema': {
              'type': 'object',
              'properties': {
                'r': {'type': 'string', ...?(extra as Map<String, Object?>?)},
              },
            },
          };
      expect(toolDefinitionHash(def(null)),
          isNot(toolDefinitionHash(def({'x-mcp-header': 'Region'}))));
    });
  });
}
