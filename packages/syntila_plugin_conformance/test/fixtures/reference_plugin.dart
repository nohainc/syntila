// Reference Worker plugin for the conformance suite's own tests. It is a
// compliant, minimal echo plugin; `--fault=NAME` makes it break one rule so
// each suite case can be shown to fail for the right reason.
//
//   --resume             implements session resume with files under dataDir
//   --fault=wrong-identity | two-terminals | noise | no-pong | ignore-eof |
//           hang | late-progress
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';

void send(Map<String, Object?> json) => stdout.writeln(jsonEncode(json));

Future<void> main(List<String> args) async {
  final resume = args.contains('--resume');
  final fault = args
      .firstWhere((a) => a.startsWith('--fault='), orElse: () => '--fault=')
      .substring('--fault='.length);
  if (fault == 'noise') stdout.writeln('starting up...');
  var dataDir = Directory.systemTemp.path;
  Timer? keepAlive;
  if (fault == 'ignore-eof') {
    keepAlive = Timer.periodic(const Duration(seconds: 1), (_) {});
  }

  void execute(PluginFrame frame) {
    final id = frame.id;
    final session = frame.json['session'];
    String? sessionState;
    if (resume && session is Map) {
      final key = session['key'] as String;
      final file = File('$dataDir/session-$key');
      if (session['mode'] == 'resume') {
        if (!file.existsSync()) {
          send({
            'type': 'error',
            'id': id,
            'code': 'session_not_found',
            'message': 'unknown session',
            'retryable': false,
          });
          return;
        }
        sessionState = 'resumed';
      } else {
        file.writeAsStringSync('state');
        sessionState = 'created';
      }
    }
    if (fault == 'hang') return; // never answers
    send({'type': 'progress', 'id': id, 'message': 'working'});
    final result = {
      'type': 'result',
      'id': id,
      'output': 'echo: ${frame.json['prompt']}'.substring(0, 20),
      'artifacts': <Object?>[],
      if (sessionState != null) 'session': {'state': sessionState},
    };
    send(result);
    if (fault == 'two-terminals') send(result);
    if (fault == 'late-progress') {
      send({'type': 'progress', 'id': id, 'message': 'late'});
    }
  }

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
        dataDir = frame.json['dataDir'] as String;
        final supported = List<String>.from(
          (frame.json['protocol'] as Map)['supported'] as List,
        );
        if (!supported.contains('1.0')) {
          send({
            'type': 'error',
            'code': 'unsupported_protocol',
            'message': 'supports 1.0',
            'retryable': false,
          });
          exit(0);
        }
        send({
          'type': 'hello.result',
          'id': frame.id,
          'protocol': '1.0',
          'plugin': {
            'id': fault == 'wrong-identity' ? 'someone-else' : 'ref-plugin',
            'version': '1.0.0',
            'name': 'Reference',
          },
          'capabilities': {
            'progress': true,
            if (resume) 'sessionResume': true,
          },
        });
      case 'probe':
        send({
          'type': 'probe.result',
          'id': frame.id,
          'state': 'ready',
          'checks': <Object?>[],
        });
      case 'ping':
        if (fault != 'no-pong') {
          send({'type': 'pong', 'nonce': frame.json['nonce']});
        }
      case 'execute':
        execute(frame);
      case 'cancel':
        break; // execute completes immediately, so there is never work to stop
      case 'shutdown':
        exit(0);
    }
  }
  // With `ignore-eof` the periodic timer above keeps the process alive after
  // end of input, which is exactly the misbehavior under test.
  if (fault != 'ignore-eof') keepAlive?.cancel();
}
