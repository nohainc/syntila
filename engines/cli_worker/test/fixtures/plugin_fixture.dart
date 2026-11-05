// Test-only Worker plugin. `--fault=NAME` selects a misbehavior; with no
// fault it is a well-behaved echo plugin. Never documented as an example.
import 'dart:convert';
import 'dart:io';

import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';

void send(Map<String, Object?> json) => stdout.writeln(jsonEncode(json));

Future<void> main(List<String> args) async {
  final fault = args
      .firstWhere((a) => a.startsWith('--fault='), orElse: () => '--fault=')
      .substring('--fault='.length);
  File('${Directory.current.path}/plugin.pid').writeAsStringSync('$pid');
  String? dataDirectory;
  if (fault == 'noise') stdout.writeln('starting up...');

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final PluginFrame frame;
    try {
      frame = decodePluginFrame(line, PluginDirection.hostToPlugin);
    } on PluginFrameException {
      send({
        'type': 'error',
        'code': 'unsupported_frame',
        'message': '',
        'retryable': false,
      });
      continue;
    }
    switch (frame.type) {
      case 'hello':
        dataDirectory = frame.json['dataDir'] as String;
        send({
          'type': 'hello.result',
          'id': frame.id,
          'protocol': fault == 'large'
              ? '1.2'
              : const {'discovery', 'checkpoint'}.contains(fault)
              ? '1.1'
              : '1.0',
          'plugin': {
            'id': fault == 'bad-identity' ? 'someone-else' : 'fixture-plugin',
            'version': '1.0.0',
            'name': 'Fixture',
          },
          'capabilities': {
            'progress': true,
            if (fault == 'discovery') 'modelDiscovery': true,
            if (fault == 'replay') 'continuity': {'strategy': 'history_replay'},
            if (fault == 'checkpoint')
              'continuity': {
                'strategy': 'checkpoint',
                'formatId': 'fixture-v1',
              },
          },
        });
      case 'models.list':
        if (File('$dataDirectory/catalog-failure').existsSync()) {
          send({
            'type': 'error',
            'id': frame.id,
            'code': 'not_ready',
            'message': 'Discovery unavailable',
          });
          continue;
        }
        send({
          'type': 'models.list.result',
          'id': frame.id,
          'models': [
            if (!File('$dataDirectory/catalog-empty').existsSync())
              {'id': 'fixture:8b', 'name': 'Fixture 8B', 'status': 'listed'},
          ],
        });
      case 'probe':
        send({
          'type': 'probe.result',
          'id': frame.id,
          'state': 'ready',
          'checks': <Object?>[],
        });
      case 'ping':
        if (fault != 'mute') {
          send({'type': 'pong', 'nonce': frame.json['nonce']});
        }
      case 'cancel':
        if (fault != 'ignore-cancel') {
          send({
            'type': 'error',
            'id': frame.id,
            'code': 'cancelled',
            'message': 'stopped',
            'retryable': false,
          });
        }
      case 'shutdown':
        exit(0);
      case 'execute':
        final id = frame.id;
        if (fault == 'checkpoint') {
          final session = frame.json['session'] as Map;
          final file = File('$dataDirectory/checkpoint-${session['key']}');
          if (session['mode'] == 'resume' && !file.existsSync()) {
            send({
              'type': 'error',
              'id': id,
              'code': 'session_not_found',
              'message': 'Missing checkpoint',
            });
            continue;
          }
          file.writeAsStringSync('committed');
        }
        switch (fault) {
          case 'large':
            send({
              'type': 'result',
              'id': id,
              'output': 'accepted:${(frame.json['prompt'] as String).length}',
              'artifacts': <Object?>[],
            });
          case 'crash':
            exit(3);
          case 'slow' || 'ignore-cancel' || 'mute':
            send({'type': 'progress', 'id': id, 'message': 'working'});
          case 'stderr-secret':
            stderr.writeln(
              'token sk-abcdefghijklmnopqrstuvwxyz0123 at /Users/someone/secret/file',
            );
            exit(4);
          case 'oversize':
            stdout.writeln('x' * 1100000);
          case 'context-error':
            send({
              'type': 'error',
              'id': id,
              'code': 'context_limit_exceeded',
              'message': 'Model context window exceeded',
              'retryable': false,
            });
          case 'error':
            send({
              'type': 'error',
              'id': id,
              'code': 'sign_in_required',
              'message': 'Sign in first',
              'retryable': false,
            });
          case 'escape':
            send({
              'type': 'result',
              'id': id,
              'output': '',
              'artifacts': [
                {'path': '../outside'},
              ],
            });
          case 'artifact':
            File('${Directory.current.path}/out.txt').writeAsStringSync('x');
            send({
              'type': 'result',
              'id': id,
              'output': 'wrote',
              'artifacts': [
                {'path': 'out.txt'},
              ],
            });
          default:
            send({'type': 'progress', 'id': id, 'message': 'working'});
            send({
              'type': 'result',
              'id': id,
              'output': fault == 'checkpoint'
                  ? 'mode:${(frame.json['session'] as Map)['mode']}'
                  : 'echo: ${frame.json['prompt']}',
              if (fault == 'checkpoint')
                'session': {
                  'state': (frame.json['session'] as Map)['mode'] == 'resume'
                      ? 'resumed'
                      : 'created',
                },
              'artifacts': <Object?>[],
            });
        }
    }
  }
}
