// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;

import '../ax/ax_render_diagnostics.dart';
import 'realtime_client_stub.dart';
import 'realtime_health.dart';
import 'realtime_messaging.dart';

/// The browser socket for `syntila.messaging/1` (ADR-038). The protocol itself
/// lives in [RealtimeMessaging]; this class owns the socket, the reconnects and
/// the subscriptions. Runs and legacy execution-workspace scopes have no stream
/// of their own: their events arrive on the Space and Thread streams.
class _BrowserRealtimeClient implements RealtimeClient {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  html.WebSocket? _socket;
  Uri? _endpoint;
  String? _spaceId;
  String? _threadId;
  Timer? _reconnectTimer;
  Timer? _ackTimer;
  late final _health = RealtimeHealthMonitor(
      ping: () => _send(_messaging.ping()),
      onStale: () {
        if (_closed) return;
        _events.add({'type': 'realtime.connection', 'status': 'stale'});
        _socket?.close();
        _scheduleReconnect();
      });
  int _attempt = 0;
  final _messaging = RealtimeMessaging();
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<void> connect(Uri endpoint, [String? workspaceId]) async {
    _closed = false;
    _endpoint = endpoint;
    _attempt = 0;
    _open();
  }

  @override
  Future<void> setWorkspace(String workspaceId) async {}

  @override
  Future<void> setScopes({
    String? spaceId,
    String? threadId,
    String? runId,
    String? executionWorkspaceId,
  }) async {
    final previous = _streams();
    _spaceId = spaceId;
    _threadId = threadId;
    final next = _streams();
    if (_socket?.readyState != html.WebSocket.OPEN) return;
    // Only changed streams are touched: a fresh subscription may reload its view.
    for (final entry in previous.entries) {
      if (!next.containsKey(entry.key)) {
        _send(_messaging.unsubscribe(entry.value.$1, entry.value.$2));
      }
    }
    for (final entry in next.entries) {
      if (!previous.containsKey(entry.key)) {
        _send(_messaging.subscribe(entry.value.$1, entry.value.$2));
      }
    }
  }

  Map<String, (String, String)> _streams() => {
        if (_spaceId != null) 'space:$_spaceId': ('space', _spaceId!),
        if (_threadId != null) 'thread:$_threadId': ('thread', _threadId!),
      };

  void _open() => unawaited(_openWithTicket());

  Future<void> _openWithTicket() async {
    var endpoint = _endpoint;
    if (_closed || endpoint == null) return;
    final tickets = realtimeTicketProvider;
    if (tickets != null) {
      try {
        final ticket = await tickets();
        if (_closed || !identical(_endpoint, endpoint)) return;
        endpoint = endpoint.replace(queryParameters: {
          ...endpoint.queryParameters,
          'ticket': ticket,
        });
      } catch (_) {
        _scheduleReconnect();
        return;
      }
    }
    final socket = html.WebSocket(endpoint.toString());
    _socket = socket;
    socket.onOpen.listen((_) {
      if (_closed || !identical(_socket, socket)) return;
      _attempt = 0;
      _events.add({'type': 'realtime.connection', 'status': 'connected'});
      _send(_messaging.subscribe('user', _userStreamId));
      for (final stream in _streams().values) {
        _send(_messaging.subscribe(stream.$1, stream.$2));
      }
      _health.start();
      _ackTimer?.cancel();
      _ackTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        for (final ack in _messaging.flushAcks()) {
          _send(ack);
        }
      });
    });
    socket.onMessage.listen((event) {
      if (_closed || !identical(_socket, socket)) return;
      final data = event.data;
      if (data is! String) return;
      try {
        final result = _messaging.receive(jsonDecode(data));
        for (final reply in result.replies) {
          _send(reply);
        }
        for (final message in result.events) {
          if (message['type'] == 'realtime.pong') {
            _health.acknowledge();
          } else {
            _events.add(message);
          }
        }
      } on FormatException {
        // Ignore malformed server frames; reconnect handling remains intact.
      }
    });
    socket.onClose.listen((_) {
      if (identical(_socket, socket)) _scheduleReconnect();
    });
    socket.onError.listen((_) {
      if (identical(_socket, socket)) _scheduleReconnect();
    });
  }

  /// The user stream is addressed by the server from the credential; the id the
  /// client names is only a label and is checked against it.
  static const _userStreamId = 'me';

  void _scheduleReconnect() {
    if (_closed || _reconnectTimer?.isActive == true) return;
    _health.stop();
    _ackTimer?.cancel();
    _events.add({'type': 'realtime.connection', 'status': 'reconnecting'});
    final cappedAttempt = math.min(_attempt++, 8);
    final jitter = 0.75 + math.Random().nextDouble() * 0.5;
    final delay = Duration(
        milliseconds: (500 * math.pow(2, cappedAttempt) * jitter).round());
    _reconnectTimer = Timer(delay, _open);
  }

  void _send(Map<String, dynamic> message) {
    final socket = _socket;
    if (const bool.fromEnvironment('SYNTILA_REALTIME_DIAGNOSTICS') &&
        message['command'] is String &&
        (message['command'] as String).startsWith('subscription.')) {
      AxRenderDiagnostics.instance.record('realtime.subscription',
          operation: message['command'] as String,
          contextData: {
            'payload': message['payload'],
            'socketOpen': socket?.readyState == html.WebSocket.OPEN
          });
    }
    if (socket?.readyState == html.WebSocket.OPEN) {
      socket!.send(jsonEncode(message));
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _health.stop();
    _ackTimer?.cancel();
    _reconnectTimer?.cancel();
    _socket?.close();
    await _events.close();
  }
}

RealtimeClient createRealtimeClient() => _BrowserRealtimeClient();
