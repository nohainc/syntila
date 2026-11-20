import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'identity.dart';
import 'server_api.dart';
import 'wire.dart';

/// Connection dimension of the Agent state machine. It is separate from
/// registration and execution state.
enum ConnectionPhase {
  disconnected,
  connecting,
  authenticated,
  syncing,
  ready,

  /// The server no longer accepts this credential or Worker. The Agent stops
  /// instead of retrying.
  revoked,
  closed,
}

abstract class AgentSocket {
  Stream<String> get messages;
  void send(String data);
  Future<void> close();
}

typedef SocketConnector =
    Future<AgentSocket> Function(Uri url, Map<String, String> headers);

class WebSocketAgentSocket implements AgentSocket {
  WebSocketAgentSocket(this._socket);
  final WebSocket _socket;

  @override
  Stream<String> get messages =>
      _socket.where((data) => data is String).cast<String>();

  @override
  void send(String data) => _socket.add(data);

  @override
  Future<void> close() => _socket.close();
}

Future<AgentSocket> connectWebSocket(
  Uri url,
  Map<String, String> headers,
) async => WebSocketAgentSocket(
  await WebSocket.connect(url.toString(), headers: headers),
);

/// The gateway address for a server base URL.
Uri gatewayUrl(String serverUrl, String workerId, String sessionId) {
  final base = Uri.parse(serverUrl);
  return base.replace(
    scheme: base.scheme == 'https' ? 'wss' : 'ws',
    path: '${base.path}/api/workspace-gateway/connect'.replaceAll('//', '/'),
    queryParameters: {'workerId': workerId, 'workerSessionId': sessionId},
  );
}

class SessionInfo {
  const SessionInfo(this.sessionId, this.epoch, this.leaseSeconds);
  final String sessionId;
  final int epoch;
  final int leaseSeconds;
}

/// One WebSocket connection for one Worker, with this reconnect sequence:
///
/// 1. claim a new session epoch (signed nonce over HTTPS);
/// 2. open the gateway socket and say hello;
/// 3. report the journal (`unreconciledAssignmentIds`);
/// 4. reconcile with the server's answer ([onSync]);
/// 5. only then `ready`: buffered commands are released and new work may start.
class AgentConnection {
  AgentConnection({
    required this.workerId,
    required this.serverUrl,
    required this.keyStore,
    required this.api,
    required this.unreconciledIds,
    required this.onSync,
    required this.onMessage,
    SocketConnector? connector,
    this.clientVersion = '0.1.0',
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 60),
    this.heartbeatInterval = const Duration(seconds: 30),
    this.stepTimeout = const Duration(seconds: 30),
    Random? random,
    this.onFault,
    this.onSession,
    this.readiness,
  }) : connector = connector ?? connectWebSocket,
       _random = random ?? Random();

  final String workerId;
  final String serverUrl;
  final KeyStore keyStore;
  final ServerApi api;
  final SocketConnector connector;
  final String clientVersion;
  final Duration baseDelay;
  final Duration maxDelay;
  final Duration heartbeatInterval;
  final Duration stepTimeout;
  final Random _random;

  final Future<List<String>> Function() unreconciledIds;
  final Future<void> Function(Map<String, Object?> syncPayload) onSync;
  final void Function(Map<String, Object?> message) onMessage;
  final void Function(String point)? onFault;

  /// Called with every new session grant (the artifact client needs its token).
  final void Function(SessionGrant grant)? onSession;

  /// The Agent's own readiness report, sent in `hello` so the server can show it.
  final Future<Map<String, Object?>> Function()? readiness;

  final _ids = MessageIds();
  final _phases = StreamController<ConnectionPhase>.broadcast();
  ConnectionPhase _phase = ConnectionPhase.disconnected;
  SessionInfo? _session;
  AgentSocket? _socket;
  bool _stopped = false;
  Completer<void>? _wake;
  final List<Map<String, Object?>> _held = [];
  int activeAssignments = 0;
  int attempts = 0;

  ConnectionPhase get phase => _phase;
  SessionInfo? get session => _session;
  Stream<ConnectionPhase> get phases => _phases.stream;

  void _set(ConnectionPhase next) {
    if (_phase == next) return;
    _phase = next;
    if (!_phases.isClosed) _phases.add(next);
  }

  /// Sends one envelope. False when the connection is not ready for traffic.
  bool send(Map<String, Object?> message) {
    final socket = _socket;
    if (socket == null) return false;
    if (_phase != ConnectionPhase.ready &&
        _phase != ConnectionPhase.syncing &&
        _phase != ConnectionPhase.authenticated) {
      return false;
    }
    socket.send(encodeFrame(message));
    return true;
  }

  MessageIds get ids => _ids;

  /// Waits until the connection is ready, or throws on timeout.
  Future<void> whenReady({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_phase == ConnectionPhase.ready) return;
    await phases.firstWhere((p) => p == ConnectionPhase.ready).timeout(timeout);
  }

  /// Runs until [stop] or until the server revokes the credential.
  Future<void> run() async {
    while (!_stopped) {
      attempts += 1;
      try {
        await _connectOnce();
        // Connected and served until the socket ended; start the delay over.
        attempts = 0;
      } on ServerRefusal catch (refusal) {
        if (refusal.fatal) {
          _set(ConnectionPhase.revoked);
          return;
        }
      } on Object {
        // Network or protocol trouble: fall through to the delay.
      }
      if (_stopped) break;
      _set(ConnectionPhase.disconnected);
      await _sleep(_delay());
    }
    _set(ConnectionPhase.closed);
  }

  Duration _delay() {
    final exponent = min(max(attempts - 1, 0), 8);
    final full = min(
      baseDelay.inMicroseconds * (1 << exponent),
      maxDelay.inMicroseconds,
    );
    // Jitter: between half and the full delay, so many Agents do not retry together.
    return Duration(
      microseconds: (full * (0.5 + _random.nextDouble() / 2)).round(),
    );
  }

  Future<void> _sleep(Duration delay) async {
    final wake = _wake = Completer<void>();
    await Future.any([Future<void>.delayed(delay), wake.future]);
    _wake = null;
  }

  Future<void> _connectOnce() async {
    _set(ConnectionPhase.connecting);
    final key = await keyStore.load();
    if (key == null) throw ServerRefusal(401, 'no key is stored');

    // 1. Claim the epoch: a newer login makes every older session stale.
    final nonce = await api.nonce(workerId);
    final signature = await signMessage(
      key,
      actionMessage('session', workerId, nonce.nonceId, nonce.nonce),
    );
    final grant = await api.connectSession(
      workerId: workerId,
      nonceId: nonce.nonceId,
      signature: signature,
      clientVersion: clientVersion,
    );
    _session = SessionInfo(grant.sessionId, grant.epoch, grant.leaseSeconds);
    onSession?.call(grant);
    onFault?.call('after-epoch-claim');
    if (_stopped) return;

    // 2. Socket and hello.
    final socket = await connector(
      gatewayUrl(serverUrl, workerId, grant.sessionId),
      {'Authorization': 'Bearer ${grant.sessionToken}'},
    ).timeout(stepTimeout);
    _socket = socket;
    final closed = Completer<void>();
    final helloAck = Completer<Map<String, Object?>>();
    final syncResult = Completer<Map<String, Object?>>();
    String? helloId;
    String? syncId;
    Timer? heartbeat;

    final subscription = socket.messages.listen(
      (raw) {
        final message = decodeFrame(raw);
        if (message == null) return;
        final type = message['type'];
        if (type == 'workspace.hello.ack' &&
            message['correlationId'] == helloId &&
            !helloAck.isCompleted) {
          final payload = message['payload'];
          helloAck.complete(
            payload is Map<String, Object?> ? payload : <String, Object?>{},
          );
        } else if (type == 'workspace.sync.result' &&
            message['correlationId'] == syncId &&
            !syncResult.isCompleted) {
          final payload = message['payload'];
          syncResult.complete(
            payload is Map<String, Object?> ? payload : <String, Object?>{},
          );
        } else if (type == 'workspace.heartbeat.ack') {
          // Liveness only.
        } else if (_phase == ConnectionPhase.ready) {
          onMessage(message);
        } else if (_held.length < 256) {
          _held.add(message);
        }
      },
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
      onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      },
    );

    try {
      _set(ConnectionPhase.authenticated);
      Map<String, Object?>? report;
      try {
        report = await readiness?.call();
      } on Object {
        report =
            null; // an unknown readiness is reported as nothing, not as ready
      }
      final hello = envelope(_ids, 'workspace.hello', {
        'name': 'syntila-worker',
        'workspaceVersion': clientVersion,
        'capabilities': const <String>[],
        if (report != null) 'readiness': report,
      });
      helloId = hello['messageId'] as String;
      socket.send(encodeFrame(hello));
      final ack = await Future.any<Map<String, Object?>?>([
        helloAck.future,
        closed.future.then((_) => null),
      ]).timeout(stepTimeout);
      if (ack == null) return;
      final idle = ack['idleHeartbeatIntervalMs'];
      final interval = idle is int && idle >= 1000
          ? Duration(milliseconds: idle)
          : heartbeatInterval;
      onFault?.call('after-hello');

      // 3. Report the journal.
      _set(ConnectionPhase.syncing);
      final unreconciled = await unreconciledIds();
      final request = envelope(_ids, 'workspace.sync.request', {
        if (unreconciled.isNotEmpty) 'unreconciledAssignmentIds': unreconciled,
      });
      syncId = request['messageId'] as String;
      socket.send(encodeFrame(request));
      final answer = await Future.any<Map<String, Object?>?>([
        syncResult.future,
        closed.future.then((_) => null),
      ]).timeout(stepTimeout);
      if (answer == null) return;

      // 4. Reconcile with the server before anything new starts.
      await onSync(answer);
      onFault?.call('after-reconcile');

      // 5. Ready: release commands that arrived meanwhile, in order.
      _set(ConnectionPhase.ready);
      final held = List<Map<String, Object?>>.of(_held);
      _held.clear();
      for (final message in held) {
        onMessage(message);
      }
      heartbeat = Timer.periodic(interval, (_) {
        final current = _session;
        if (current == null) return;
        send(
          envelope(_ids, 'workspace.heartbeat', {
            'sessionId': current.sessionId,
            'status': 'online',
            'activeAssignments': activeAssignments,
          }),
        );
      });
      await closed.future;
    } finally {
      heartbeat?.cancel();
      _held.clear();
      _socket = null;
      await subscription.cancel();
      try {
        await socket.close();
      } on Object {
        // Already closed.
      }
    }
  }

  /// Drops the current socket as a network failure would; the loop reconnects.
  Future<void> dropSocket() async {
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }

  Future<void> stop() async {
    _stopped = true;
    _wake?.complete();
    await dropSocket();
    if (!_phases.isClosed && _phase != ConnectionPhase.revoked) {
      _set(ConnectionPhase.closed);
    }
  }
}
