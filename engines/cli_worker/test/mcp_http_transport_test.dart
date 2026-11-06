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
}
