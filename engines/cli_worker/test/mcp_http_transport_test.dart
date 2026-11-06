@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/mcp_http_transport.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:test/test.dart';

import 'support/fake_mcp_http.dart';

void main() {
  late FakeMcpHttp fake;
  late List<McpClient> clients;

  McpClient connect({String? token, Duration? timeout}) {
    final client = McpClient(
      StreamableHttpTransport(
        endpoint: fake.endpoint,
        allowInsecureLoopback: true,
        headers: {if (token != null) 'Authorization': 'Bearer $token'},
        requestTimeout: timeout ?? const Duration(seconds: 30),
      ),
    );
    clients.add(client);
    return client;
  }

  setUp(() async {
    fake = FakeMcpHttp();
    await fake.start();
    clients = [];
  });
  tearDown(() async {
    for (final c in clients) {
      await c.close();
    }
    await fake.stop();
  });

  test('initialize, list and call over plain JSON replies', () async {
    final client = connect();
    await client.initialize();
    expect(client.negotiatedVersion, isNotNull);
    expect((await client.listTools()).single['name'], 'echo');
    final result = await client.callTool('echo', {'text': 'hi'}).result;
    expect((result['content'] as List).first['text'], 'json: hi');
  });

  test('an SSE reply delivers progress and then the result', () async {
    fake.callStyle = 'sse';
    final client = connect();
    await client.initialize();
    final progress = <String?>[];
    final result = await client.callTool('echo', {
      'text': 'hi',
    }, onProgress: (p, t, m) => progress.add(m)).result;
    expect((result['content'] as List).first['text'], 'sse: hi');
    expect(progress, ['half']);
  });

  test('session and protocol-version headers follow the handshake', () async {
    final client = connect();
    await client.initialize();
    await client.listTools();
    final first = fake.seen.first;
    expect(first.headers['accept'], contains('application/json'));
    expect(first.headers['accept'], contains('text/event-stream'));
    expect(first.headers.containsKey('mcp-session-id'), isFalse);
    final later = fake.seen.last;
    expect(later.headers['mcp-session-id'], 'sess-1');
    expect(later.headers['mcp-protocol-version'], client.negotiatedVersion);
  });

  test('notifications are posted and accepted without a body', () async {
    final client = connect();
    await client.initialize();
    // The notification is posted right after initialize() returns.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      fake.seen.any((s) => s.body?['method'] == 'notifications/initialized'),
      isTrue,
    );
  });

  test('a wrong or missing token is an authentication failure', () async {
    fake.requiredToken = 'secret-token';
    final bad = connect(token: 'wrong');
    await expectLater(
      bad.initialize(),
      throwsA(
        isA<McpException>().having(
          (e) => e.code,
          'code',
          McpFailure.authRequired,
        ),
      ),
    );
    final good = connect(token: 'secret-token');
    await good.initialize();
    expect((await good.listTools()).single['name'], 'echo');
  });

  test('the token never appears in errors or the endpoint', () async {
    fake.requiredToken = 'secret-token';
    final bad = connect(token: 'leaky-value-123');
    try {
      await bad.initialize();
    } on McpException catch (error) {
      expect('$error', isNot(contains('leaky-value-123')));
    }
  });

  test('https is required; plain http only for loopback and by opt-in', () {
    expect(
      () => StreamableHttpTransport(
        endpoint: Uri.parse('http://example.com/mcp'),
      ),
      throwsA(isA<McpException>()),
    );
    expect(
      () => StreamableHttpTransport(
        endpoint: Uri.parse('http://example.com/mcp'),
        allowInsecureLoopback: true,
      ),
      throwsA(isA<McpException>()),
    );
    expect(
      () => StreamableHttpTransport(
        endpoint: Uri.parse('http://127.0.0.1:1/mcp'),
      ),
      throwsA(isA<McpException>()),
    );
    StreamableHttpTransport(
      endpoint: Uri.parse('http://127.0.0.1:1/mcp'),
      allowInsecureLoopback: true,
    ).close();
    StreamableHttpTransport(
      endpoint: Uri.parse('https://example.com/mcp'),
    ).close();
    expect(
      () => StreamableHttpTransport(
        endpoint: Uri.parse('https://user:pass@example.com/mcp'),
      ),
      throwsA(isA<McpException>()),
    );
  });

  test(
    'an oversize reply fails the call instead of exhausting memory',
    () async {
      fake.bigReply = true;
      final client = connect();
      await client.initialize();
      await expectLater(
        client.callTool('echo', {'text': 'x'}).result,
        throwsA(isA<McpException>()),
      );
    },
  );

  test('a server error fails the call promptly', () async {
    fake.failCalls = true;
    final client = connect();
    await client.initialize();
    final clock = Stopwatch()..start();
    await expectLater(
      client.callTool('echo', {'text': 'x'}).result,
      throwsA(isA<McpException>()),
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('an expired session is reported', () async {
    final client = connect();
    await client.initialize();
    fake.expireSession = true;
    await expectLater(client.listTools(), throwsA(isA<McpException>()));
  });

  test('an unreachable server fails fast', () async {
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close(force: true);
    final client = McpClient(
      StreamableHttpTransport(
        endpoint: Uri.parse('http://127.0.0.1:$port/mcp'),
        allowInsecureLoopback: true,
      ),
    );
    clients.add(client);
    await expectLater(client.initialize(), throwsA(isA<McpException>()));
  });

  test('closing ends the server session with a DELETE', () async {
    final client = connect();
    await client.initialize();
    await client.close();
    expect(fake.seen.last.method, 'DELETE');
    expect(fake.seen.last.headers['mcp-session-id'], 'sess-1');
  });

  test('a cancelled call posts notifications/cancelled', () async {
    final client = connect();
    await client.initialize();
    final call = client.callTool('echo', {'text': 'x'});
    call.cancel();
    await call.result.then((_) {}, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      fake.seen.any((s) => s.body?['method'] == 'notifications/cancelled'),
      isTrue,
    );
  });

  group('stateless 2026-07-28 over HTTP', () {
    test('discovers and calls with routing headers and no session', () async {
      fake.modern = true;
      fake.worker = true;
      final client = connect();
      await client.connect();
      expect(client.isModern, isTrue);
      expect(client.initializeMeta['syntila.worker'], '1');
      await client.listTools();
      final result = await client.callTool('syntila.probe', {}).result;
      expect(result.containsKey('resultType'), isFalse);
      await client.close();

      final posts = fake.seen.where((s) => s.method == 'POST').toList();
      expect(posts.map((s) => s.body?['method']), [
        'server/discover',
        'tools/list',
        'tools/call',
      ]);
      for (final post in posts) {
        expect(post.headers['mcp-protocol-version'], '2026-07-28');
        expect(post.headers['mcp-method'], post.body?['method']);
        expect(post.headers.containsKey('mcp-session-id'), isFalse);
      }
      expect(posts.last.headers['mcp-name'], 'syntila.probe');
      expect(posts.first.headers.containsKey('mcp-name'), isFalse);
      // No handshake, no initialized notification, no session DELETE.
      expect(fake.seen.any((s) => s.method == 'DELETE'), isFalse);
      expect(fake.seen.any((s) => s.body?['method'] == 'initialize'), isFalse);
    });

    test('a server session id is ignored, never stored or echoed', () async {
      fake.modern = true;
      final client = connect();
      await client.connect();
      await client.listTools();
      await client.close();
      expect(
        fake.seen.any((s) => s.headers.containsKey('mcp-session-id')),
        isFalse,
      );
    });

    test(
      'a cancelled stateless call aborts the stream, no cancel POST',
      () async {
        fake.modern = true;
        fake.callGate = Completer<void>();
        final client = connect();
        await client.connect();
        final call = client.callTool('echo', {'text': 'x'});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        call.result.ignore();
        call.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          fake.seen.any((s) => s.body?['method'] == 'notifications/cancelled'),
          isFalse,
        );
        fake.callGate!.complete();
      },
    );

    test('an unsupported version surfaces the modern 400 error', () async {
      fake.modern = true;
      fake.discoverVersions = ['2030-01-01'];
      final client = connect();
      await expectLater(
        client.connect(),
        throwsA(
          isA<McpException>()
              .having((e) => e.code, 'code', McpFailure.versionUnsupported)
              .having((e) => e.jsonRpcCode, 'rpc', -32022),
        ),
      );
      // No silent downgrade: the handshake is never attempted.
      expect(fake.seen.any((s) => s.body?['method'] == 'initialize'), isFalse);
    });

    test(
      'tools with x-mcp-header parameters are refused, not mis-sent',
      () async {
        fake.modern = true;
        fake.customInputSchema = {
          'type': 'object',
          'properties': {
            'region': {'type': 'string', 'x-mcp-header': 'Region'},
          },
        };
        final client = connect();
        await client.connect();
        await client.listTools();
        expect(
          () => client.callTool('echo', {'region': 'eu'}),
          throwsA(
            isA<McpException>().having(
              (e) => e.code,
              'code',
              McpFailure.unsupportedFeature,
            ),
          ),
        );
        expect(
          fake.seen.any((s) => s.body?['method'] == 'tools/call'),
          isFalse,
        );
      },
    );

    test('routing header values are encoded safely', () {
      expect(
        StreamableHttpTransport.encodeHeaderValue('get_weather'),
        'get_weather',
      );
      expect(StreamableHttpTransport.encodeHeaderValue('my tool'), 'my tool');
      expect(
        StreamableHttpTransport.encodeHeaderValue('naïve'),
        '=?base64?bmHDr3Zl?=',
      );
      expect(
        StreamableHttpTransport.encodeHeaderValue(' lead'),
        '=?base64?IGxlYWQ=?=',
      );
      expect(
        StreamableHttpTransport.encodeHeaderValue('a\r\nb'),
        startsWith('=?base64?'),
      );
      expect(
        StreamableHttpTransport.encodeHeaderValue('=?base64?x?='),
        startsWith('=?base64?PT9'),
      );
    });
  });

  group('auto negotiation against handshake servers', () {
    test(
      'method-not-found on discover falls back; sessions still apply',
      () async {
        final client = connect();
        await client.connect();
        expect(client.isModern, isFalse);
        await client.listTools();
        await client.close();
        final discover = fake.seen.firstWhere(
          (s) => s.body?['method'] == 'server/discover',
        );
        expect(discover.headers['mcp-method'], 'server/discover');
        // Legacy behavior after the handshake: session header and DELETE.
        final list = fake.seen.firstWhere(
          (s) => s.body?['method'] == 'tools/list',
        );
        expect(list.headers['mcp-session-id'], 'sess-1');
        expect(list.headers.containsKey('mcp-method'), isFalse);
        expect(fake.seen.last.method, 'DELETE');
      },
    );

    test('an empty HTTP 400 on discover falls back to initialize', () async {
      fake.discoverFailure = 'empty400';
      final client = connect();
      await client.connect();
      expect(client.isModern, isFalse);
      expect((await client.listTools()).single['name'], 'echo');
    });

    test('an empty success on discover is not a modern reply', () async {
      fake.discoverFailure = 'emptyok';
      final client = connect();
      await client.connect();
      expect(client.isModern, isFalse);
      expect((await client.listTools()).single['name'], 'echo');
    });

    test('a silent server falls back after the discover timeout', () async {
      fake.discoverFailure = 'silent';
      final client = connect();
      await client.connect(timeout: const Duration(milliseconds: 300));
      expect(client.isModern, isFalse);
    });

    test('a modern -32022 body from a dual server never downgrades', () async {
      fake.discoverFailure = 'unsupported';
      final client = connect();
      await expectLater(
        client.connect(),
        throwsA(
          isA<McpException>().having(
            (e) => e.code,
            'code',
            McpFailure.versionUnsupported,
          ),
        ),
      );
      expect(fake.seen.any((s) => s.body?['method'] == 'initialize'), isFalse);
    });
  });
}
