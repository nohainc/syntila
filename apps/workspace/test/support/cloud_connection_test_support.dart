import 'dart:async';
import 'dart:convert';

import 'package:syntila_protocol/workspace_runtime_protocol.dart'
    show workspaceRuntimeProtocolVersion;
import 'package:syntila_workspace/cloud_connection.dart';
import 'package:syntila_workspace/workspace_transport.dart';

export 'package:syntila_workspace/workspace_transport.dart'
    show WorkspaceTransport;

class FakeSocket implements WorkspaceTransport {
  final controller = StreamController<Object?>();
  final sent = <Object>[];

  @override
  Stream<Object?> get messages => controller.stream.map((raw) {
        if (raw is! String) return raw;
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) return raw;
        final type = decoded['type'];
        if (type == 'assignment.start') {
          decoded['executionWorkspaceId'] ??= decoded.remove('workspaceId');
          final payload = decoded['payload'];
          if (payload is Map<String, dynamic> && payload['snapshot'] == null) {
            final snapshot = Map<String, dynamic>.from(payload)
              ..remove('input');
            final workerId = snapshot['workerId'];
            snapshot['workerTypeId'] ??=
                workerId == 'gemini' ? 'gemini' : 'chatgpt';
            decoded['payload'] = {
              'snapshot': snapshot,
              if (payload['input'] is Map) 'input': payload['input'],
            };
          }
          return jsonEncode(decoded);
        }
        if (type == 'workspace.hello.ack' || type == 'workspace.sync.result') {
          final requestType = type == 'workspace.hello.ack'
              ? 'workspace.hello'
              : 'workspace.sync.request';
          final requests = sent
              .whereType<String>()
              .map((message) => jsonDecode(message) as Map<String, dynamic>)
              .where((message) => message['type'] == requestType)
              .toList();
          final request = requests.isEmpty ? null : requests.last;
          final payload = request?['payload'];
          if (request != null && payload is Map<String, dynamic>) {
            decoded['correlationId'] = request['messageId'];
            decoded['workspaceRuntimeId'] ??= payload['workspaceRuntimeId'];
            decoded['executionWorkspaceId'] ??= payload['executionWorkspaceId'];
            return jsonEncode(decoded);
          }
        }
        return raw;
      });

  @override
  void send(Object message) => sent.add(message);

  @override
  Future<void> sendAndWait(Object message) {
    send(message);
    return Future<void>.value();
  }

  @override
  Future<void> close() => controller.close();
}

/// Rejects the first terminal sends while the connection itself stays up.
class FlakyTerminalSocket extends FakeSocket {
  FlakyTerminalSocket(this.failures);
  int failures;

  @override
  Future<void> sendAndWait(Object message) {
    final decoded = jsonDecode(message as String) as Map<String, dynamic>;
    if (decoded['type'] == 'assignment.result' && failures > 0) {
      failures--;
      return Future<void>.error(TimeoutException('terminal send timed out'));
    }
    return super.sendAndWait(message);
  }
}

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met before $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> completeHandshake(
  WorkspaceCloudConnection connection,
  FakeSocket socket, {
  String sessionId = 'test-session',
  bool announceReadiness = false,
  List<String> extraCloudCapabilities = const [],
  List<Map<String, Object?>> assignmentStates = const [],
  Future<void> Function()? beforeSyncResult,
  DateTime? serverTime,
}) async {
  Map<String, dynamic> sentMessage(String type) => socket.sent
      .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
      .firstWhere((message) => message['type'] == type);

  final legacy = connection.uri.path.contains('/workspace') &&
      !connection.uri.path.contains('workspace-gateway');
  final protocol = legacy
      ? 'syntila.workspace-runtime-protocol'
      : 'syntila.workspace-runtime-protocol';
  final version = workspaceRuntimeProtocolVersion;
  final helloType = legacy ? 'workspace.hello' : 'workspace.hello';
  await waitFor(() => socket.sent.any((message) =>
      (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
      helloType));
  final hello = sentMessage(helloType);
  socket.controller.add(jsonEncode({
    'protocol': protocol,
    'protocolVersion': version,
    'messageId': 'test-hello-ack',
    if (!legacy) 'correlationId': hello['messageId'],
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'type': legacy ? 'workspace.hello.ack' : 'workspace.hello.ack',
    'workspaceRuntimeId': connection.workspaceRuntimeId,
    'executionWorkspaceId': connection.workspaceId,
    'payload': {
      'sessionId': sessionId,
      if (serverTime != null)
        'serverTime': serverTime.toUtc().toIso8601String(),
      if (announceReadiness || extraCloudCapabilities.isNotEmpty)
        'cloudCapabilities': [
          if (announceReadiness) serviceReadinessCapability,
          ...extraCloudCapabilities,
        ],
    },
  }));

  const syncType = 'workspace.sync.request';
  await waitFor(() => socket.sent.any((message) =>
      (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
      syncType));
  final sync = sentMessage(syncType);
  if (beforeSyncResult != null) await beforeSyncResult();
  socket.controller.add(jsonEncode({
    'protocol': protocol,
    'protocolVersion': version,
    'messageId': 'test-sync-result',
    if (!legacy) 'correlationId': sync['messageId'],
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'type': legacy ? 'workspace.sync.response' : 'workspace.sync.result',
    'workspaceRuntimeId': connection.workspaceRuntimeId,
    'executionWorkspaceId': connection.workspaceId,
    'payload': {'assignmentStates': assignmentStates},
  }));
  await waitFor(
      () => connection.connectionStage == WorkspaceConnectionStage.ready);
}
