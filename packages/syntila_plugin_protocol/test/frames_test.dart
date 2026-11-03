import 'dart:convert';

import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:test/test.dart';

PluginFrame decodeFromPlugin(Map<String, Object?> json) =>
    decodePluginFrame(jsonEncode(json), PluginDirection.pluginToHost);

void main() {
  test('round-trips host frames through the host-to-plugin decoder', () {
    final frames = [
      PluginFrame.hello(id: 'h1', hostVersion: '1.4.0', dataDir: '/data'),
      PluginFrame.probe(id: 'p1', mode: 'passive'),
      PluginFrame.execute(
        id: 'e1',
        deadlineMs: 1000,
        prompt: 'hi',
        workingDirectory: '/space',
        access: 'read_only',
        sessionKey: 'worker-session-1',
        sessionMode: 'resume',
      ),
      PluginFrame.cancel(id: 'e1'),
      PluginFrame.ping('n1'),
      PluginFrame.pong('n1'),
      PluginFrame.shutdown(),
    ];
    for (final frame in frames) {
      final decoded =
          decodePluginFrame(frame.encode(), PluginDirection.hostToPlugin);
      expect(decoded.type, frame.type);
    }
  });

  test('accepts CRLF and ignores unknown fields', () {
    final frame = decodePluginFrame(
      '{"type":"progress","id":"e1","message":"x","future":true}\r\n',
      PluginDirection.pluginToHost,
    );
    expect(frame.type, 'progress');
  });

  test('rejects a frame type sent in the wrong direction', () {
    expect(
      () => decodePluginFrame(
        PluginFrame.shutdown().encode(),
        PluginDirection.pluginToHost,
      ),
      throwsA(isA<PluginFrameException>()),
    );
    expect(
      () => decodeFromPlugin({'type': 'hello', 'id': 'x'}),
      throwsA(isA<PluginFrameException>()),
    );
  });

  test('rejects malformed JSON, non-objects and oversize lines', () {
    for (final line in ['not json', '[]', '"x"', '{"type":5}']) {
      expect(() => decodePluginFrame(line, PluginDirection.pluginToHost),
          throwsA(isA<PluginFrameException>()));
    }
    final huge = jsonEncode({
      'type': 'progress',
      'id': 'e1',
      'message': 'x',
      'pad': 'y' * PluginProtocolLimits.maxFrameBytes,
    });
    expect(() => decodePluginFrame(huge, PluginDirection.pluginToHost),
        throwsA(isA<PluginFrameException>()));
  });

  test('bounds progress, percent and ids', () {
    expect(
      () => decodeFromPlugin(
          {'type': 'progress', 'id': 'e1', 'message': 'x', 'percent': 101}),
      throwsA(isA<PluginFrameException>()),
    );
    expect(
      () => decodeFromPlugin({
        'type': 'progress',
        'id': 'e1',
        'message': 'x' * (PluginProtocolLimits.maxProgressMessageLength + 1),
      }),
      throwsA(isA<PluginFrameException>()),
    );
    expect(
      () => decodeFromPlugin(
          {'type': 'progress', 'id': 'bad id', 'message': 'x'}),
      throwsA(isA<PluginFrameException>()),
    );
  });

  test('limits result output by bytes, not characters', () {
    final atLimit = 'a' * PluginProtocolLimits.maxOutputBytes;
    expect(
      decodeFromPlugin({
        'type': 'result',
        'id': 'e1',
        'output': atLimit,
        'artifacts': []
      }).type,
      'result',
    );
    // Three-byte characters: fewer characters than the limit, more bytes, and
    // the whole frame still fits under the frame limit.
    final multibyte = '€' * 270000;
    expect(
      () =>
          decodeFromPlugin({'type': 'result', 'id': 'e1', 'output': multibyte}),
      throwsA(isA<PluginFrameException>()),
    );
  });

  test('rejects unsafe artifact paths', () {
    for (final path in [
      '../x',
      '/etc/passwd',
      r'C:\x',
      'a//b',
      r'a\..\b',
      ''
    ]) {
      expect(
        () => decodeFromPlugin({
          'type': 'result',
          'id': 'e1',
          'output': '',
          'artifacts': [
            {'path': path}
          ],
        }),
        throwsA(isA<PluginFrameException>()),
        reason: path,
      );
    }
    expect(isSafePluginRelativePath('reports/review.md'), isTrue);
  });

  test('validates probe states, hello.result protocol and error shape', () {
    expect(
      () => decodeFromPlugin(
          {'type': 'probe.result', 'id': 'p1', 'state': 'weird'}),
      throwsA(isA<PluginFrameException>()),
    );
    expect(
      () => decodeFromPlugin({
        'type': 'hello.result',
        'id': 'h1',
        'protocol': '2.0',
        'plugin': {'id': 'a', 'version': '1.0.0', 'name': 'A'},
        'capabilities': {},
      }),
      throwsA(isA<PluginFrameException>()),
    );
    // An error before any execute may omit the id.
    expect(
      decodeFromPlugin(
              {'type': 'error', 'code': 'unsupported_protocol', 'message': ''})
          .type,
      'error',
    );
  });

  test('normalizes unknown plugin error codes to internal', () {
    expect(normalizePluginErrorCode('cancelled'), 'cancelled');
    expect(normalizePluginErrorCode('mystery'), 'internal');
  });

  test('execute requires reserved attachments to be empty', () {
    expect(
      () => decodePluginFrame(
        jsonEncode({
          'type': 'execute',
          'id': 'e1',
          'deadlineMs': 1000,
          'prompt': '',
          'workingDirectory': '/s',
          'access': 'read_write',
          'attachments': ['a'],
        }),
        PluginDirection.hostToPlugin,
      ),
      throwsA(isA<PluginFrameException>()),
    );
  });
}
