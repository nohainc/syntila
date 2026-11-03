import 'dart:io';

import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:test/test.dart';

const _vectorDirectory = '../../docs/specifications/worker-plugin-vectors';

/// Replays a documented transcript against the host rules. Returns the code of
/// the first violation, or null when every frame is accepted or dropped.
String? replay(String name) {
  final lines = File('$_vectorDirectory/$name.transcript')
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty);
  final session = PluginHostSession(
    expectedPluginId: 'acme-reviewer',
    expectedVersion: '1.4.2',
  );
  var handshook = false;

  void handshake() {
    if (handshook) return;
    session.startHandshake(id: 'h1', hostVersion: '1.4.0', dataDir: '/data');
    session.onPluginFrame(decodePluginFrame(
      '{"type":"hello.result","id":"h1","protocol":"1.0",'
      '"plugin":{"id":"acme-reviewer","version":"1.4.2","name":"A"},'
      '"capabilities":{}}',
      PluginDirection.pluginToHost,
    ));
    handshook = true;
  }

  for (final line in lines) {
    final payload = line.substring(2);
    if (line.startsWith('→')) {
      final frame = decodePluginFrame(payload, PluginDirection.hostToPlugin);
      switch (frame.type) {
        case 'hello':
          session.startHandshake(
              id: frame.id!, hostVersion: '1.4.0', dataDir: '/data');
          handshook = true;
        case 'probe':
          handshake();
          session.beginProbe(id: frame.id!, mode: frame.json['mode'] as String);
        case 'execute':
          handshake();
          session.beginExecute(frame);
        case 'cancel':
          session.requestCancel();
        default:
          break;
      }
    } else {
      final PluginFrame frame;
      try {
        frame = decodePluginFrame(payload, PluginDirection.pluginToHost);
      } on PluginFrameException {
        return PluginHostFailure.protocolViolation;
      }
      final verdict = session.onPluginFrame(frame);
      if (verdict.isViolation) return verdict.code;
    }
  }
  return null;
}

void main() {
  test('valid-minimal is accepted end to end', () {
    expect(replay('valid-minimal'), isNull);
  });

  test('valid-cancel is accepted and ends the execute', () {
    expect(replay('valid-cancel'), isNull);
  });

  test('invalid-two-terminals is a protocol violation', () {
    expect(replay('invalid-two-terminals'), PluginHostFailure.protocolViolation);
  });

  test('invalid-stdout-noise is a protocol violation', () {
    expect(replay('invalid-stdout-noise'), PluginHostFailure.protocolViolation);
  });
}
