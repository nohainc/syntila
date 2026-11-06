import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  bool toolError = false;
  bool outputSchema = false;
  bool malformedResult = false;
  Completer<void>? callGate;
  Completer<void>? listGate;
  bool expireSession = false;
  bool worker = false; // behave as a Syntila MCP Worker
  String toolDescription = 'echoes';
  bool leakToken = false; // make errors echo the bearer token
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
          if (worker) '_meta': {'syntila.worker': '1'},
        });
      case 'tools/list':
        if (listGate case final gate?) await gate.future;
        await json({
          'tools': [
            for (final name
                in worker ? ['syntila.execute', 'syntila.probe'] : ['echo'])
              {
                'name': name,
                'description': toolDescription,
                'inputSchema': {'type': 'object'},
                if (outputSchema) 'outputSchema': {'type': 'object'},
              },
          ],
        });
      case 'tools/call':
        if (callGate case final gate?) await gate.future;
        if (params['name'] == 'syntila.probe') {
          await json({
            'content': [],
            'structuredContent': {
              'state': 'ready',
              'checks': [
                {'code': 'remote', 'ok': true, 'message': 'remote reachable'},
              ],
            },
          });
        } else if (leakToken) {
          await json({
            'isError': true,
            'content': [],
            'structuredContent': {
              'issue': {
                'code': 'internal',
                'message':
                    'rejected token ${request.headers.value('authorization')}',
              },
            },
          });
        } else if (params['name'] == 'syntila.execute') {
          final prompt = (params['arguments'] as Map)['prompt'];
          await json({
            'content': [],
            'structuredContent': {'text': 'remote echo: $prompt'},
          });
        } else if (failCalls) {
          response.statusCode = 500;
          await response.close();
        } else if (malformedResult) {
          await json({});
        } else if (toolError) {
          await json({
            'isError': true,
            'content': [
              {'type': 'text', 'text': 'tool failed'},
            ],
          });
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
