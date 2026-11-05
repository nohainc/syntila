import 'frames.dart';
import 'limits.dart';

enum PluginSessionPhase { awaitingHello, ready, executing }

enum FrameVerdictKind { accept, drop, violation }

/// Outcome of feeding one validated plugin frame to a [PluginHostSession].
final class FrameVerdict {
  const FrameVerdict._(this.kind, this.code, this.detail);

  const FrameVerdict.accept() : this._(FrameVerdictKind.accept, null, null);
  const FrameVerdict.drop(String detail)
      : this._(FrameVerdictKind.drop, null, detail);
  const FrameVerdict.violation(String code, String detail)
      : this._(FrameVerdictKind.violation, code, detail);

  final FrameVerdictKind kind;

  /// A `PluginHostFailure` code when [kind] is a violation.
  final String? code;
  final String? detail;

  bool get isViolation => kind == FrameVerdictKind.violation;
}

/// Pure host-side rules for one plugin process: handshake ordering, identity,
/// id correlation, exactly one terminal frame per execute, rate limiting,
/// heartbeats and cancel/handshake deadlines. It performs no I/O and takes an
/// injectable clock, so the Engine's plugin host and tests share one rule set.
///
/// A violation means the host must terminate the plugin process.
class PluginHostSession {
  PluginHostSession({
    required this.expectedPluginId,
    required this.expectedVersion,
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now,
        _tokens = PluginProtocolLimits.progressBurst.toDouble() {
    _lastRefill = _now();
    _lastFrameAt = _lastRefill;
  }

  final String expectedPluginId;
  final String expectedVersion;
  final DateTime Function() _now;

  PluginSessionPhase _phase = PluginSessionPhase.awaitingHello;
  String? _helloId;
  DateTime? _helloSentAt;
  String? _negotiatedProtocol;
  Map<String, Object?> _capabilities = const {};
  String? _activeExecuteId;
  String? _pendingProbeId;
  String? _pendingModelsId;
  DateTime? _cancelDeadline;
  PluginFrame? _cancelFrame;
  late DateTime _lastFrameAt;
  DateTime? _lastPingAt;
  int _pingSequence = 0;
  final List<PluginFrame> _replies = [];
  final List<String> _finishedIds = [];
  PluginFrame? _lastTerminal;

  double _tokens;
  late DateTime _lastRefill;

  /// Non-terminal frames dropped by the rate limit or sent after a terminal.
  int droppedFrames = 0;

  PluginSessionPhase get phase => _phase;
  String? get negotiatedProtocol => _negotiatedProtocol;
  Map<String, Object?> get capabilities => _capabilities;
  PluginFrame? get lastTerminal => _lastTerminal;

  /// Frames the host must write to the plugin (for example `pong`).
  List<PluginFrame> takeReplies() {
    final replies = List<PluginFrame>.of(_replies);
    _replies.clear();
    return replies;
  }

  PluginFrame startHandshake({
    required String id,
    required String hostVersion,
    required String dataDir,
  }) {
    if (_helloId != null) throw StateError('handshake already started');
    _helloId = id;
    _helloSentAt = _now();
    return PluginFrame.hello(
      id: id,
      hostVersion: hostVersion,
      dataDir: dataDir,
    );
  }

  PluginFrame beginProbe({required String id, required String mode}) {
    _require(PluginSessionPhase.ready);
    if (_pendingProbeId != null) throw StateError('probe already pending');
    _pendingProbeId = id;
    return PluginFrame.probe(id: id, mode: mode);
  }

  PluginFrame beginListModels({required String id}) {
    _require(PluginSessionPhase.ready);
    if (_pendingModelsId != null) throw StateError('discovery already pending');
    _pendingModelsId = id;
    return PluginFrame.listModels(id: id);
  }

  PluginFrame beginExecute(PluginFrame execute) {
    _require(PluginSessionPhase.ready);
    if (execute.type != 'execute') throw ArgumentError('expected execute');
    _activeExecuteId = execute.id;
    _phase = PluginSessionPhase.executing;
    _cancelDeadline = null;
    _cancelFrame = null;
    _lastFrameAt = _now();
    _lastPingAt = _lastFrameAt;
    return execute;
  }

  /// Idempotent: repeated calls return the same cancel frame and keep the
  /// original deadline.
  PluginFrame requestCancel({String reason = 'user'}) {
    _require(PluginSessionPhase.executing);
    _cancelDeadline ??= _now().add(PluginProtocolLimits.cancelGrace);
    return _cancelFrame ??=
        PluginFrame.cancel(id: _activeExecuteId!, reason: reason);
  }

  /// True when the handshake did not complete within the timeout.
  bool get handshakeOverdue =>
      _phase == PluginSessionPhase.awaitingHello &&
      _helloSentAt != null &&
      _now().difference(_helloSentAt!) >= PluginProtocolLimits.handshakeTimeout;

  /// True when a cancel was sent and no terminal frame arrived in the grace.
  bool get cancelOverdue =>
      _phase == PluginSessionPhase.executing &&
      _cancelDeadline != null &&
      !_now().isBefore(_cancelDeadline!);

  /// Three consecutive ping windows with no frame at all.
  bool get unresponsive =>
      _phase == PluginSessionPhase.executing &&
      _now().difference(_lastFrameAt) >=
          PluginProtocolLimits.pingInterval *
              PluginProtocolLimits.missedPingWindows;

  /// The next heartbeat ping if one is due, otherwise null.
  PluginFrame? nextPing() {
    if (_phase != PluginSessionPhase.executing) return null;
    final now = _now();
    final last = _lastPingAt ?? _lastFrameAt;
    if (now.difference(last) < PluginProtocolLimits.pingInterval) return null;
    _lastPingAt = now;
    _pingSequence += 1;
    return PluginFrame.ping('host-$_pingSequence');
  }

  FrameVerdict onPluginFrame(PluginFrame frame) {
    _lastFrameAt = _now();
    if (_phase == PluginSessionPhase.awaitingHello) {
      return _onHandshakeFrame(frame);
    }
    switch (frame.type) {
      case 'ping':
        _replies.add(PluginFrame.pong(frame.json['nonce'] as String));
        return const FrameVerdict.accept();
      case 'pong':
        return const FrameVerdict.accept();
      case 'hello.result':
        return const FrameVerdict.violation(
          PluginHostFailure.protocolViolation,
          'hello.result after the handshake',
        );
      case 'models.list.result':
        if (_pendingModelsId == null || frame.id != _pendingModelsId) {
          return const FrameVerdict.violation(
              PluginHostFailure.protocolViolation,
              'unexpected discovery response');
        }
        _pendingModelsId = null;
        return const FrameVerdict.accept();
      case 'error':
        if ((_pendingModelsId != null && frame.id == _pendingModelsId) ||
            (_pendingProbeId != null && frame.id == _pendingProbeId)) {
          _pendingModelsId = null;
          _pendingProbeId = null;
          return const FrameVerdict.accept();
        }
        return _onExecutionFrame(frame);
      case 'probe.result':
        if (_pendingProbeId == null || frame.id != _pendingProbeId) {
          return const FrameVerdict.violation(
            PluginHostFailure.protocolViolation,
            'probe.result does not match a pending probe',
          );
        }
        _pendingProbeId = null;
        return const FrameVerdict.accept();
      default:
        return _onExecutionFrame(frame);
    }
  }

  FrameVerdict _onHandshakeFrame(PluginFrame frame) {
    if (frame.type == 'error' && frame.json['code'] == 'unsupported_protocol') {
      return const FrameVerdict.violation(
        PluginHostFailure.protocolUnsupported,
        'plugin supports none of the offered protocol versions',
      );
    }
    if (frame.type != 'hello.result') {
      return const FrameVerdict.violation(
        PluginHostFailure.protocolViolation,
        'first plugin frame must be hello.result',
      );
    }
    if (frame.id != _helloId) {
      return const FrameVerdict.violation(
        PluginHostFailure.protocolViolation,
        'hello.result id does not match hello',
      );
    }
    final protocol = frame.json['protocol'] as String;
    if (!PluginProtocolLimits.supportedProtocolVersions.contains(protocol)) {
      return const FrameVerdict.violation(
        PluginHostFailure.protocolUnsupported,
        'plugin selected a protocol version the host did not offer',
      );
    }
    final plugin = Map<String, Object?>.from(frame.json['plugin'] as Map);
    if (plugin['id'] != expectedPluginId ||
        plugin['version'] != expectedVersion) {
      return const FrameVerdict.violation(
        PluginHostFailure.identityMismatch,
        'plugin identity differs from the pinned manifest',
      );
    }
    _negotiatedProtocol = protocol;
    _capabilities =
        Map<String, Object?>.from(frame.json['capabilities'] as Map);
    _phase = PluginSessionPhase.ready;
    return const FrameVerdict.accept();
  }

  FrameVerdict _onExecutionFrame(PluginFrame frame) {
    final id = frame.id;
    if (id == null) {
      return const FrameVerdict.violation(
        PluginHostFailure.protocolViolation,
        'frame without an id',
      );
    }
    if (_finishedIds.contains(id)) {
      if (frame.isTerminal) {
        return const FrameVerdict.violation(
          PluginHostFailure.protocolViolation,
          'second terminal frame for one execute',
        );
      }
      droppedFrames += 1;
      return const FrameVerdict.drop('frame after the terminal frame');
    }
    if (_phase != PluginSessionPhase.executing || id != _activeExecuteId) {
      return const FrameVerdict.violation(
        PluginHostFailure.protocolViolation,
        'frame id does not match the active execute',
      );
    }
    if (frame.isTerminal) {
      _lastTerminal = frame;
      _finishedIds.add(id);
      if (_finishedIds.length > 16) _finishedIds.removeAt(0);
      _activeExecuteId = null;
      _cancelDeadline = null;
      _cancelFrame = null;
      _phase = PluginSessionPhase.ready;
      return const FrameVerdict.accept();
    }
    if (!_takeToken()) {
      droppedFrames += 1;
      return const FrameVerdict.drop('progress rate limit exceeded');
    }
    return const FrameVerdict.accept();
  }

  bool _takeToken() {
    final now = _now();
    final elapsed = now.difference(_lastRefill).inMicroseconds / 1e6;
    _lastRefill = now;
    _tokens = (_tokens + elapsed * PluginProtocolLimits.progressRatePerSecond)
        .clamp(0.0, PluginProtocolLimits.progressBurst.toDouble())
        .toDouble();
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }

  void _require(PluginSessionPhase expected) {
    if (_phase != expected) {
      throw StateError('session is $_phase, expected $expected');
    }
  }
}
