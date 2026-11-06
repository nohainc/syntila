@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/mcp_http_transport.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:test/test.dart';

class Seen {
  Seen(this.method, this.headers, this.body);
  final String method;
  final Map<String, String> headers;
  final Map<String, Object?>? body;
}

/// A scriptable MCP server over Streamable HTTP.
class FakeMcpHttp {
  late HttpServer server;
  String callStyle = 'json'; // json | sse
  String? requiredToken;
  bool bigReply = false;
  bool failCalls = false;
  bool expireSession = false;
  final seen = <Seen>[];

  Uri get endpoint => Uri.parse('http://127.0.0.1:${server.port}/mcp');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(','));
    final response = request.response;
    final raw = await utf8.decoder.bind(request).join();
    final body = raw.isEmpty ? null : jsonDecode(raw) as Map<String, Object?>;
    seen.add(Seen(request.method, headers, body));
    if (requiredToken != null &&
        request.headers.value('authorization') != 'Bearer $requiredToken') {
      response.statusCode = 401;
      await response.close();
      return;
    }
    if (request.method == 'DELETE') {
      await response.close();
      return;
    }
    if (expireSession && body?['method'] != 'initialize') {
      response.statusCode = 404;
      await response.close();
      return;
    }
    final method = body?['method'];
    final id = body?['id'];
    final params = (body?['params'] as Map?)?.cast<String, Object?>() ?? {};
    if (id == null) {
      response.statusCode = 202; // notification
      await response.close();
      return;
    }
    Future<void> json(Object? result) async {
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
      );
      await response.close();
    }

    switch (method) {
      case 'initialize':
        response.headers.set('Mcp-Session-Id', 'sess-1');
        await json({
          'protocolVersion': params['protocolVersion'],
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'fake', 'version': '1'},
        });
      case 'tools/list':
        await json({
          'tools': [
            {
              'name': 'echo',
              'description': 'echoes',
              'inputSchema': {'type': 'object'},
            },
          ],
        });
      case 'tools/call':
        if (failCalls) {
          response.statusCode = 500;
          await response.close();
        } else if (bigReply) {
          await json({
            'content': [
              {'type': 'text', 'text': 'x' * (5 * 1024 * 1024)},
            ],
          });
        } else if (callStyle == 'sse') {
          response.headers.contentType = ContentType('text', 'event-stream');
          final token = (params['_meta'] as Map?)?['progressToken'];
          response.write(': keep-alive comment\n\n');
          response.write(
            'event: message\ndata: ${jsonEncode({
              'jsonrpc': '2.0',
              'method': 'notifications/progress',
              'params': {'progressToken': token, 'progress': 1, 'message': 'half'},
            })}\n\n',
          );
          await response.flush();
          response.write(
            'data: ${jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'content': [
                  {'type': 'text', 'text': 'sse: ${(params['arguments'] as Map)['text']}'},
                ],
              },
            })}\n\n',
          );
          await response.close();
        } else {
          await json({
            'content': [
              {
                'type': 'text',
                'text': 'json: ${(params['arguments'] as Map)['text']}',
              },
            ],
          });
        }
      default:
        await json({});
    }
  }

  Future<void> stop() => server.close(force: true);
}

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
