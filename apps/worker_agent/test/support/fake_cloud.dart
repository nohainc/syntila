import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';

class FakeWorker {
  FakeWorker(this.id, this.workerType, this.name);
  final String id;
  final String workerType;
  final String name;
  String? publicKey;
  int epoch = 0;
  String? sessionId;
  String? sessionToken;
}

class FakeAssignment {
  FakeAssignment(this.id, this.workerId, this.attemptId, this.payload);
  final String id;
  final String workerId;
  final String attemptId;
  final Map<String, Object?> payload;
  String status = 'created';
  bool cancelRequested = false;
  Map<String, Object?>? terminal;
  String? terminalType;
  int acks = 0;
  int startAcks = 0;
}

class _Socket {
  _Socket(this.socket, this.workerId, this.sessionId, this.epoch);
  final WebSocket socket;
  final String workerId;
  final String sessionId;
  final int epoch;
}

/// An in-process stand-in for the server side of ADR-034: pairing, signed
/// nonces, an epoch per session, and a fence that rejects any write from a
/// session that is no longer current. It speaks the Workspace gateway frames.
class FakeCloud {
  FakeCloud._(this._server);

  final HttpServer _server;
  final Map<String, FakeWorker> workers = {};
  final Map<String, FakeAssignment> assignments = {};
  final Map<String, Map<String, Object?>> _challenges = {};
  final Map<String, ({String workerId, String nonce, DateTime expires})>
  _nonces = {};
  final List<_Socket> _sockets = [];
  final List<String> rejected = [];
  final List<String> log = [];

  /// When false a superseded session keeps its socket, so a test can send a
  /// late result from it and watch the fence refuse it.
  bool closeSupersededSockets = true;
  bool grantPermits = true;

  /// While true every request is refused with 503, so an Agent that lost its
  /// connection cannot get back until the test lets it.
  bool offline = false;
  int _counter = 0;

  static Future<FakeCloud> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cloud = FakeCloud._(server);
    server.listen(cloud._handle);
    return cloud;
  }

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> close() async {
    for (final s in List.of(_sockets)) {
      await s.socket.close();
    }
    await _server.close(force: true);
  }

  String _id(String prefix) => '$prefix-${++_counter}';

  FakeWorker createWorker({
    String workerType = 'chatgpt',
    String name = 'Writer',
  }) {
    final worker = FakeWorker(_id('wrk'), workerType, name);
    workers[worker.id] = worker;
    return worker;
  }

  PairingCode createPairing(
    String workerId, {
    Duration ttl = const Duration(minutes: 10),
  }) {
    final challengeId = _id('wpc');
    final secret = 'secret-${_id('s')}-0123456789abcdef';
    _challenges[challengeId] = {
      'workerId': workerId,
      'secret': secret,
      'expires': DateTime.now().add(ttl),
      'consumed': false,
    };
    return PairingCode(
      serverUrl: url,
      workerId: workerId,
      challengeId: challengeId,
      secret: secret,
    );
  }

  /// Sends a command to the Worker's current session (or holds it until the
  /// Worker syncs, like the server's command inbox).
  FakeAssignment dispatch(
    String workerId, {
    String? assignmentId,
    Map<String, Object?>? payload,
  }) {
    final id = assignmentId ?? _id('asg');
    final assignment = FakeAssignment(id, workerId, 'att-$id', {
      'prompt': 'hello',
      'timeoutMs': 60000,
      'queueWaitTimeoutMs': 1000,
      ...?payload,
    });
    assignments[id] = assignment;
    _push(assignment);
    return assignment;
  }

  /// Sends a cancel for a command the Worker has not received (it was offline).
  void pushCancelOnly(FakeAssignment assignment) {
    assignment.cancelRequested = true;
    final socket = _current(assignment.workerId);
    if (socket != null) {
      _sendTo(socket, _assignmentFrame('assignment.cancel', assignment, {}));
    }
  }

  /// Registers a command without sending it.
  FakeAssignment createAssignment(String workerId, {String? assignmentId}) {
    final id = assignmentId ?? _id('asg');
    final assignment = FakeAssignment(id, workerId, 'att-$id', {
      'prompt': 'hello',
      'timeoutMs': 60000,
      'queueWaitTimeoutMs': 1000,
    });
    assignments[id] = assignment;
    return assignment;
  }

  void push(FakeAssignment assignment) => _push(assignment);

  void cancel(String assignmentId) {
    final assignment = assignments[assignmentId]!;
    assignment.cancelRequested = true;
    final socket = _current(assignment.workerId);
    if (socket != null) {
      _sendTo(socket, _assignmentFrame('assignment.cancel', assignment, {}));
    }
  }

  Map<String, Object?> _assignmentFrame(
    String type,
    FakeAssignment a,
    Map<String, Object?> payload,
  ) => {
    'protocol': wireProtocol,
    'protocolVersion': wireProtocolVersion,
    'messageId': 'cloud-${++_counter}',
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'type': type,
    'executionWorkspaceId': 'ws-fake',
    'workspaceRuntimeId': 'rt-fake',
    'workerId': a.workerId,
    'runId': 'run-${a.id}',
    'taskId': 'task-${a.id}',
    'attemptId': a.attemptId,
    'assignmentId': a.id,
    'idempotencyKey': 'idem-${a.id}',
    'payload': payload,
  };

  _Socket? _current(String workerId) {
    final worker = workers[workerId];
    if (worker == null) return null;
    for (final s in _sockets.reversed) {
      if (s.workerId == workerId && s.epoch == worker.epoch) return s;
    }
    return null;
  }

  /// Number of sockets currently open for [workerId], current or not.
  int socketCount(String workerId) =>
      _sockets.where((s) => s.workerId == workerId).length;

  Future<void> dropSockets(String workerId) async {
    for (final s in _sockets.where((s) => s.workerId == workerId).toList()) {
      await s.socket.close();
    }
  }

  void _push(FakeAssignment a) {
    final socket = _current(a.workerId);
    if (socket == null) return;
    _sendTo(socket, _assignmentFrame('assignment.start', a, a.payload));
  }

  void _sendTo(_Socket socket, Map<String, Object?> frame) {
    try {
      socket.socket.add(jsonEncode(frame));
    } on Object {
      // The socket is gone.
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (offline) {
      request.response.statusCode = 503;
      await request.response.close();
      return;
    }
    try {
      if (request.uri.path == '/api/workspace-gateway/connect') {
        await _connect(request);
        return;
      }
      final body =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
      Map<String, Object?> answer;
      switch (request.uri.path) {
        case '/api/worker-agent/claim':
          answer = {'pairing': await _claim(body)};
        case '/api/worker-agent/nonce':
          answer = {'nonce': _nonce(body)};
        case '/api/worker-agent/sessions':
          answer = {'session': await _session(body)};
        case '/api/worker-agent/rotate':
          answer = {'credential': await _rotate(body)};
        default:
          throw _Refusal(404, 'not found');
      }
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(answer));
    } on _Refusal catch (refusal) {
      request.response
        ..statusCode = refusal.status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': refusal.message}));
    } on Object catch (error) {
      request.response
        ..statusCode = 500
        ..write('$error');
    }
    await request.response.close();
  }

  Future<Map<String, Object?>> _claim(Map<String, Object?> body) async {
    final challenge = _challenges[body['challengeId']];
    if (challenge == null || challenge['secret'] != body['secret']) {
      throw _Refusal(403, 'unknown challenge');
    }
    if (challenge['consumed'] == true ||
        (challenge['expires'] as DateTime).isBefore(DateTime.now())) {
      throw _Refusal(410, 'expired or used');
    }
    final workerId = challenge['workerId'] as String;
    final publicKey = body['publicKey'] as String;
    final ok = await verifyMessage(
      publicKey,
      pairingMessage(body['challengeId'] as String, workerId, publicKey),
      body['signature'] as String,
    );
    if (!ok) throw _Refusal(401, 'bad signature');
    final worker = workers[workerId]!;
    if (workers.values.any((w) => w.publicKey == publicKey)) {
      throw _Refusal(409, 'key already in use');
    }
    challenge['consumed'] = true;
    worker.publicKey = publicKey;
    log.add('claimed $workerId');
    return {'workerId': workerId};
  }

  Map<String, Object?> _nonce(Map<String, Object?> body) {
    final worker = workers[body['workerId']];
    if (worker == null || worker.publicKey == null) {
      throw _Refusal(404, 'not paired');
    }
    final nonceId = _id('nonce');
    final nonce = 'n-${_id('v')}-abcdefghijklmnop';
    _nonces[nonceId] = (
      workerId: worker.id,
      nonce: nonce,
      expires: DateTime.now().add(const Duration(seconds: 60)),
    );
    return {'nonceId': nonceId, 'nonce': nonce};
  }

  /// A nonce is spent whether or not the signature is right.
  ({String workerId, String nonce}) _spend(String nonceId, String workerId) {
    final entry = _nonces.remove(nonceId);
    if (entry == null ||
        entry.workerId != workerId ||
        entry.expires.isBefore(DateTime.now())) {
      throw _Refusal(401, 'nonce is not valid');
    }
    return (workerId: entry.workerId, nonce: entry.nonce);
  }

  Future<Map<String, Object?>> _session(Map<String, Object?> body) async {
    final workerId = body['workerId'] as String;
    final spent = _spend(body['nonceId'] as String, workerId);
    final worker = workers[workerId];
    if (worker == null || worker.publicKey == null) {
      throw _Refusal(404, 'not paired');
    }
    final ok = await verifyMessage(
      worker.publicKey!,
      actionMessage(
        'session',
        workerId,
        body['nonceId'] as String,
        spent.nonce,
      ),
      body['signature'] as String,
    );
    if (!ok) throw _Refusal(401, 'bad signature');
    worker.epoch += 1;
    worker.sessionId = _id('ses');
    worker.sessionToken = 'tok-${_id('t')}';
    if (closeSupersededSockets) {
      for (final s
          in _sockets
              .where((s) => s.workerId == workerId && s.epoch < worker.epoch)
              .toList()) {
        await s.socket.close();
      }
    }
    log.add('session $workerId epoch ${worker.epoch}');
    return {
      'sessionId': worker.sessionId,
      'epoch': worker.epoch,
      'sessionToken': worker.sessionToken,
      'leaseSeconds': 300,
      'actorId': 'act-$workerId',
    };
  }

  Future<Map<String, Object?>> _rotate(Map<String, Object?> body) async {
    final workerId = body['workerId'] as String;
    final spent = _spend(body['nonceId'] as String, workerId);
    final worker = workers[workerId];
    if (worker == null || worker.publicKey == null) {
      throw _Refusal(404, 'not paired');
    }
    final next = body['newPublicKey'] as String;
    final nonceId = body['nonceId'] as String;
    final oldOk = await verifyMessage(
      worker.publicKey!,
      actionMessage('rotate', workerId, nonceId, spent.nonce, next),
      body['signature'] as String,
    );
    final newOk = await verifyMessage(
      next,
      actionMessage('rotate-new', workerId, nonceId, spent.nonce, next),
      body['newKeySignature'] as String,
    );
    if (!oldOk || !newOk) throw _Refusal(401, 'bad signature');
    worker.publicKey = next;
    worker.epoch += 1;
    worker.sessionId = null;
    for (final s in _sockets.where((s) => s.workerId == workerId).toList()) {
      await s.socket.close();
    }
    return {'rotated': true};
  }

  Future<void> _connect(HttpRequest request) async {
    final workerId = request.uri.queryParameters['workerId'];
    final sessionId = request.uri.queryParameters['workerSessionId'];
    final auth = request.headers.value('authorization');
    final worker = workers[workerId];
    if (worker == null ||
        worker.sessionId != sessionId ||
        auth != 'Bearer ${worker.sessionToken}') {
      request.response.statusCode = 401;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    final entry = _Socket(socket, worker.id, sessionId!, worker.epoch);
    _sockets.add(entry);
    socket.listen(
      (data) => _onFrame(entry, data),
      onDone: () => _sockets.remove(entry),
      onError: (Object _) => _sockets.remove(entry),
    );
  }

  bool _isCurrent(_Socket socket) =>
      workers[socket.workerId]?.epoch == socket.epoch;

  void _onFrame(_Socket socket, Object? data) {
    final frame = decodeFrame(data);
    if (frame == null) return;
    final type = frame['type'] as String;
    final base = {
      'protocol': wireProtocol,
      'protocolVersion': wireProtocolVersion,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'executionWorkspaceId': 'ws-fake',
      'workspaceRuntimeId': 'rt-fake',
    };
    void reply(String replyType, Map<String, Object?> payload) =>
        _sendTo(socket, {
          ...base,
          'messageId': 'cloud-${++_counter}',
          'correlationId': frame['messageId'],
          'type': replyType,
          'payload': payload,
        });
    switch (type) {
      case 'workspace.hello':
        reply('workspace.hello.ack', {
          'sessionId': socket.sessionId,
          'cloudCapabilities': const <String>[],
        });
      case 'workspace.heartbeat':
        reply('workspace.heartbeat.ack', {'acknowledged': true});
      case 'workspace.sync.request':
        final states = [
          for (final a in assignments.values.where(
            (a) => a.workerId == socket.workerId,
          ))
            {'assignmentId': a.id, 'status': a.status},
        ];
        reply('workspace.sync.result', {
          'activeAssignmentIds': [
            for (final a in assignments.values)
              if (a.workerId == socket.workerId && !_terminal(a.status)) a.id,
          ],
          'assignmentStates': states,
        });
        // The command inbox: commands that never got an acknowledgement are
        // presented again once the Worker has synchronized.
        for (final a in assignments.values) {
          if (a.workerId == socket.workerId && a.status == 'created') {
            Timer(const Duration(milliseconds: 20), () {
              if (_isCurrent(socket)) _push(a);
            });
          }
          if (a.workerId == socket.workerId &&
              a.cancelRequested &&
              !_terminal(a.status)) {
            Timer(const Duration(milliseconds: 30), () {
              if (_isCurrent(socket)) {
                _sendTo(socket, _assignmentFrame('assignment.cancel', a, {}));
              }
            });
          }
        }
      default:
        _onAssignmentFrame(socket, type, frame);
    }
  }

  static bool _terminal(String status) =>
      const {'completed', 'failed', 'cancelled', 'timed_out'}.contains(status);

  void _onAssignmentFrame(
    _Socket socket,
    String type,
    Map<String, Object?> frame,
  ) {
    final id = frame['assignmentId'];
    final assignment = id is String ? assignments[id] : null;
    if (assignment == null) return;
    // The fence: a session that is no longer current changes nothing, and
    // learns nothing about it.
    if (!_isCurrent(socket) ||
        assignment.workerId != socket.workerId ||
        frame['attemptId'] != assignment.attemptId) {
      rejected.add('$type:$id:epoch${socket.epoch}');
      return;
    }
    final payload = (frame['payload'] as Map?)?.cast<String, Object?>() ?? {};
    switch (type) {
      case 'assignment.ack':
        assignment.acks += 1;
        if (payload['accepted'] == true && assignment.status == 'created') {
          assignment.status = 'accepted';
        }
      case 'assignment.start.permit.request':
        if (grantPermits && !assignment.cancelRequested) {
          _sendTo(
            socket,
            _assignmentFrame('assignment.start.permit.grant', assignment, {
              'granted': true,
              'permitId': 'permit-${assignment.id}',
              'expiresAt': DateTime.now()
                  .add(const Duration(minutes: 5))
                  .toUtc()
                  .toIso8601String(),
            }),
          );
        }
      case 'assignment.start.ack':
        assignment.startAcks += 1;
        if (!_terminal(assignment.status)) assignment.status = 'started';
      case 'assignment.result':
      case 'assignment.error':
      case 'assignment.cancelled':
        if (_terminal(assignment.status)) {
          _ackTerminal(socket, assignment);
          return;
        }
        assignment.terminalType = type;
        assignment.terminal = payload;
        assignment.status = type == 'assignment.result'
            ? 'completed'
            : type == 'assignment.error'
            ? 'failed'
            : 'cancelled';
        _ackTerminal(socket, assignment);
    }
  }

  void _ackTerminal(_Socket socket, FakeAssignment a) {
    _sendTo(
      socket,
      _assignmentFrame('assignment.ack', a, {
        'terminal': true,
        'status': a.status,
      }),
    );
  }
}

class _Refusal implements Exception {
  _Refusal(this.status, this.message);
  final int status;
  final String message;
}
