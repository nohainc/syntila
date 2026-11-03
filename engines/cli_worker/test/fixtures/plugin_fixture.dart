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
        send({
          'type': 'hello.result',
          'id': frame.id,
          'protocol': '1.0',
          'plugin': {
            'id': fault == 'bad-identity' ? 'someone-else' : 'fixture-plugin',
            'version': '1.0.0',
            'name': 'Fixture',
          },
          'capabilities': {'progress': true},
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
        switch (fault) {
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
              'output': 'echo: ${frame.json['prompt']}',
              'artifacts': <Object?>[],
            });
        }
    }
  }
}
