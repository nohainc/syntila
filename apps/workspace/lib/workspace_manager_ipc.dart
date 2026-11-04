import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'local_management_transport.dart';
import 'windows_native.dart';
export 'local_management_transport.dart' show workspaceManagerEndpoint;

const workspaceManagerProtocolName = 'syntila.workspace-manager-ipc';
const workspaceManagerProtocolVersion = 1;

/// Optional command groups this build serves (see
/// `docs/specifications/WORKER_PLUGIN_MANAGEMENT_IPC_V1.md`).
const workspaceManagerCapabilities = <String>['plugins.v1'];
const _maxFrameBytes = 1024 * 1024;
const _handshakeTimeout = Duration(seconds: 5);

typedef WorkspaceManagerRequestHandler = Future<Object?> Function(
  String command,
  Map<String, Object?> payload,
);
typedef WorkspaceManagerSnapshotProvider = Future<Map<String, Object?>>
    Function();

class WorkspaceManagerProtocolException implements Exception {
  const WorkspaceManagerProtocolException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Local management RPC over a private Unix-domain socket. Access is limited
/// to the owning OS account by the 0700 parent directory, 0600 socket and an
/// additional per-installation capability key. The wire protocol is transport
/// independent and versioned separately from Cloud and Worker protocols.
class WorkspaceManagerIpcServer {
  WorkspaceManagerIpcServer({
    required this.runtimeDirectory,
    required this.requestHandler,
    required this.snapshotProvider,
    required this.serviceVersion,
    this.eventStream,
  });

  final Directory runtimeDirectory;
  final WorkspaceManagerRequestHandler requestHandler;
  final WorkspaceManagerSnapshotProvider snapshotProvider;
  final String serviceVersion;
  final Stream<Map<String, Object?>>? eventStream;

  ServerSocket? _server;
  StreamSubscription<LocalManagementChannel>? _acceptSubscription;
  WindowsPipeListener? _windowsListener;
  StreamSubscription<Map<String, Object?>>? _eventSubscription;
  final Set<LocalManagementChannel> _clients = {};
  final Set<LocalManagementChannel> _subscribers = {};
  final Random _random = Random.secure();
  String? _key;

  File get _keyFile => File('${runtimeDirectory.path}/manager-ipc.key');
  String get socketPath => workspaceManagerEndpoint(runtimeDirectory);

  Future<void> start() async {
    await runtimeDirectory.create(recursive: true);
    await _restrict(runtimeDirectory.path, directory: true);
    _key = await _loadOrCreateKey();
    if (Platform.isWindows) {
      final listener = WindowsPipeListener();
      listener.start(socketPath);
      _windowsListener = listener;
      _acceptSubscription = listener.connections.listen(_accept);
      _eventSubscription = eventStream?.listen(_publishEvent);
      return;
    }
    final socketEntity = await FileSystemEntity.type(
      socketPath,
      followLinks: false,
    );
    if (socketEntity != FileSystemEntityType.notFound) {
      await File(socketPath).delete();
    }
    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
      shared: false,
    );
    _server = server;
    await _restrict(socketPath, directory: false);
    _acceptSubscription = server
        .map<LocalManagementChannel>(UnixManagementChannel.new)
        .listen(_accept);
    _eventSubscription = eventStream?.listen(_publishEvent);
  }

  Future<void> _restrict(String path, {required bool directory}) async {
    if (Platform.isWindows) {
      WindowsNative.securePath(path);
      return;
    }
    final result =
        await Process.run('chmod', [directory ? '700' : '600', path]);
    if (result.exitCode != 0) {
      throw StateError('Could not secure the Workspace Manager IPC endpoint.');
    }
  }

  Future<String> _loadOrCreateKey() async {
    final type = await FileSystemEntity.type(_keyFile.path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      final existing = (await _keyFile.readAsString()).trim();
      if (RegExp(r'^[a-f0-9]{64}$').hasMatch(existing)) {
        await _restrict(_keyFile.path, directory: false);
        return existing;
      }
      throw StateError('Workspace Manager IPC key is invalid.');
    }
    if (type != FileSystemEntityType.notFound) {
      throw StateError('Workspace Manager IPC key must be a regular file.');
    }
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final key =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    await _keyFile.writeAsString(key, flush: true);
    await _restrict(_keyFile.path, directory: false);
    return key;
  }

  void _accept(LocalManagementChannel socket) {
    _clients.add(socket);
    unawaited(_handleClient(socket));
  }

  Future<void> _handleClient(LocalManagementChannel socket) async {
    var authenticated = false;
    try {
      final lines = managementLines(socket.input);
      final iterator = StreamIterator<String>(lines);
      try {
        if (!await iterator.moveNext().timeout(_handshakeTimeout)) {
          throw const WorkspaceManagerProtocolException(
            'handshake_timeout',
            'IPC handshake timed out.',
          );
        }
        final hello = _decodeFrame(iterator.current);
        if (hello['type'] != 'hello' ||
            hello['protocol'] != workspaceManagerProtocolName) {
          throw const WorkspaceManagerProtocolException(
            'invalid_handshake',
            'Expected a Workspace Manager protocol handshake.',
          );
        }
        final version = hello['version'];
        if (version != workspaceManagerProtocolVersion) {
          throw WorkspaceManagerProtocolException(
            'version_mismatch',
            'Supported protocol version is $workspaceManagerProtocolVersion.',
          );
        }
        if (!_constantTimeEquals(hello['key'], _key)) {
          throw const WorkspaceManagerProtocolException(
            'unauthorized',
            'Local Workspace Manager authentication failed.',
          );
        }
        authenticated = true;
        final snapshot = await snapshotProvider();
        _write(socket, {
          'type': 'hello',
          'protocol': workspaceManagerProtocolName,
          'version': workspaceManagerProtocolVersion,
          'serviceVersion': serviceVersion,
          // Additive feature discovery; the integer version stays 1 so older
          // clients keep working. A client missing a capability reports an
          // outdated service instead of sending unsupported commands.
          'capabilities': workspaceManagerCapabilities,
          'snapshot': snapshot,
        });
        while (await iterator.moveNext()) {
          final message = _decodeFrame(iterator.current);
          if (message['type'] != 'request' || message['id'] is! String) {
            _writeError(socket, message['id']?.toString(), 'invalid_request',
                'Malformed request envelope.');
            continue;
          }
          final id = message['id'] as String;
          if (message['version'] != workspaceManagerProtocolVersion) {
            _writeError(socket, id, 'version_mismatch',
                'Request protocol version is not supported.');
            continue;
          }
          final command = message['command'];
          final payloadValue = message['payload'];
          if (command is! String ||
              (payloadValue != null && payloadValue is! Map)) {
            _writeError(socket, id, 'invalid_request',
                'Command and object payload are required.');
            continue;
          }
          final payload = payloadValue == null
              ? <String, Object?>{}
              : Map<String, Object?>.from(payloadValue as Map);
          if (command == 'events.subscribe') {
            _subscribers.add(socket);
            _write(socket, {'type': 'response', 'id': id, 'ok': true});
            continue;
          }
          if (command == 'events.unsubscribe') {
            _subscribers.remove(socket);
            _write(socket, {'type': 'response', 'id': id, 'ok': true});
            continue;
          }
          try {
            final result = await requestHandler(command, payload);
            _write(socket, {
              'type': 'response',
              'id': id,
              'ok': true,
              if (result != null) 'result': result,
            });
          } on WorkspaceManagerProtocolException catch (error) {
            _writeError(socket, id, error.code, error.message);
          } on Object {
            _writeError(socket, id, 'command_failed',
                'Workspace Manager command failed.');
          }
        }
      } finally {
        await iterator.cancel();
      }
    } on WorkspaceManagerProtocolException catch (error) {
      if (!authenticated) {
        try {
          _write(socket, {
            'type': 'error',
            'protocol': workspaceManagerProtocolName,
            'version': workspaceManagerProtocolVersion,
            'error': {'code': error.code, 'message': error.message},
          });
          await socket.flush().timeout(_handshakeTimeout);
        } on Object {
          // Peer closure during a rejected handshake must not stop the service.
        }
      }
    } on Object {
      // A malformed or disconnected local client is isolated to that socket.
    } finally {
      _subscribers.remove(socket);
      _clients.remove(socket);
      socket.destroy();
    }
  }

  Map<String, Object?> _decodeFrame(String line) {
    if (utf8.encode(line).length > _maxFrameBytes) {
      throw const WorkspaceManagerProtocolException(
        'frame_too_large',
        'IPC frame exceeds the one-megabyte limit.',
      );
    }
    final decoded = jsonDecode(line);
    if (decoded is! Map) {
      throw const WorkspaceManagerProtocolException(
        'invalid_frame',
        'IPC frames must be JSON objects.',
      );
    }
    return Map<String, Object?>.from(decoded);
  }

  bool _constantTimeEquals(Object? candidate, String? expected) {
    if (candidate is! String || expected == null) return false;
    final left = utf8.encode(candidate);
    final right = utf8.encode(expected);
    var difference = left.length ^ right.length;
    final length = max(left.length, right.length);
    for (var index = 0; index < length; index++) {
      difference |= (index < left.length ? left[index] : 0) ^
          (index < right.length ? right[index] : 0);
    }
    return difference == 0;
  }

  void _write(LocalManagementChannel socket, Map<String, Object?> message) {
    final line = jsonEncode(message);
    if (utf8.encode(line).length > _maxFrameBytes) {
      _writeError(socket, null, 'response_too_large',
          'IPC response exceeds the one-megabyte limit.');
      return;
    }
    socket.write('$line\n');
  }

  void _writeError(LocalManagementChannel socket, String? id, String code,
          String message) =>
      _write(socket, {
        'type': 'response',
        if (id != null) 'id': id,
        'ok': false,
        'error': {'code': code, 'message': message},
      });

  void _publishEvent(Map<String, Object?> event) {
    for (final socket in List<LocalManagementChannel>.of(_subscribers)) {
      try {
        _write(socket, {...event, 'type': 'event'});
      } on Object {
        _subscribers.remove(socket);
      }
    }
  }

  Future<void> close() async {
    await _eventSubscription?.cancel();
    await _acceptSubscription?.cancel();
    for (final socket in _clients.toList()) {
      socket.destroy();
    }
    _clients.clear();
    _subscribers.clear();
    await _server?.close();
    _server = null;
    await _windowsListener?.close();
    if (Platform.isWindows) return;
    final type = await FileSystemEntity.type(socketPath, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      await File(socketPath).delete();
    }
  }
}

class WorkspaceManagerIpcClient {
  WorkspaceManagerIpcClient._(
    this._socket,
    this._lineSubscription,
    this.initialSnapshot,
    this.serviceVersion,
  );

  final LocalManagementChannel _socket;
  final StreamSubscription<String> _lineSubscription;
  final Map<String, Object?> initialSnapshot;
  final String serviceVersion;
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  final Map<String, Completer<Object?>> _pending = {};
  final Random _random = Random.secure();
  bool _closed = false;
  Stream<Map<String, Object?>> get events => _events.stream;

  static Future<WorkspaceManagerIpcClient> connect({
    required String socketPath,
    required String key,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final LocalManagementChannel socket = Platform.isWindows
        ? await WindowsPipeChannel.connect(socketPath).timeout(timeout)
        : UnixManagementChannel(await Socket.connect(
            InternetAddress(socketPath, type: InternetAddressType.unix), 0,
            timeout: timeout));
    final firstLine = Completer<Map<String, Object?>>();
    late final StreamSubscription<String> subscription;
    var handshaken = false;
    WorkspaceManagerIpcClient? client;
    subscription = managementLines(socket.input).listen((line) {
      if (utf8.encode(line).length > _maxFrameBytes) {
        socket.destroy();
        return;
      }
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        socket.destroy();
        return;
      }
      final message = Map<String, Object?>.from(decoded);
      if (!handshaken) {
        if (!firstLine.isCompleted) firstLine.complete(message);
      } else {
        client?._handleLine(line);
      }
    }, onError: (Object _, StackTrace __) {
      client?._socketDisconnected();
    }, onDone: () {
      client?._socketDisconnected();
    });
    socket.write('${jsonEncode({
          'type': 'hello',
          'protocol': workspaceManagerProtocolName,
          'version': workspaceManagerProtocolVersion,
          'key': key,
        })}\n');
    Map<String, Object?> response;
    try {
      response = await firstLine.future.timeout(timeout);
    } catch (_) {
      await subscription.cancel();
      socket.destroy();
      rethrow;
    }
    if (response['type'] != 'hello' ||
        response['protocol'] != workspaceManagerProtocolName ||
        response['version'] != workspaceManagerProtocolVersion) {
      await subscription.cancel();
      socket.destroy();
      final error = response['error'];
      if (error is Map) {
        throw WorkspaceManagerProtocolException(
          error['code']?.toString() ?? 'handshake_failed',
          error['message']?.toString() ?? 'IPC handshake was rejected.',
        );
      }
      throw const WorkspaceManagerProtocolException(
        'version_mismatch',
        'Workspace Manager protocol version negotiation failed.',
      );
    }
    handshaken = true;
    final snapshot = response['snapshot'];
    final connectedClient = WorkspaceManagerIpcClient._(
      socket,
      subscription,
      snapshot is Map ? Map<String, Object?>.from(snapshot) : const {},
      response['serviceVersion']?.toString() ?? 'unknown',
    );
    // Attach after the greeting is parsed, then hand subsequent lines to the
    // client without cancelling and recreating the socket subscription.
    client = connectedClient;
    return connectedClient;
  }

  void _handleLine(String line) {
    if (utf8.encode(line).length > _maxFrameBytes) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      final message = Map<String, Object?>.from(decoded);
      if (message['type'] == 'event') {
        _events.add(message);
        return;
      }
      if (message['type'] != 'response' || message['id'] is! String) return;
      final pending = _pending.remove(message['id']);
      if (pending == null || pending.isCompleted) return;
      if (message['ok'] == true) {
        pending.complete(message['result']);
      } else {
        final error = message['error'];
        pending.completeError(WorkspaceManagerProtocolException(
          error is Map
              ? error['code']?.toString() ?? 'command_failed'
              : 'command_failed',
          error is Map
              ? error['message']?.toString() ?? 'Command failed.'
              : 'Command failed.',
        ));
      }
    } on Object {
      // Ignore malformed server events; pending requests still have timeouts.
    }
  }

  Future<Object?> request(
    String command, {
    Map<String, Object?> payload = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_closed) throw const SocketException('Workspace service is closed.');
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _socket.write('${jsonEncode({
          'type': 'request',
          'version': workspaceManagerProtocolVersion,
          'id': id,
          'command': command,
          'payload': payload,
        })}\n');
    try {
      return await completer.future.timeout(timeout);
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> subscribe() async {
    await request('events.subscribe');
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  void _socketDisconnected() {
    if (_closed) return;
    _events.add({'type': 'event', 'name': 'service.disconnected'});
    _failPending(const SocketException('Workspace service disconnected.'));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failPending(const SocketException('Workspace service client closed.'));
    _socket.destroy();
    await _lineSubscription.cancel();
    await _events.close();
  }
}

/// Reconnects after the service process restarts or a local socket is lost.
/// No periodic status polling is performed; snapshots arrive at handshake and
/// subsequent changes arrive on the event stream.
class WorkspaceManagerIpcConnection {
  WorkspaceManagerIpcConnection({
    required this.socketPath,
    required this.key,
    this.minimumRetryDelay = const Duration(milliseconds: 300),
    this.maximumRetryDelay = const Duration(seconds: 10),
  });

  final String socketPath;
  final String key;
  final Duration minimumRetryDelay;
  final Duration maximumRetryDelay;
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  WorkspaceManagerIpcClient? _client;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<void>? _reconnectLoop;
  bool _closed = false;
  bool _connected = false;
  Map<String, Object?> initialSnapshot = const {};
  String? serviceVersion;

  bool get isConnected => _connected;
  Stream<Map<String, Object?>> get events => _events.stream;

  Future<void> connect() async {
    if (_closed) {
      throw const SocketException('Workspace service client closed.');
    }
    try {
      await _connectOnce();
    } on Object {
      _scheduleReconnect();
      rethrow;
    }
  }

  Future<void> _connectOnce() async {
    if (_connected || _closed) return;
    final client = await WorkspaceManagerIpcClient.connect(
      socketPath: socketPath,
      key: key,
    );
    if (_closed) {
      await client.close();
      return;
    }
    _client = client;
    initialSnapshot = client.initialSnapshot;
    serviceVersion = client.serviceVersion;
    _connected = true;
    _events.add(
        {'type': 'event', 'name': 'ipc.connectionChanged', 'connected': true});
    _events.add({
      'type': 'event',
      'name': 'ipc.snapshot',
      'snapshot': initialSnapshot,
      'serviceVersion': serviceVersion,
    });
    _subscription = client.events.listen((event) {
      if (event['name'] == 'service.disconnected') {
        _handleDisconnect();
      } else {
        _events.add(event);
      }
    }, onError: (_) {
      _handleDisconnect();
    });
    try {
      await client.subscribe();
    } on Object {
      _handleDisconnect();
      rethrow;
    }
  }

  Future<Object?> request(
    String command, {
    Map<String, Object?> payload = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final client = _client;
    if (!_connected || client == null) {
      throw const SocketException('Workspace service is reconnecting.');
    }
    try {
      return await client.request(command, payload: payload, timeout: timeout);
    } on Object {
      _handleDisconnect();
      rethrow;
    }
  }

  void _handleDisconnect() {
    if (!_connected || _closed) return;
    _connected = false;
    _events.add(
        {'type': 'event', 'name': 'ipc.connectionChanged', 'connected': false});
    unawaited(_subscription?.cancel());
    _subscription = null;
    final client = _client;
    _client = null;
    unawaited(client?.close());
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed || _reconnectLoop != null) return;
    final future = _reconnectUntilAvailable();
    _reconnectLoop = future;
    unawaited(future.whenComplete(() {
      if (identical(_reconnectLoop, future)) _reconnectLoop = null;
    }));
  }

  Future<void> _reconnectUntilAvailable() async {
    var delay = minimumRetryDelay;
    while (!_closed && !_connected) {
      await Future<void>.delayed(delay);
      if (_closed || _connected) return;
      try {
        await _connectOnce();
        return;
      } on Object {
        final next = delay.inMilliseconds * 2;
        delay = Duration(
          milliseconds: next.clamp(
            minimumRetryDelay.inMilliseconds,
            maximumRetryDelay.inMilliseconds,
          ),
        );
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connected = false;
    await _subscription?.cancel();
    _subscription = null;
    await _client?.close();
    _client = null;
    await _events.close();
  }
}
