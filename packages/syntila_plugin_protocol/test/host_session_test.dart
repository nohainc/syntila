import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';
import 'package:test/test.dart';

PluginFrame helloResult({
  String id = 'h1',
  String protocol = '1.0',
  String pluginId = 'acme-reviewer',
  String version = '1.4.2',
}) =>
    decodePluginFrame(
      '{"type":"hello.result","id":"$id","protocol":"$protocol",'
      '"plugin":{"id":"$pluginId","version":"$version","name":"A"},'
      '"capabilities":{"progress":true}}',
      PluginDirection.pluginToHost,
    );

PluginFrame plugin(String json) =>
    decodePluginFrame(json, PluginDirection.pluginToHost);

class Clock {
  DateTime now = DateTime.utc(2026, 11, 3, 10);
  void advance(Duration d) => now = now.add(d);
}

PluginHostSession ready(Clock clock) {
  final session = PluginHostSession(
    expectedPluginId: 'acme-reviewer',
    expectedVersion: '1.4.2',
    now: () => clock.now,
  );
  session.startHandshake(id: 'h1', hostVersion: '1.4.0', dataDir: '/d');
  expect(session.onPluginFrame(helloResult()).kind, FrameVerdictKind.accept);
  return session;
}

PluginHostSession executing(Clock clock) {
  final session = ready(clock);
  session.beginExecute(PluginFrame.execute(
    id: 'e1',
    deadlineMs: 60000,
    prompt: 'hi',
    workingDirectory: '/s',
    access: 'read_write',
  ));
  return session;
}

void main() {
  group('handshake', () {
    test('accepts a matching hello.result and records the capabilities', () {
      final session = ready(Clock());
      expect(session.phase, PluginSessionPhase.ready);
      expect(session.negotiatedProtocol, '1.0');
      expect(session.capabilities['progress'], true);
    });

    test('rejects a first frame that is not hello.result', () {
      final session = PluginHostSession(
          expectedPluginId: 'acme-reviewer', expectedVersion: '1.4.2');
      session.startHandshake(id: 'h1', hostVersion: '1', dataDir: '/d');
      final verdict = session.onPluginFrame(
          plugin('{"type":"progress","id":"e1","message":"x"}'));
      expect(verdict.code, PluginHostFailure.protocolViolation);
    });

    test('reports identity and protocol mismatches with distinct codes', () {
      PluginHostSession fresh() {
        final s = PluginHostSession(
            expectedPluginId: 'acme-reviewer', expectedVersion: '1.4.2');
        s.startHandshake(id: 'h1', hostVersion: '1', dataDir: '/d');
        return s;
      }

      expect(fresh().onPluginFrame(helloResult(pluginId: 'evil')).code,
          PluginHostFailure.identityMismatch);
      expect(fresh().onPluginFrame(helloResult(version: '9.9.9')).code,
          PluginHostFailure.identityMismatch);
      expect(fresh().onPluginFrame(helloResult(protocol: '1.7')).code,
          PluginHostFailure.protocolUnsupported);
      expect(fresh().onPluginFrame(helloResult(id: 'other')).code,
          PluginHostFailure.protocolViolation);
      expect(
          fresh()
              .onPluginFrame(plugin(
                  '{"type":"error","code":"unsupported_protocol","message":""}'))
              .code,
          PluginHostFailure.protocolUnsupported);
    });

    test('times out after ten seconds', () {
      final clock = Clock();
      final session = PluginHostSession(
          expectedPluginId: 'a', expectedVersion: '1.0.0', now: () => clock.now);
      session.startHandshake(id: 'h1', hostVersion: '1', dataDir: '/d');
      clock.advance(const Duration(seconds: 9));
      expect(session.handshakeOverdue, isFalse);
      clock.advance(const Duration(seconds: 1));
      expect(session.handshakeOverdue, isTrue);
    });
  });

  group('execute', () {
    test('accepts progress then exactly one terminal frame', () {
      final session = executing(Clock());
      expect(
          session
              .onPluginFrame(plugin('{"type":"progress","id":"e1","message":"x"}'))
              .kind,
          FrameVerdictKind.accept);
      expect(
          session
              .onPluginFrame(plugin('{"type":"result","id":"e1","output":"ok"}'))
              .kind,
          FrameVerdictKind.accept);
      expect(session.phase, PluginSessionPhase.ready);
      expect(session.lastTerminal?.type, 'result');
    });

    test('a second terminal frame is a violation; late progress is dropped', () {
      final session = executing(Clock());
      session.onPluginFrame(plugin('{"type":"result","id":"e1","output":"a"}'));
      final late = session
          .onPluginFrame(plugin('{"type":"progress","id":"e1","message":"x"}'));
      expect(late.kind, FrameVerdictKind.drop);
      expect(session.droppedFrames, 1);
      final second = session
          .onPluginFrame(plugin('{"type":"result","id":"e1","output":"b"}'));
      expect(second.code, PluginHostFailure.protocolViolation);
    });

    test('rejects frames for an unknown id', () {
      final session = executing(Clock());
      final verdict = session
          .onPluginFrame(plugin('{"type":"result","id":"zzz","output":""}'));
      expect(verdict.code, PluginHostFailure.protocolViolation);
    });

    test('rate limits non-terminal frames but never terminal ones', () {
      final clock = Clock();
      final session = executing(clock);
      var dropped = 0;
      for (var i = 0; i < PluginProtocolLimits.progressBurst + 50; i++) {
        final verdict = session.onPluginFrame(
            plugin('{"type":"progress","id":"e1","message":"x"}'));
        if (verdict.kind == FrameVerdictKind.drop) dropped++;
      }
      expect(dropped, 50);
      expect(session.droppedFrames, 50);
      clock.advance(const Duration(seconds: 1));
      expect(
          session
              .onPluginFrame(plugin('{"type":"progress","id":"e1","message":"x"}'))
              .kind,
          FrameVerdictKind.accept);
      expect(
          session
              .onPluginFrame(plugin('{"type":"result","id":"e1","output":""}'))
              .kind,
          FrameVerdictKind.accept);
    });
  });

  group('liveness and cancel', () {
    test('pings every 15 seconds and gives up after three silent windows', () {
      final clock = Clock();
      final session = executing(clock);
      expect(session.nextPing(), isNull);
      clock.advance(const Duration(seconds: 15));
      expect(session.nextPing()?.type, 'ping');
      expect(session.nextPing(), isNull);
      clock.advance(const Duration(seconds: 29));
      expect(session.unresponsive, isFalse);
      clock.advance(const Duration(seconds: 1));
      expect(session.unresponsive, isTrue);
    });

    test('any plugin frame counts as liveness and a ping gets a pong', () {
      final clock = Clock();
      final session = executing(clock);
      clock.advance(const Duration(seconds: 40));
      session.onPluginFrame(plugin('{"type":"ping","nonce":"n1"}'));
      expect(session.unresponsive, isFalse);
      final replies = session.takeReplies();
      expect(replies.single.type, 'pong');
      expect(replies.single.json['nonce'], 'n1');
      expect(session.takeReplies(), isEmpty);
    });

    test('cancel is idempotent, has a five second grace, and clears on terminal',
        () {
      final clock = Clock();
      final session = executing(clock);
      final first = session.requestCancel();
      clock.advance(const Duration(seconds: 4));
      expect(identical(session.requestCancel(), first), isTrue);
      expect(session.cancelOverdue, isFalse);
      clock.advance(const Duration(seconds: 1));
      expect(session.cancelOverdue, isTrue);
      session.onPluginFrame(plugin(
          '{"type":"error","id":"e1","code":"cancelled","message":"","retryable":false}'));
      expect(session.cancelOverdue, isFalse);
      expect(session.phase, PluginSessionPhase.ready);
    });

    test('probe results must match the pending probe', () {
      final session = ready(Clock());
      session.beginProbe(id: 'p1', mode: 'passive');
      expect(
          session
              .onPluginFrame(plugin('{"type":"probe.result","id":"p2","state":"ready"}'))
              .code,
          PluginHostFailure.protocolViolation);
      final session2 = ready(Clock());
      session2.beginProbe(id: 'p1', mode: 'passive');
      expect(
          session2
              .onPluginFrame(plugin('{"type":"probe.result","id":"p1","state":"ready"}'))
              .kind,
          FrameVerdictKind.accept);
    });

    test('refuses to execute before the handshake completes', () {
      final session = PluginHostSession(
          expectedPluginId: 'a', expectedVersion: '1.0.0');
      expect(
          () => session.beginExecute(PluginFrame.execute(
              id: 'e1',
              deadlineMs: 1000,
              prompt: '',
              workingDirectory: '/s',
              access: 'read_write')),
          throwsStateError);
    });
  });
}
