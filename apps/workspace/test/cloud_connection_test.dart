import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_protocol/workspace_runtime_protocol.dart'
    show workspaceRuntimeProtocolVersion;
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:syntila_workspace/cloud_connection.dart';
import 'package:test/test.dart';

import 'support/cloud_connection_test_support.dart';

void main() {
  test('connects outbound and sends hello', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    final hello =
        jsonDecode(socket.sent.single as String) as Map<String, dynamic>;
    expect(hello['protocol'], 'syntila.workspace-runtime-protocol');
    expect(hello['protocolVersion'], workspaceRuntimeProtocolVersion);
    expect(hello['type'], 'workspace.hello');
    final payload = hello['payload'] as Map<String, dynamic>;
    expect(payload['workspaceRuntimeId'], 'workspace-1');
    expect(payload['executionWorkspaceId'], 'workspace-1');
    expect(payload['capabilities'], isA<Map<String, dynamic>>());
    await connection.close();
  });

  test('refreshes catalog after initial sync and each recovered session',
      () async {
    final firstSocket = FakeSocket();
    final secondSocket = FakeSocket();
    final sockets = [firstSocket, secondSocket];
    var refreshes = 0;
    late final WorkspaceCloudConnection connection;
    connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-refresh'),
      workspaceRuntimeId: 'runtime-refresh',
      workspaceId: 'workspace-refresh',
      factory: (_) async => sockets.removeAt(0),
      workerInventoryProvider: () async => const [],
      onSessionReady: () async {
        refreshes++;
        await connection.refreshWorkerInventory();
      },
      heartbeat: const Duration(hours: 1),
      reconnectBaseDelay: const Duration(milliseconds: 1),
      reconnectMaxDelay: const Duration(milliseconds: 2),
    );

    await connection.connect();
    await completeHandshake(connection, firstSocket,
        sessionId: 'first-session');
    await waitFor(() => refreshes == 1);

    await firstSocket.controller.close();
    await waitFor(() => secondSocket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'workspace.hello'));
    await completeHandshake(connection, secondSocket,
        sessionId: 'second-session');
    await waitFor(() => refreshes == 2);

    expect(refreshes, 2);
    await connection.close();
  });

  test('hands fallback back to WSS only after sync reconciliation', () async {
    final fallback = FakeSocket();
    final recovered = FakeSocket();
    final pendingUpgrade = Completer<WorkspaceTransport>();
    var socketAttempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-handover'),
      workspaceRuntimeId: 'runtime-handover',
      workspaceId: 'workspace-handover',
      factory: (_) async {
        socketAttempts++;
        if (socketAttempts <= 2) throw const SocketException('offline');
        return pendingUpgrade.future;
      },
      fallbackFactory: (_) async => fallback,
      workerInventoryProvider: () async => const [],
      heartbeat: const Duration(hours: 1),
      webSocketFailureLimit: 2,
      webSocketProbeInterval: const Duration(milliseconds: 20),
      reconnectBaseDelay: const Duration(milliseconds: 1),
      reconnectMaxDelay: const Duration(milliseconds: 2),
    );

    Future<void> acknowledge(FakeSocket socket, String id) async {
      final messages = socket.sent
          .map((item) => jsonDecode(item as String) as Map<String, dynamic>);
      final hello =
          messages.firstWhere((item) => item['type'] == 'workspace.hello');
      socket.controller.add(jsonEncode({
        'protocol': 'syntila.workspace-runtime-protocol',
        'protocolVersion': workspaceRuntimeProtocolVersion,
        'messageId': '$id-hello-ack',
        'correlationId': hello['messageId'],
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'workspace.hello.ack',
        'workspaceRuntimeId': 'runtime-handover',
        'executionWorkspaceId': 'workspace-handover',
        'payload': {'sessionId': '$id-session'},
      }));
      await waitFor(() => socket.sent.any((item) =>
          (jsonDecode(item as String) as Map<String, dynamic>)['type'] ==
          'workspace.sync.request'));
      final sync = socket.sent
          .map((item) => jsonDecode(item as String) as Map<String, dynamic>)
          .firstWhere((item) => item['type'] == 'workspace.sync.request');
      socket.controller.add(jsonEncode({
        'protocol': 'syntila.workspace-runtime-protocol',
        'protocolVersion': workspaceRuntimeProtocolVersion,
        'messageId': '$id-sync-result',
        'correlationId': sync['messageId'],
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'workspace.sync.result',
        'workspaceRuntimeId': 'runtime-handover',
        'executionWorkspaceId': 'workspace-handover',
        'payload': {'assignmentStates': []},
      }));
      await waitFor(
          () => connection.connectionStage == WorkspaceConnectionStage.ready);
    }

    await connection.connect();
    expect(connection.activeTransportMode, 'http_long_poll');
    await acknowledge(fallback, 'fallback');
    await waitFor(() => socketAttempts == 3);
    expect(fallback.controller.isClosed, isFalse);
    expect(connection.activeTransportMode, 'http_long_poll');
    pendingUpgrade.complete(recovered);
    await waitFor(() => fallback.controller.isClosed);
    await waitFor(
        () => connection.activeTransportMode == 'switching_to_websocket');
    expect(connection.connectionStage, WorkspaceConnectionStage.authenticating);
    await acknowledge(recovered, 'recovered');
    expect(connection.activeTransportMode, 'websocket');
    await connection.close();
  });

  test('failed background probes preserve HTTPS and back off to an hour',
      () async {
    final fallback = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => throw const SocketException('WSS unavailable'),
      fallbackFactory: (_) async => fallback,
      heartbeat: const Duration(hours: 1),
      webSocketProbeInterval: const Duration(minutes: 5),
      webSocketFailureLimit: 1,
    );
    await connection.connect();
    await completeHandshake(connection, fallback);
    final session = connection.sessionId;
    expect(connection.nextWebSocketProbeDelay, const Duration(minutes: 5));
    // Immediate wake retry resets backoff, then a failure doubles it.
    await connection.retryWebSocketNow();
    expect(connection.nextWebSocketProbeDelay, const Duration(minutes: 10));
    expect(connection.sessionId, session);
    expect(connection.connectionStage, WorkspaceConnectionStage.ready);
    expect(connection.activeTransportMode, 'http_long_poll');
    expect(fallback.controller.isClosed, isFalse);
    await connection.close();
  });

  test('a fresh network client keeps an upgraded WebSocket usable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upgraded = Completer<WebSocket>();
    final listener = server.listen((request) async {
      upgraded.complete(await WebSocketTransformer.upgrade(request));
    });
    final transport = await connectWebSocketWorkspaceTransport(
      Uri.parse('ws://127.0.0.1:${server.port}/'),
    );
    final socket = await upgraded.future;
    final response = transport.messages.first;
    socket.add('alive');
    expect(await response, 'alive');
    await transport.close();
    await socket.close();
    await listener.cancel();
    await server.close(force: true);
  });

  test('timed-out probe leaves HTTPS ready and disposes a late result',
      () async {
    final fallback = FakeSocket();
    final lateSocket = FakeSocket();
    final pending = Completer<WorkspaceTransport>();
    var attempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) {
        attempts++;
        if (attempts == 1) throw const SocketException('offline');
        return pending.future;
      },
      fallbackFactory: (_) async => fallback,
      protocolHandshakeTimeout: const Duration(milliseconds: 100),
      heartbeat: const Duration(hours: 1),
      webSocketProbeInterval: const Duration(hours: 1),
      webSocketFailureLimit: 1,
    );
    await connection.connect();
    await completeHandshake(connection, fallback);
    await connection.retryWebSocketNow();
    expect(connection.connectionStage, WorkspaceConnectionStage.ready);
    expect(fallback.controller.isClosed, isFalse);
    pending.complete(lateSocket);
    await waitFor(() => lateSocket.controller.isClosed);
    expect(lateSocket.sent, isEmpty);
    await connection.close();
  });

  test('periodic failures reach the maximum retry interval', () async {
    final fallback = FakeSocket();
    var attempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async {
        attempts++;
        throw const SocketException('offline');
      },
      fallbackFactory: (_) async => fallback,
      heartbeat: const Duration(hours: 1),
      webSocketProbeInterval: const Duration(milliseconds: 10),
      webSocketProbeMaxInterval: const Duration(milliseconds: 40),
      webSocketFailureLimit: 1,
    );
    await connection.connect();
    await completeHandshake(connection, fallback);
    await waitFor(() => attempts >= 4);
    expect(
        connection.nextWebSocketProbeDelay, const Duration(milliseconds: 40));
    expect(fallback.controller.isClosed, isFalse);
    await connection.close();
  });

  test('disconnect fences a pending probe and closes its late socket',
      () async {
    final fallback = FakeSocket();
    final candidate = FakeSocket();
    final pending = Completer<WorkspaceTransport>();
    var attempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) {
        attempts++;
        if (attempts == 1) throw const SocketException('offline');
        return pending.future;
      },
      fallbackFactory: (_) async => fallback,
      heartbeat: const Duration(hours: 1),
      webSocketProbeInterval: const Duration(hours: 1),
      webSocketFailureLimit: 1,
    );
    await connection.connect();
    await completeHandshake(connection, fallback);
    final probe = connection.retryWebSocketNow();
    expect(fallback.controller.isClosed, isFalse);
    await connection.close();
    pending.complete(candidate);
    await probe;
    await waitFor(() => candidate.controller.isClosed);
    expect(connection.connectionStage, WorkspaceConnectionStage.offline);
    expect(candidate.sent, isEmpty);
  });

  test('reports Thread readiness without a local path', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    final hello =
        jsonDecode(socket.sent.single as String) as Map<String, dynamic>;
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-hello-ack',
      'correlationId': hello['messageId'],
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'workspaceRuntimeId': 'runtime-1',
      'executionWorkspaceId': 'workspace-1',
      'payload': {'sessionId': 'session-1'},
    }));
    await waitFor(() => connection.isConnected);

    connection.reportThreadStatus(
      spaceId: 'space-1',
      threadId: 'thread-1',
      workingDirectoryState: 'ready',
    );
    final status = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'thread.status');
    final payload = status['payload'] as Map<String, dynamic>;
    expect(payload['spaceId'], 'space-1');
    expect(payload['threadId'], 'thread-1');
    expect(payload.containsKey('path'), isFalse);
    expect(payload.containsKey('relativePath'), isFalse);
    await connection.close();
  });

  test('tracks authentication and synchronization stages before Ready',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-stage'),
      workspaceRuntimeId: 'runtime-stage',
      workspaceId: 'workspace-stage',
      factory: (_) async => socket,
      workerInventoryProvider: () async => const [],
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    expect(connection.connectionStage, WorkspaceConnectionStage.authenticating);
    expect(connection.isConnected, isFalse);
    final hello =
        jsonDecode(socket.sent.single as String) as Map<String, dynamic>;

    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'stage-hello-ack',
      'correlationId': hello['messageId'],
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'workspaceRuntimeId': 'runtime-stage',
      'executionWorkspaceId': 'workspace-stage',
      'payload': {'sessionId': 'session-stage'},
    }));
    await waitFor(() =>
        connection.connectionStage == WorkspaceConnectionStage.synchronizing);
    await waitFor(() => socket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'worker.inventory'));
    expect(connection.isConnected, isTrue);
    final syncRequest = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'workspace.sync.request');

    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'stage-sync-result',
      'correlationId': syncRequest['messageId'],
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.sync.result',
      'workspaceRuntimeId': 'runtime-stage',
      'executionWorkspaceId': 'workspace-stage',
      'payload': {'assignmentStates': []},
    }));
    await waitFor(
        () => connection.connectionStage == WorkspaceConnectionStage.ready);
    expect(connection.lastReadyAt, isNotNull);
    await connection.close();
  });

  test('classifies a failed WebSocket upgrade by HTTP status', () async {
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-400'),
      workspaceRuntimeId: 'runtime-400',
      workspaceId: 'workspace-400',
      factory: (_) async => throw const WebSocketException(
        'upgrade rejected',
        HttpStatus.badRequest,
      ),
    );

    await expectLater(connection.connect(), throwsA(isA<WebSocketException>()));
    expect(connection.connectionStage, WorkspaceConnectionStage.offline);
    expect(connection.lastHttpStatusCode, HttpStatus.badRequest);
    expect(connection.lastConnectionError,
        'Cloud rejected the WebSocket upgrade with HTTP 400.');
    await connection.close();
  });

  test('preflight rejects a missing runtime credential before opening socket',
      () async {
    var opened = false;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-no-credential'),
      workspaceRuntimeId: 'runtime-no-credential',
      workspaceId: 'workspace-no-credential',
      credentialAvailable: false,
      factory: (_) async {
        opened = true;
        return FakeSocket();
      },
    );

    await expectLater(
      connection.connect(),
      throwsA(isA<WorkspaceConnectionPreflightException>()),
    );
    expect(opened, isFalse);
    expect(connection.connectionStage, WorkspaceConnectionStage.offline);
    expect(connection.lastConnectionError, contains('credential is missing'));
    await connection.close();
  });

  test('manual retry opens a fresh socket without replacing the runtime',
      () async {
    final first = FakeSocket();
    final second = FakeSocket();
    var calls = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-retry'),
      workspaceRuntimeId: 'runtime-retry',
      workspaceId: 'workspace-retry',
      factory: (_) async => ++calls == 1 ? first : second,
    );

    await connection.connect();
    await connection.retryNow();

    expect(calls, 2);
    expect(connection.connectionStage, WorkspaceConnectionStage.authenticating);
    expect(connection.isConnected, isFalse);
    await connection.close();
  });

  test('hello acknowledgement timeout differs from upgrade failure', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-no-hello'),
      workspaceRuntimeId: 'runtime-no-hello',
      workspaceId: 'workspace-no-hello',
      factory: (_) async => socket,
      protocolHandshakeTimeout: const Duration(milliseconds: 20),
      reconnectBaseDelay: const Duration(milliseconds: 5),
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    await waitFor(() => connection.lastConnectionError != null);
    expect(connection.lastConnectionError,
        contains('did not acknowledge workspace.hello'));
    expect(connection.lastHttpStatusCode, isNull);
    await connection.close();
  });

  test('Cloud sync timeout is distinct from the hello handshake timeout',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-no-sync'),
      workspaceRuntimeId: 'runtime-no-sync',
      workspaceId: 'workspace-no-sync',
      factory: (_) async => socket,
      protocolHandshakeTimeout: const Duration(seconds: 1),
      syncTimeout: const Duration(milliseconds: 30),
      reconnectBaseDelay: const Duration(milliseconds: 5),
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    final hello =
        jsonDecode(socket.sent.single as String) as Map<String, dynamic>;
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'sync-timeout-hello-ack',
      'correlationId': hello['messageId'],
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'workspaceRuntimeId': 'runtime-no-sync',
      'executionWorkspaceId': 'workspace-no-sync',
      'payload': {'sessionId': 'session-no-sync'},
    }));
    await waitFor(() => connection.lastConnectionError != null);

    expect(connection.lastConnectionError,
        contains('Cloud synchronization did not complete'));
    expect(connection.connectionStage, WorkspaceConnectionStage.reconnecting);
    await connection.close();
  });

  test('uses the Gateway session for protocol heartbeats', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(milliseconds: 10),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-1',
      'correlationId': 'client-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {
        'sessionId': 'session-1',
        'heartbeatIntervalMs': 1000,
        'serverTime': DateTime.now().toUtc().toIso8601String(),
        'serverVersion': '2.0.0',
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final heartbeats = socket.sent
        .skip(1)
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .where((message) => message['type'] == 'workspace.heartbeat')
        .toList();
    expect(heartbeats, isNotEmpty);
    expect(
      (heartbeats.first['payload'] as Map<String, dynamic>)['sessionId'],
      'session-1',
    );
    expect(connection.authorizedWorkspaceIds, contains('workspace-1'));
    final sync = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'workspace.sync.request');
    expect(
      (sync['payload'] as Map<String, dynamic>)['workspaceRuntimeId'],
      'workspace-1',
    );
    await connection.close();
  });

  test('accepts a compatible newer minor protocol version', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(connection.isConnected, isTrue);
    await connection.close();
  });

  test('delivers validated Cloud update announcements to the Workspace',
      () async {
    final socket = FakeSocket();
    Map<String, Object?>? received;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      workspaceUpdateAvailableHandler: (payload) async {
        received = payload;
      },
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-update-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.update',
      'payload': {
        'version': '0.2.0',
        'channel': 'stable',
        'packageR2Key': 'workspace/releases/0.2.0/macos-arm64.tar.gz',
        'packageDigest': 'sha256:abc123',
        'signature': 'sig-1',
        'releaseNotes': 'Security fixes',
        'minSupportedWorkspaceVersion': '0.1.0',
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(received?['version'], '0.2.0');
    expect(received?['packageR2Key'],
        'workspace/releases/0.2.0/macos-arm64.tar.gz');
    await connection.close();
  });

  test('ignores an incompatible protocol major version', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );

    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': '3.0',
      'messageId': 'server-incompatible',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'should-not-be-accepted'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(connection.sessionId, isNull);
    expect(
      socket.sent.where((message) =>
          (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
          'workspace.sync.request'),
      isEmpty,
    );
    await connection.close();
  });

  test('publishes path-free Allowed Folders with the inventory snapshot',
      () async {
    final socket = FakeSocket();
    var foldersReadable = true;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      workerInventoryProvider: () async => const [],
      allowedFolderProvider: () async {
        if (!foldersReadable) throw StateError('registry unreadable');
        return const [
          {
            'id': 'folder-0123456789abcdef',
            'displayName': 'api',
            'status': 'available',
            'checkedAt': '2026-10-25T12:00:00.000Z',
          }
        ];
      },
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {
        'sessionId': 'session-1',
        'cloudCapabilities': [allowedFoldersCapability],
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    List<Map<String, dynamic>> inventories() => socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .where((message) => message['type'] == 'worker.inventory')
        .map((message) => message['payload'] as Map<String, dynamic>)
        .toList();

    await connection.refreshWorkerInventory();
    final folders = inventories().last['allowedFolders'] as List;
    expect(folders.single['id'], 'folder-0123456789abcdef');
    expect(folders.single.containsKey('path'), isFalse);

    foldersReadable = false;
    await connection.refreshWorkerInventory();
    expect(inventories().last.containsKey('allowedFolders'), isFalse,
        reason: 'An unreadable list keeps Cloud state instead of clearing it.');
    expect(inventories().last['workers'], isEmpty);
    await connection.close();
  });

  test('omits Allowed Folders when Cloud does not announce support', () async {
    final socket = FakeSocket();
    var reads = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      workerInventoryProvider: () async => const [],
      allowedFolderProvider: () async {
        reads++;
        return const [];
      },
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await connection.refreshWorkerInventory();
    final payload = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .lastWhere((message) =>
            message['type'] ==
            'worker.inventory')['payload'] as Map<String, dynamic>;
    expect(payload.containsKey('allowedFolders'), isFalse);
    expect(reads, 0);
    await connection.close();
  });

  test('reports Workspace-owned Worker inventory over runtime protocol',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    connection.reportWorkerInventory([
      {
        'workerId': 'workspace-worker-dynamic',
        'workerTypeId': 'dynamic-test-worker',
        'activationState': 'enabled',
        'readinessState': 'ready',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'dynamic-test-cli',
        'profileReleaseVersion': 1,
        'providerToolName': 'Fixture CLI',
        'providerToolVersion': '1.0.0',
        'capabilities': ['text', 'thread_read'],
        'localConcurrencyLimit': 1,
        'revision': 2,
      },
    ]);
    final messages = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .toList();
    final inventory = messages.firstWhere(
      (message) => message['type'] == 'worker.inventory',
    );
    final payload = inventory['payload'] as Map<String, dynamic>;
    expect(payload['fullSnapshot'], isTrue);
    expect(payload['parallelSlots'], 1,
        reason: 'The Workspace-wide slot total must reach Cloud.');
    expect((payload['workers'] as List).single['workerId'],
        'workspace-worker-dynamic');
    expect((payload['workers'] as List).single['engineVersion'], '1.0.0');
    expect(
      (payload['workers'] as List).single['profileDefinitionId'],
      'dynamic-test-cli',
    );
    expect(
      (payload['workers'] as List).single['workerTypeId'],
      'dynamic-test-worker',
    );
    expect(
      (payload['workers'] as List).single['providerToolName'],
      'Fixture CLI',
    );
    expect(jsonEncode(payload), isNot(contains('credentialRef')));
    expect(jsonEncode(payload), isNot(contains('providerToolPath')));
    await connection.close();
  });

  test('forwards every Worker activity with ordering and safe details',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-activity',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-activity'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    const context = WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'workspace-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-activity',
      idempotencyKey: 'idem-activity',
      payload: {},
    );
    for (final entry in [
      ('tool-call-1', 'tool.started', 'running', 1),
      ('tool-call-1', 'tool.completed', 'completed', 2),
      ('tool-call-2', 'tool.started', 'running', 3),
    ]) {
      await connection.reportWorkerActivity(
        context,
        WorkerActivity(
          requestId: 'request-activity',
          assignmentId: context.assignmentId,
          executionId: 'execution-activity',
          workerId: 'chatgpt',
          eventId: 'event-${entry.$4}',
          sequence: entry.$4,
          timestamp: '2026-10-12T18:00:0${entry.$4}Z',
          eventType: entry.$2,
          status: entry.$3,
          title: 'Tool',
          activityId: entry.$1,
          details: const {'toolName': 'shell'},
        ),
      );
    }
    await waitFor(() =>
        socket.sent.where((item) {
          final value = jsonDecode(item as String) as Map<String, dynamic>;
          return value['type'] == 'assignment.activity';
        }).length ==
        3);
    final messages = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .where((message) => message['type'] == 'assignment.activity')
        .toList();
    expect(
        messages.map((message) =>
            (message['payload'] as Map<String, dynamic>)['sequence']),
        [1, 2, 3]);
    expect(
        messages.map((message) =>
            (message['payload'] as Map<String, dynamic>)['activityId']),
        ['tool-call-1', 'tool-call-1', 'tool-call-2']);
    expect(jsonEncode(messages), isNot(contains('prompt')));
    await connection.close();
  });

  test('retains activity generated while disconnected until reconnect',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(hours: 1),
    );
    const context = WorkspaceAssignmentContext(
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'workspace-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-disconnected',
      idempotencyKey: 'idem-disconnected',
      payload: {},
    );

    await connection.reportWorkerActivity(
      context,
      WorkerActivity(
        requestId: 'request-disconnected',
        assignmentId: 'assignment-disconnected',
        executionId: 'execution-disconnected',
        workerId: 'worker-1',
        eventId: 'event-disconnected',
        sequence: 1,
        timestamp: '2026-10-12T18:00:01Z',
        eventType: 'execution.started',
        status: 'running',
        title: 'Worker started',
      ),
    );
    await connection.connect();
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-disconnected-activity',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-disconnected-activity'},
    }));

    await waitFor(() => socket.sent.any((item) {
          final value = jsonDecode(item as String) as Map<String, dynamic>;
          return value['type'] == 'assignment.activity' &&
              value['assignmentId'] == 'assignment-disconnected';
        }));
    await connection.close();
  });

  test('reconnects when Gateway heartbeat acknowledgements stop', () async {
    var socketCount = 0;
    final sockets = <FakeSocket>[];
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async {
        final socket = FakeSocket();
        sockets.add(socket);
        socketCount += 1;
        return socket;
      },
      heartbeat: const Duration(milliseconds: 10),
      reconnectBaseDelay: const Duration(milliseconds: 1),
      reconnectMaxDelay: const Duration(milliseconds: 5),
    );

    await connection.connect();
    sockets.first.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-ack',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.hello.ack',
      'payload': {'sessionId': 'session-1'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(socketCount, greaterThan(1));
    expect(connection.reconnectCount, greaterThan(0));
    await connection.close();
  });

  group('Service readiness', () {
    List<Map<String, dynamic>> sentOfType(FakeSocket socket, String type) =>
        socket.sent
            .map((m) => jsonDecode(m as String) as Map<String, dynamic>)
            .where((m) => m['type'] == type)
            .toList();

    WorkspaceCloudConnection newConnection(FakeSocket socket,
            {Duration heartbeat = const Duration(hours: 1),
            WorkspaceAssignmentHandler? handler}) =>
        WorkspaceCloudConnection(
          uri: Uri.parse(
              'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
          workspaceRuntimeId: 'runtime-1',
          workspaceId: 'workspace-1',
          factory: (_) async => socket,
          heartbeat: heartbeat,
          assignmentHandler: handler,
        );

    test('is disconnected until connected and advertises the capability',
        () async {
      final socket = FakeSocket();
      final connection = newConnection(socket);
      expect(connection.serviceState, ServiceConnectionState.disconnected);
      expect(connection.readyForAssignments, isFalse);
      await connection.connect();
      final hello = sentOfType(socket, 'workspace.hello').first;
      final capabilities =
          (hello['payload'] as Map)['capabilities'] as Map<String, dynamic>;
      expect(capabilities['customCapabilities'],
          contains(serviceReadinessCapability));
      await connection.close();
    });

    test(
        'is not ready while synchronizing, then publishes ready with a generation',
        () async {
      final socket = FakeSocket();
      final connection = newConnection(socket);
      await connection.connect();
      await completeHandshake(
        connection,
        socket,
        announceReadiness: true,
        beforeSyncResult: () async {
          expect(connection.serviceState, ServiceConnectionState.synchronizing);
          expect(connection.readyForAssignments, isFalse);
          // Nothing is published as ready before synchronization completes.
          expect(
              sentOfType(socket, 'workspace.readiness').where(
                  (m) => (m['payload'] as Map)['readyForAssignments'] == true),
              isEmpty);
        },
      );
      expect(connection.serviceState, ServiceConnectionState.ready);
      final published = sentOfType(socket, 'workspace.readiness');
      expect(published, hasLength(1));
      expect(published.single['payload'], containsPair('state', 'ready'));
      expect(published.single['payload'],
          containsPair('readyForAssignments', true));
      expect(published.single['payload'], containsPair('syncGeneration', 1));
      expect(published.single['workspaceRuntimeId'], 'runtime-1');
      await connection.close();
    });

    test(
        'does not send the dedicated message to a Cloud that did not announce it',
        () async {
      final socket = FakeSocket();
      final connection = newConnection(socket);
      await connection.connect();
      await completeHandshake(connection, socket);
      connection.pauseNewWork();
      expect(sentOfType(socket, 'workspace.readiness'), isEmpty);
      await connection.close();
    });

    test('publishes immediately when new work is paused, resumed or drained',
        () async {
      final socket = FakeSocket();
      final connection = newConnection(socket);
      await connection.connect();
      await completeHandshake(connection, socket, announceReadiness: true);
      connection.pauseNewWork();
      expect(connection.serviceState, ServiceConnectionState.paused);
      expect(connection.readyForAssignments, isFalse);
      var last =
          sentOfType(socket, 'workspace.readiness').last['payload'] as Map;
      expect(last['state'], 'paused');
      expect(last['readyForAssignments'], isFalse);
      connection.resumeNewWork();
      last = sentOfType(socket, 'workspace.readiness').last['payload'] as Map;
      expect(last['state'], 'ready');
      expect(last['readyForAssignments'], isTrue);
      connection.beginDrain();
      expect(connection.serviceState, ServiceConnectionState.draining);
      last = sentOfType(socket, 'workspace.readiness').last['payload'] as Map;
      expect(last['state'], 'draining');
      expect(last['readyForAssignments'], isFalse);
      await connection.close();
    });

    test('announces shutdown before the connection is torn down', () async {
      final socket = FakeSocket();
      final connection = newConnection(socket);
      await connection.connect();
      await completeHandshake(connection, socket, announceReadiness: true);
      await connection.close();
      final last =
          sentOfType(socket, 'workspace.readiness').last['payload'] as Map;
      expect(last['state'], 'draining');
      expect(last['readyForAssignments'], isFalse);
      expect(last['reason'], 'shutdown');
    });

    test('repeats readiness on every heartbeat', () async {
      final socket = FakeSocket();
      final connection =
          newConnection(socket, heartbeat: const Duration(milliseconds: 150));
      await connection.connect();
      await completeHandshake(connection, socket);
      await waitFor(() => sentOfType(socket, 'workspace.heartbeat').isNotEmpty);
      final readiness = (sentOfType(socket, 'workspace.heartbeat')
          .last['payload'] as Map)['readiness'] as Map;
      expect(readiness['state'], 'ready');
      expect(readiness['readyForAssignments'], isTrue);
      expect(readiness['syncGeneration'], 1);
      await connection.close();
    });

    test(
        'an idle Service sends idle pings once Cloud has acknowledged its '
        'readiness', () async {
      final socket = FakeSocket();
      final connection =
          newConnection(socket, heartbeat: const Duration(milliseconds: 40));
      await connection.connect();
      Map<String, Object?> fromCloud(String type, Map<String, Object?> payload,
              {String? correlationId}) =>
          {
            'protocol': 'syntila.workspace-runtime-protocol',
            'protocolVersion': workspaceRuntimeProtocolVersion,
            'messageId': 'server-${DateTime.now().microsecondsSinceEpoch}',
            if (correlationId != null) 'correlationId': correlationId,
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'workspaceRuntimeId': 'runtime-1',
            'executionWorkspaceId': 'workspace-1',
            'type': type,
            'payload': payload,
          };
      socket.controller.add(jsonEncode(fromCloud('workspace.hello.ack', {
        'sessionId': 'session-1',
        'heartbeatIntervalMs': 15000,
        'serverTime': DateTime.now().toUtc().toIso8601String(),
        'cloudCapabilities': [idlePingCapability],
      })));

      var answered = 0;
      // Cloud acknowledges heartbeats and answers idle pings.
      bool answer() {
        for (final message in socket.sent.skip(answered)) {
          if (message == workspaceIdlePingFrame) {
            socket.controller.add(workspaceIdlePongFrame);
            continue;
          }
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          if (decoded['type'] != 'workspace.heartbeat') continue;
          socket.controller.add(jsonEncode(fromCloud(
            'workspace.heartbeat.ack',
            {
              'acknowledged': true,
              'serverTime': DateTime.now().toUtc().toIso8601String(),
            },
            correlationId: decoded['messageId'] as String,
          )));
        }
        answered = socket.sent.length;
        return socket.sent.contains(workspaceIdlePingFrame);
      }

      await waitFor(answer);
      final heartbeats = sentOfType(socket, 'workspace.heartbeat').length;
      expect(heartbeats, greaterThanOrEqualTo(3));

      // Several intervals of pings alone keep the connection up: an answered
      // ping counts as an acknowledgement, and no heartbeat is needed.
      final pings =
          socket.sent.where((m) => m == workspaceIdlePingFrame).length;
      await waitFor(() {
        answer();
        return socket.sent.where((m) => m == workspaceIdlePingFrame).length >=
            pings + 5;
      });
      expect(sentOfType(socket, 'workspace.heartbeat'), hasLength(heartbeats));
      expect(connection.reconnectCount, 0);
      await connection.close();
    });

    test('keeps sending heartbeats to a Cloud that did not announce idle pings',
        () async {
      final socket = FakeSocket();
      final connection =
          newConnection(socket, heartbeat: const Duration(milliseconds: 40));
      await connection.connect();
      await completeHandshake(connection, socket);
      var acknowledged = 0;
      await waitFor(() {
        final heartbeats = sentOfType(socket, 'workspace.heartbeat');
        for (final heartbeat in heartbeats.skip(acknowledged)) {
          socket.controller.add(jsonEncode({
            'protocol': 'syntila.workspace-runtime-protocol',
            'protocolVersion': workspaceRuntimeProtocolVersion,
            'messageId': 'ack-${heartbeat['messageId']}',
            'correlationId': heartbeat['messageId'],
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'type': 'workspace.heartbeat.ack',
            'payload': {'acknowledged': true},
          }));
        }
        acknowledged = heartbeats.length;
        return heartbeats.length >= 6;
      });
      expect(socket.sent, isNot(contains(workspaceIdlePingFrame)));
      expect(connection.reconnectCount, 0);
      await connection.close();
    });
  });

  test('reconnects after a dropped socket', () async {
    final sockets = <FakeSocket>[FakeSocket(), FakeSocket()];
    final first = sockets.first;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => sockets.removeAt(0),
      heartbeat: const Duration(hours: 1),
    );
    await connection.connect();
    await first.controller.close();
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(connection.reconnectCount, 1);
    await connection.close();
  });

  test('retries a failed reconnect with backoff', () async {
    final first = FakeSocket();
    final recovered = FakeSocket();
    var factoryCalls = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async {
        factoryCalls += 1;
        if (factoryCalls == 2) throw const SocketException('temporary loss');
        return factoryCalls == 1 ? first : recovered;
      },
      heartbeat: const Duration(hours: 1),
      reconnectBaseDelay: const Duration(milliseconds: 5),
      reconnectMaxDelay: const Duration(milliseconds: 20),
    );
    await connection.connect();
    await first.controller.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(factoryCalls, greaterThanOrEqualTo(3));
    expect(connection.reconnectCount, greaterThanOrEqualTo(2));
    await connection.close();
  });

  test('applies Cloud cancellation delivered on the reconnected socket',
      () async {
    final first = FakeSocket();
    final recovered = FakeSocket();
    final cancellationRequests = <String>[];
    final assignmentStarted = Completer<void>();
    final finishAssignment = Completer<WorkspaceAssignmentResult>();
    var factoryCalls = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => ++factoryCalls == 1 ? first : recovered,
      assignmentHandler: (_) {
        assignmentStarted.complete();
        return finishAssignment.future;
      },
      assignmentCancellationHandler: (assignmentId, reason) async {
        cancellationRequests.add('$assignmentId:$reason');
        return true;
      },
      heartbeat: const Duration(hours: 1),
      reconnectBaseDelay: const Duration(milliseconds: 1),
      reconnectMaxDelay: const Duration(milliseconds: 5),
    );
    await connection.connect();
    await completeHandshake(connection, first);
    first.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'assignment-before-reconnect',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'runtime-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-still-running',
      'idempotencyKey': 'idempotency-cancel-after-reconnect',
      'payload': {
        'workerId': 'worker-1',
        'objective': 'keep running until Cloud cancels',
        'role': 'implementer',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': <String, Object?>{},
        'contextArtifactIds': <String>[],
        'timeoutMs': 60000,
      },
    }));
    await assignmentStarted.future.timeout(const Duration(seconds: 2));
    await first.controller.close();
    await waitFor(() => connection.reconnectCount > 0);
    // reconnectCount increments before the retry delay. Wait for the recovered
    // socket's hello to prove _open attached its message listener before send.
    await waitFor(() => recovered.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'workspace.hello';
        }));
    await completeHandshake(connection, recovered, sessionId: 'recovered');
    recovered.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cancel-after-reconnect',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.cancel',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'runtime-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-still-running',
      'idempotencyKey': 'idempotency-cancel-after-reconnect',
      'payload': {'reason': 'cancelled after reconnect', 'gracePeriodMs': 100},
    }));
    await waitFor(() => cancellationRequests.isNotEmpty);
    expect(cancellationRequests.first,
        'assignment-still-running:cancelled after reconnect');
    await waitFor(() => recovered.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'assignment.cancel.ack'));
    finishAssignment.complete(
        const WorkspaceAssignmentResult(summary: 'cancelled by test'));
    await connection.close();
  });

  test('retryNow tears down dead transport and reconnects cleanly', () async {
    final first = FakeSocket();
    final second = FakeSocket();
    final sockets = <FakeSocket>[first, second];
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://gateway.syntila.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => sockets.removeAt(0),
    );
    await connection.connect();
    await completeHandshake(connection, first, sessionId: 'session-1');
    expect(connection.isConnected, isTrue);

    // Simulate dead connection / sleep wake-up where retryNow is triggered
    await connection.retryNow();
    expect(connection.isConnected, isFalse);
    await completeHandshake(connection, second, sessionId: 'session-2');
    expect(connection.isConnected, isTrue);
    expect(connection.sessionId, 'session-2');
    await connection.close();
  });

  test('recovers when factory throws TimeoutException', () async {
    final recovered = FakeSocket();
    var attempts = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://gateway.syntila.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      reconnectBaseDelay: const Duration(milliseconds: 1),
      reconnectMaxDelay: const Duration(milliseconds: 5),
      factory: (_) async {
        attempts++;
        if (attempts == 1) {
          throw TimeoutException('Simulated connect timeout on wake');
        }
        return recovered;
      },
    );
    try {
      await connection.connect();
    } on Object catch (error) {
      expect(error, isA<TimeoutException>());
    }
    expect(connection.connectionStage, WorkspaceConnectionStage.reconnecting);
    expect(connection.lastConnectionError, contains('Connection timed out'));

    await connection.retryNow();
    await waitFor(() => recovered.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'workspace.hello';
        }));
    await completeHandshake(connection, recovered, sessionId: 'recovered');
    expect(connection.isConnected, isTrue);
    await connection.close();
  });

  test('acknowledges a Cloud delivery probe without any assignment', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      localQueueLengthProvider: () => 3,
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cloud-probe-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'diagnostic.probe',
      'workspaceRuntimeId': 'workspace-1',
      'executionWorkspaceId': 'workspace-1',
      'payload': {
        'probeId': 'probe-1',
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      },
    }));
    await waitFor(() => socket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'diagnostic.probe.ack'));

    final ack = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'diagnostic.probe.ack');
    final payload = ack['payload'] as Map<String, dynamic>;
    expect(ack['correlationId'], 'cloud-probe-1');
    expect(payload['probeId'], 'probe-1');
    expect(DateTime.parse(payload['receivedAt'] as String).isUtc, isTrue);
    expect(
      DateTime.parse(payload['ackedAt'] as String)
          .isBefore(DateTime.parse(payload['receivedAt'] as String)),
      isFalse,
    );
    expect(payload['syncState'], 'ready');
    expect(payload['localQueueLength'], 3);
    expect(payload['activeAssignments'], 0);
    expect(connection.activeAssignmentCount, 0);
    await connection.close();
  });

  test('returns the raw usage report for a Cloud usage request', () async {
    final socket = FakeSocket();
    final requestedWorkers = <String>[];
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      workerUsageProvider: (workerId) async {
        requestedWorkers.add(workerId);
        return {
          'status': 'ok',
          'output': 'Current session: 6% used\n',
          'errorOutput': '',
          'exitCode': 0,
          'truncated': false,
        };
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cloud-usage-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'worker.usage.request',
      'workspaceRuntimeId': 'workspace-1',
      'executionWorkspaceId': 'workspace-1',
      'payload': {'requestId': 'usage-1', 'workerId': 'worker-1'},
    }));
    await waitFor(() => socket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'worker.usage.result'));

    final result = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'worker.usage.result');
    final payload = result['payload'] as Map<String, dynamic>;
    expect(requestedWorkers, ['worker-1']);
    expect(result['correlationId'], 'cloud-usage-1');
    expect(payload['requestId'], 'usage-1');
    expect(payload['status'], 'ok');
    expect(payload['output'], 'Current session: 6% used\n');
    await connection.close();
  });

  test('reports usage as unavailable when the Service cannot read it',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cloud-usage-2',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'worker.usage.request',
      'workspaceRuntimeId': 'workspace-1',
      'executionWorkspaceId': 'workspace-1',
      'payload': {'requestId': 'usage-2', 'workerId': 'worker-1'},
    }));
    await waitFor(() => socket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'worker.usage.result'));
    final payload = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) =>
            message['type'] ==
            'worker.usage.result')['payload'] as Map<String, dynamic>;
    expect(payload['status'], 'unavailable');
    await connection.close();
  });

  test('an input wake-up triggers the input delivery handler', () async {
    final socket = FakeSocket();
    var wakes = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      inputAvailableHandler: () => wakes++,
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cloud-input-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'input.available',
      'workspaceRuntimeId': 'workspace-1',
      'executionWorkspaceId': 'workspace-1',
      'payload': <String, Object?>{},
    }));
    await waitFor(() => wakes == 1);
    await connection.close();
  });

  test('ignores a probe that has no usable probe ID', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cloud-probe-bad',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'diagnostic.probe',
      'payload': {'sentAt': DateTime.now().toUtc().toIso8601String()},
    }));
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cloud-probe-good',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'diagnostic.probe',
      'workspaceRuntimeId': 'workspace-1',
      'executionWorkspaceId': 'workspace-1',
      'payload': {
        'probeId': 'probe-after-bad',
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      },
    }));
    await waitFor(() => socket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'diagnostic.probe.ack'));
    final acks = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .where((message) => message['type'] == 'diagnostic.probe.ack')
        .toList();
    expect(acks, hasLength(1));
    expect(acks.single['correlationId'], 'cloud-probe-good');
    await connection.close();
  });

  test('records a heartbeat acknowledgement as a clock-offset sample',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      heartbeat: const Duration(milliseconds: 100),
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    await waitFor(() => socket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'workspace.heartbeat'));
    final heartbeat = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'workspace.heartbeat');

    // Cloud clock runs 2 seconds ahead of this machine.
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cloud-heartbeat-ack',
      'correlationId': heartbeat['messageId'],
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.heartbeat.ack',
      'workspaceRuntimeId': 'workspace-1',
      'executionWorkspaceId': 'workspace-1',
      'payload': {
        'acknowledged': true,
        'serverTime': DateTime.now()
            .toUtc()
            .add(const Duration(seconds: 2))
            .toIso8601String(),
      },
    }));
    await waitFor(() => connection.clockOffset.hasEstimate);
    expect(connection.clockOffset.offsetMs, inInclusiveRange(1900, 2100));
    await connection.close();
  });
}
