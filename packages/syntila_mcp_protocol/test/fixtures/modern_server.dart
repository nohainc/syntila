// Reference stateless (2026-07-28) MCP server over stdio. Mode is argv[0]:
//   normal | input_required | badtype | versions | unsupported
// It has no `initialize`: every request must carry its protocol version and
// client capabilities in `_meta`.
import 'dart:convert';
import 'dart:io';

const metaVersion = 'io.modelcontextprotocol/protocolVersion';

void send(Map<String, Object?> m) => stdout.writeln(jsonEncode(m));

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'normal' : args[0];
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final m = jsonDecode(line) as Map<String, Object?>;
    final id = m['id'];
    final method = m['method'];
    final params = (m['params'] as Map?)?.cast<String, Object?>() ?? {};
    final meta = (params['_meta'] as Map?)?.cast<String, Object?>() ?? {};
    if (id == null) continue;
    void error(int code, String message, [Object? data]) => send({
          'jsonrpc': '2.0',
          'id': id,
          'error': {
            'code': code,
            'message': message,
            if (data != null) 'data': data,
          },
        });
    void result(Map<String, Object?> r) => send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'resultType': mode == 'badtype' ? 'task' : 'complete',
            ...r
          },
        });
    if (method == 'initialize') stderr.writeln('initialize-seen');
    if (method == 'initialize' || method == 'ping') {
      // Removed in stateless revisions.
      error(-32601, 'Method not found');
      continue;
    }
    final version = meta[metaVersion];
    if (version == null) {
      error(-32602, 'Missing required _meta');
      continue;
    }
    if (version != '2026-07-28') {
      error(-32022, 'Unsupported protocol version', {
        'supported': ['2026-07-28'],
        'requested': version,
      });
      continue;
    }
    switch (method) {
      case 'server/discover' when mode == 'unsupported':
        error(-32022, 'Unsupported protocol version', {
          'supported': ['2030-01-01', '2025-06-18'],
          'requested': version,
        });
      case 'server/discover':
        result({
          'supportedVersions':
              mode == 'versions' ? ['2030-01-01'] : ['2026-07-28'],
          'capabilities': {'tools': {}},
          '_meta': {
            'io.modelcontextprotocol/serverInfo': {
              'name': 'modern',
              'version': '1'
            },
            'syntila.worker': '1',
          },
        });
      case 'tools/list':
        result({
          'tools': [
            {
              'name': 'echo',
              'description': 'echoes',
              'inputSchema': {'type': 'object'},
            },
            {
              'name': 'headered',
              'description': 'needs a routing header',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'region': {'type': 'string', 'x-mcp-header': 'Region'},
                },
              },
            },
          ],
        });
      case 'tools/call':
        if (mode == 'input_required') {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'resultType': 'input_required',
              'inputRequests': {
                'q': {'method': 'elicitation/create', 'params': {}},
              },
              'requestState': 'opaque',
            },
          });
        } else {
          result({
            'content': [
              {
                'type': 'text',
                'text': '${(params['arguments'] as Map?)?['text']}'
              }
            ],
            'echoedMeta': meta.keys.toList()..sort(),
          });
        }
      default:
        error(-32601, 'Method not found');
    }
  }
}
