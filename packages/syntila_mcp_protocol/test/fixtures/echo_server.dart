// Reference MCP server for client tests. Mode is argv[0]:
//   normal | badversion | crash | huge | sampling
import 'dart:async';
import 'dart:convert';
import 'dart:io';

void send(Map<String, Object?> m) => stdout.writeln(jsonEncode(m));

Map<String, Object?> tool(String name, String desc) => {
      'name': name,
      'description': desc,
      'inputSchema': {'type': 'object'},
    };

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'normal' : args[0];
  var toolDesc = 'echoes';
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final m = jsonDecode(line) as Map<String, Object?>;
    final id = m['id'];
    final method = m['method'];
    final params = (m['params'] as Map?)?.cast<String, Object?>() ?? {};
    switch (method) {
      case 'initialize':
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion':
                mode == 'badversion' ? '1999-01-01' : params['protocolVersion'],
            'capabilities': {
              'tools': {'listChanged': true}
            },
            'serverInfo': {'name': 'echo', 'version': '1'},
            '_meta': {'syntila.worker': '1'},
          },
        });
      case 'ping':
        send({'jsonrpc': '2.0', 'id': id, 'result': {}});
      case 'tools/list':
        final cursor = params['cursor'];
        if (cursor == null) {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'tools': [tool('echo', toolDesc)],
              'nextCursor': 'page2',
            },
          });
        } else {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'tools': [tool('slow', 'waits')]
            },
          });
        }
      case 'tools/call':
        final name = params['name'];
        if (mode == 'crash') exit(3);
        if (mode == 'sampling') {
          send({
            'jsonrpc': '2.0',
            'id': 'srv1',
            'method': 'sampling/createMessage',
            'params': {}
          });
        }
        if (name == 'slow') {
          // Never answers; the client must cancel/time out.
          break;
        }
        final meta = (params['_meta'] as Map?)?.cast<String, Object?>();
        if (meta != null) {
          send({
            'jsonrpc': '2.0',
            'method': 'notifications/progress',
            'params': {
              'progressToken': meta['progressToken'],
              'progress': 1,
              'total': 2,
              'message': 'half'
            },
          });
        }
        final args2 = params['arguments'] as Map? ?? {};
        final text =
            mode == 'huge' ? 'x' * (2 * 1024 * 1024) : '${args2['text']}';
        send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'content': [
              {'type': 'text', 'text': text}
            ]
          },
        });
      case 'notifications/cancelled':
        stderr.writeln('cancelled:${params['requestId']}');
      case 'test/mutate':
        toolDesc = 'changed';
        send({'jsonrpc': '2.0', 'method': 'notifications/tools/list_changed'});
    }
  }
}
