// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;

import 'package:syntila_protocol/syntila_protocol.dart';

import '../ax/ax_render_diagnostics.dart';
import 'realtime_client_stub.dart';
import 'realtime_health.dart';
import 'realtime_cursors.dart';

class _BrowserRealtimeClient implements RealtimeClient {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  html.WebSocket? _socket;
  Uri? _endpoint;
  String? _spaceId;
  String? _threadId;
  String? _runId;
  String? _executionWorkspaceId;
  Timer? _reconnectTimer;
  late final _health = RealtimeHealthMonitor(
      ping: () => _send({'type': 'ping'}),
      onStale: () {
        if (_closed) return;
        _events.add({'type': 'realtime.connection', 'status': 'stale'});
        _socket?.close();
        _scheduleReconnect();
      });
  int _attempt = 0;
  final _cursors = RealtimeCursors();
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
  Future<void> setWorkspace(String workspaceId) async {
    await setScopes(executionWorkspaceId: workspaceId);
  }

  @override
  Future<void> setScopes({
    String? spaceId,
    String? threadId,
    String? runId,
    String? executionWorkspaceId,
  }) async {
    String key(Map<String, dynamic> scope) => jsonEncode(scope);
    final previous = {for (final scope in _currentScopes()) key(scope): scope};
    _spaceId = spaceId;
    _threadId = threadId;
    _runId = runId;
    _executionWorkspaceId = executionWorkspaceId;
    final next = {for (final scope in _currentScopes()) key(scope): scope};
    if (_socket?.readyState != html.WebSocket.OPEN) return;
    // Only changed scopes are touched: every subscribe makes Cloud send
    // realtime.ready, which triggers a full recovery of that scope.
    for (final entry in previous.entries) {
      if (!next.containsKey(entry.key)) {
        _send({'type': 'unsubscribe', 'scope': entry.value});
      }
    }
    for (final entry in next.entries) {
      if (!previous.containsKey(entry.key)) {
        _send({'type': 'subscribe', 'scope': entry.value});
      }
    }
  }

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
    // Cloud sends realtime.ready on accept and again after hello; both mean
    // the same connection is live, and each one triggers a full recovery.
    var readyForwarded = false;
    socket.onOpen.listen((_) {
      if (_closed || !identical(_socket, socket)) return;
      _attempt = 0;
      _events.add({'type': 'realtime.connection', 'status': 'connected'});
      _send(_cursors.hello());
      _send({
        'type': 'subscribe',
        'scope': {'kind': 'user'}
      });
      _subscribeCurrentScopes();
      _health.start();
    });
    socket.onMessage.listen((event) {
      if (_closed || !identical(_socket, socket)) return;
      final data = event.data;
      if (data is! String) return;
      try {
        final decoded = jsonDecode(data);
        if (decoded is! Map) return;
        final message = Map<String, dynamic>.from(decoded);
        if (message['type'] == 'realtime.pong') {
          _health.acknowledge();
        } else if (message['type'] == 'realtime.ready') {
          if (readyForwarded) return;
          readyForwarded = true;
          _events.add(message);
        } else if (message['type'] == 'event' && message['event'] is Map) {
          final eventValue = Map<String, dynamic>.from(message['event'] as Map);
          final type = eventValue['type'];
          if (type is String && isReplayableRealtimeEvent(eventValue)) {
            _cursors.record(eventValue);
          }
          _events.add(eventValue);
        } else if (message['type'] == 'reconnect.required') {
          _cursors.record(message);
          // Query routers reconcile the affected stream through authenticated HTTP.
          _events.add(message);
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

  void _subscribeCurrentScopes() {
    for (final scope in _currentScopes()) {
      _send({'type': 'subscribe', 'scope': scope});
    }
  }

  List<Map<String, dynamic>> _currentScopes() => [
        if (_spaceId != null) {'kind': 'space', 'spaceId': _spaceId},
        if (_threadId != null) {'kind': 'thread', 'threadId': _threadId},
        if (_runId != null) {'kind': 'run', 'runId': _runId},
        if (_executionWorkspaceId != null)
          {
            'kind': 'execution_workspace',
            'executionWorkspaceId': _executionWorkspaceId
          },
      ];

  void _scheduleReconnect() {
    if (_closed || _reconnectTimer?.isActive == true) return;
    _health.stop();
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
        (message['type'] == 'subscribe' || message['type'] == 'unsubscribe')) {
      AxRenderDiagnostics.instance.record('realtime.subscription',
          operation: message['type'] as String,
          contextData: {
            'scope': message['scope'],
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
    _reconnectTimer?.cancel();
    _socket?.close();
    await _events.close();
  }
}

RealtimeClient createRealtimeClient() => _BrowserRealtimeClient();
