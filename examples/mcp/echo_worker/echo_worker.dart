// Reference Syntila MCP Worker (MCP_WORKER_PROFILE_V1.md): a stdio MCP server
// that advertises the Worker profile and implements syntila.execute and
// syntila.probe. Run with `dart echo_worker.dart [mode]`.
//
// Behaviour is driven by the prompt so tests can exercise every path:
//   FAIL      -> isError with issue code rate_limited
//   BADCODE   -> isError with an unknown issue code (normalised to internal)
//   SLOW      -> never answers (logs "cancelled:<id>" to stderr when cancelled)
//   BIGTEXT   -> output over the limit
//   BADART    -> an absolute artifact path
//   ART       -> a valid relative artifact
//   CRASH     -> exits abruptly
//   LEAK      -> isError whose message contains $SECRET_TOKEN (redaction)
//   anything  -> progress notification, then "echo: <prompt>"
// Mode `noexecute` omits syntila.execute; `badprobe` returns an unknown state;
// `badcheck` returns a probe check in the wrong shape.
import 'dart:convert';
import 'dart:io';

void send(Map<String, Object?> m) => stdout.writeln(jsonEncode(m));

Map<String, Object?> tool(String name) => {
  'name': name,
  'description': 'Syntila Worker tool $name',
  'inputSchema': {'type': 'object'},
};

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'normal' : args[0];
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final m = jsonDecode(line) as Map<String, Object?>;
    final id = m['id'];
    final params = (m['params'] as Map?)?.cast<String, Object?>() ?? {};
    switch (m['method']) {
      case 'initialize':
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': params['protocolVersion'],
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'echo-worker', 'version': '1'},
            '_meta': {'syntila.worker': '1'},
          },
        });
      case 'ping':
        send({'jsonrpc': '2.0', 'id': id, 'result': {}});
      case 'tools/list':
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'tools': [
              if (mode != 'noexecute') tool('syntila.execute'),
              tool('syntila.probe'),
            ],
          },
        });
      case 'notifications/cancelled':
        stderr.writeln('cancelled:${params['requestId']}');
      case 'tools/call':
        final name = params['name'];
        final a = (params['arguments'] as Map?)?.cast<String, Object?>() ?? {};
        if (name == 'syntila.probe') {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'content': [],
              'structuredContent': {
                'state': mode == 'badprobe' ? 'bogus' : 'ready',
                'checks': [
                  if (mode == 'badcheck')
                    {'name': 'echo', 'passed': true}
                  else
                    {
                      'code': 'echo',
                      'ok': true,
                      'message': 'echo worker ready',
                    },
                ],
              },
            },
          });
          break;
        }
        final prompt = '${a['prompt']}';
        if (prompt.contains('CRASH')) exit(3);
        if (prompt.contains('SLOW')) break;
        final meta = (params['_meta'] as Map?)?.cast<String, Object?>();
        if (meta != null) {
          send({
            'jsonrpc': '2.0',
            'method': 'notifications/progress',
            'params': {
              'progressToken': meta['progressToken'],
              'progress': 1,
              'total': 2,
              'message': 'working',
            },
          });
        }
        if (prompt.contains('LEAK')) {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'isError': true,
              'content': [],
              'structuredContent': {
                'issue': {
                  'code': 'internal',
                  'message':
                      'failed with ${Platform.environment['SECRET_TOKEN']}',
                },
              },
            },
          });
          break;
        }
        if (prompt.contains('FAIL') || prompt.contains('BADCODE')) {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'isError': true,
              'content': [],
              'structuredContent': {
                'issue': {
                  'code': prompt.contains('FAIL') ? 'rate_limited' : 'weird',
                  'message': 'worker said no',
                },
              },
            },
          });
          break;
        }
        final text = prompt.contains('BIGTEXT')
            ? 'x' * (900 * 1024)
            : 'echo: $prompt | access: ${a['access']} | model: ${a['model']}';
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'content': [
              {'type': 'text', 'text': text},
            ],
            'structuredContent': {
              'text': text,
              if (prompt.contains('ART')) 'artifacts': ['out/report.md'],
              if (prompt.contains('BADART')) 'artifacts': ['/etc/passwd'],
              'session': {'key': 'echo-session-1'},
            },
          },
        });
    }
  }
}
