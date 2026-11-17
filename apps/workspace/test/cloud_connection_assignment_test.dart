import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_protocol/workspace_runtime_protocol.dart'
    show workspaceRuntimeProtocolVersion;
import 'package:syntila_workspace/assignment_journal.dart';
import 'package:syntila_workspace/cli_worker_engine_supervisor.dart'
    show CliWorkerEngineProbeException;
import 'package:syntila_workspace/cloud_connection.dart';
import 'package:syntila_workspace/worker_diagnostic_store.dart';
import 'package:syntila_workspace/provider_failure_cipher.dart';
import 'package:syntila_workspace/secure_credentials.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'support/cloud_connection_test_support.dart';

class _MemoryCredentials implements SecureCredentialStore {
  final values = <String, String>{};
  @override
  String? readSync(String key) => values[key];
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  for (final supported in [false, true]) {
    test('journals encrypted failure and gates Cloud delivery: $supported',
        () async {
      final dir = await Directory.systemTemp.createTemp('failure-delivery-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/assignments.jsonl');
      final credentials = _MemoryCredentials();
      AssignmentJournal journal() => AssignmentJournal(file,
          providerFailureCipher:
              ProviderFailureCipher(credentials, file, 'installation'));
      final socket = FakeSocket();
      final connection = WorkspaceCloudConnection(
        uri: Uri.parse(
            'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
        workspaceRuntimeId: 'workspace-1',
        workspaceId: 'workspace-1',
        factory: (_) async => socket,
        assignmentJournal: journal(),
        assignmentHandler: (_) async =>
            throw const CliWorkerEngineProbeException(
                'provider_failure', 'failed',
                providerFailure: {
              'schemaVersion': 1,
              'source': 'structured_error',
              'providerErrorText': 'provider secret text',
              'failedRunResponse': 'partial response',
            }),
      );
      await connection.connect();
      await completeHandshake(connection, socket,
          extraCloudCapabilities:
              supported ? [providerFailureDetailsCapability] : []);
      final assignment = {
        'protocol': 'syntila.workspace-runtime-protocol',
        'protocolVersion': workspaceRuntimeProtocolVersion,
        'messageId': 'provider-error',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'assignment.start',
        'workspaceId': 'workspace-1',
        'workspaceRuntimeId': 'workspace-1',
        'workerId': 'worker-1',
        'runId': 'run-1',
        'taskId': 'task-1',
        'attemptId': 'attempt-1',
        'assignmentId': 'assignment-1',
        'idempotencyKey': 'idem-1',
        'payload': {
          'objective': 'test',
          'role': 'implementer',
          'workerId': 'chatgpt',
          'engineVersion': '1.0.0',
          'profileDefinitionId': 'chatgpt-codex',
          'profileReleaseVersion': 1,
          'input': {},
          'contextArtifactIds': [],
          'timeoutMs': 1000
        },
      };
      socket.controller.add(jsonEncode(assignment));
      await waitFor(() => socket.sent.any((line) =>
          (jsonDecode(line as String) as Map)['type'] == 'assignment.error'));
      final sent = socket.sent
          .map((line) => jsonDecode(line as String) as Map)
          .firstWhere((message) => message['type'] == 'assignment.error');
      expect(
          (sent['payload'] as Map).containsKey('providerFailure'), supported);
      expect(
          await file.readAsString(), isNot(contains('provider secret text')));
      final recovered = await journal().find('assignment-1');
      expect(
          (recovered!.result!['providerFailure'] as Map)['failedRunResponse'],
          'partial response');
      socket.controller.add(jsonEncode(assignment));
      await waitFor(() =>
          socket.sent
              .where((line) =>
                  (jsonDecode(line as String) as Map)['type'] ==
                  'assignment.error')
              .length >=
          2);
      final replay = socket.sent
          .map((line) => jsonDecode(line as String) as Map)
          .where((message) => message['type'] == 'assignment.error')
          .last;
      expect(
          (replay['payload'] as Map).containsKey('providerFailure'), supported);
      await connection.close();
    });
  }
  test('retains provider failure details during normalization', () {
    const details = <String, Object?>{
      'schemaVersion': 1,
      'source': 'structured_error',
      'providerErrorText': 'Output limit reached',
      'failedRunResponse': 'Partial answer',
    };
    final failure = normalizeAssignmentExecutionFailure(
      const CliWorkerEngineProbeException('provider_failure', 'failed',
          providerFailure: details),
    );
    expect(failure.code, 'execution_failed');
    expect(failure.providerFailure, details);
  });
  test('includes recovered non-terminal assignments in sync', () async {
    final socket = FakeSocket();
    final directory = await Directory.systemTemp.createTemp('workspace-sync-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'recovered-running',
      status: AssignmentStatus.running,
      updatedAt: DateTime.now().toUtc(),
    ));
    await journal.append(AssignmentRecord(
      assignmentId: 'already-completed',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.now().toUtc(),
    ));
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
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
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final sync = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'workspace.sync.request');
    expect(
      (sync['payload'] as Map<String, dynamic>)['unreconciledAssignmentIds'],
      ['already-completed', 'recovered-running'],
    );
    await connection.close();
  });

  test('executes correlated assignments through the injected handler',
      () async {
    final socket = FakeSocket();
    final directory =
        await Directory.systemTemp.createTemp('workspace-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (context) async {
        expect(context.runId, 'run-1');
        expect(context.taskId, 'task-1');
        return const WorkspaceAssignmentResult(
          summary: 'completed by workspace',
          output: {'text': 'durable result payload'},
        );
      },
      assignmentJournal: journal,
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-assignment-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-1',
      'idempotencyKey': 'idem-1',
      'payload': {
        'objective': 'inspect',
        'role': 'research',
        'workerId': 'syntila.echo',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    }));
    await waitFor(() => socket.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'assignment.result';
        }));

    final messages = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .toList();
    expect(
        messages.any((message) => message['type'] == 'assignment.ack'), isTrue);
    final result = messages.firstWhere(
      (message) => message['type'] == 'assignment.result',
    );
    expect(result['assignmentId'], 'assignment-1');
    expect((result['payload'] as Map<String, dynamic>)['summary'],
        'completed by workspace');
    final records = await journal.reconcile();
    expect(records['assignment-1']!.status, AssignmentStatus.completed);
    expect((records['assignment-1']!.result?['output'] as Map)['text'],
        'durable result payload');
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('reconciles a handler that exceeds the assignment deadline', () {
    fakeAsync((async) {
      final socket = FakeSocket();
      final neverFinishes = Completer<WorkspaceAssignmentResult>();
      var cancellationRequested = false;
      final connection = WorkspaceCloudConnection(
        uri: Uri.parse(
            'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
        workspaceRuntimeId: 'workspace-1',
        workspaceId: 'workspace-1',
        factory: (_) async => socket,
        assignmentCancellationHandler: (assignmentId, reason) async {
          cancellationRequested = assignmentId == 'assignment-timeout' &&
              reason == 'Assignment deadline exceeded';
          return cancellationRequested;
        },
        assignmentHandler: (_) => neverFinishes.future,
      );
      unawaited(connection.connect());
      async.flushMicrotasks();
      socket.controller.add(jsonEncode({
        'protocol': 'syntila.workspace-runtime-protocol',
        'protocolVersion': workspaceRuntimeProtocolVersion,
        'messageId': 'test-hello-ack',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'workspace.hello.ack',
        'payload': {'sessionId': 'test-session'},
      }));
      async.flushMicrotasks();
      socket.controller.add(jsonEncode({
        'protocol': 'syntila.workspace-runtime-protocol',
        'protocolVersion': workspaceRuntimeProtocolVersion,
        'messageId': 'test-sync-result',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'workspace.sync.result',
        'payload': {'assignmentStates': const <Object?>[]},
      }));
      async.flushMicrotasks();
      expect(connection.connectionStage, WorkspaceConnectionStage.ready);

      socket.controller.add(jsonEncode({
        'protocol': 'syntila.workspace-runtime-protocol',
        'protocolVersion': workspaceRuntimeProtocolVersion,
        'messageId': 'server-assignment-timeout',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'assignment.start',
        'workspaceId': 'workspace-1',
        'workspaceRuntimeId': 'workspace-1',
        'workerId': 'worker-1',
        'runId': 'run-timeout',
        'taskId': 'task-timeout',
        'attemptId': 'attempt-timeout',
        'assignmentId': 'assignment-timeout',
        'idempotencyKey': 'idem-timeout',
        'payload': {
          'objective': 'deadline test',
          'role': 'implementer',
          'workerId': 'worker-1',
          'engineVersion': '1.0.0',
          'profileDefinitionId': 'chatgpt-codex',
          'profileReleaseVersion': 1,
          'input': {},
          'contextArtifactIds': [],
          'timeoutMs': 1000,
          'queueWaitTimeoutMs': 1000,
        },
      }));
      async.flushMicrotasks();
      expect(connection.activeAssignmentCount, 1);

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();

      final errorMessage = socket.sent
          .map((message) =>
              jsonDecode(message as String) as Map<String, dynamic>)
          .firstWhere((message) => message['type'] == 'assignment.error');
      final payload = errorMessage['payload'] as Map<String, dynamic>;
      expect(payload['executionId'], 'assignment-timeout');
      expect((payload['error'] as Map)['code'], 'timeout');
      expect(cancellationRequested, isTrue);
      expect(connection.activeAssignmentCount, 0);
      unawaited(connection.close());
      async.flushMicrotasks();
    });
  });

  test('reports normalized assignment failures to Cloud without changing codes',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (_) async => throw const AssignmentExecutionFailure(
        code: 'quota_exhausted',
        message:
            'The provider rejected this request because a usage limit was reached.',
        retryable: false,
      ),
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-normalized-engine-error',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-error',
      'taskId': 'task-error',
      'attemptId': 'attempt-error',
      'assignmentId': 'assignment-error',
      'idempotencyKey': 'idem-error',
      'payload': {
        'objective': 'test normalized error',
        'role': 'implementer',
        'workerId': 'chatgpt',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    }));
    await waitFor(() => socket.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'assignment.error';
        }));
    final errorMessage = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.error');
    final error = (errorMessage['payload'] as Map<String, dynamic>)['error']
        as Map<String, dynamic>;
    expect(error['code'], 'quota_exhausted');
    expect(error['retryable'], isFalse);
    expect(error['message'], contains('usage limit'));
    await connection.close();
  });

  test(
      'normalizes Engine provider failures instead of hiding them as generic execution errors',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (_) async => throw const CliWorkerEngineProbeException(
        'provider_tool_unavailable',
        'CLI Worker Engine could not be started.',
        localDiagnostics: 'provider launch failed',
      ),
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'engine-provider-error',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-engine-error',
      'taskId': 'task-engine-error',
      'attemptId': 'attempt-engine-error',
      'assignmentId': 'assignment-engine-error',
      'idempotencyKey': 'idem-engine-error',
      'payload': {
        'objective': 'test engine error normalization',
        'role': 'implementer',
        'workerId': 'chatgpt',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    }));
    await waitFor(() => socket.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'assignment.error';
        }));
    final errorMessage = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.error');
    final error = (errorMessage['payload'] as Map<String, dynamic>)['error']
        as Map<String, dynamic>;
    expect(error['code'], 'cli_not_found');
    expect(error['retryable'], isFalse);
    expect(error['message'], contains('CLI'));
    expect(
      (error['details'] as Map<String, dynamic>)['diagnostic'],
      'provider launch failed',
    );
    await connection.close();
  });

  test('retains unexpected runtime exception detail for private reports', () {
    final normalized = normalizeAssignmentExecutionFailure(
      const FormatException(
          'Engine response was malformed at /Users/tester/run'),
    );
    expect(normalized.code, 'execution_failed');
    expect(normalized.message, 'The assignment could not be completed.');
    expect(normalized.retryable, isTrue);
    expect(normalized.localDiagnostic, contains('FormatException'));
    expect(normalized.localDiagnostic, contains('[PATH]'));
  });

  test('paused or draining Workspace rejects new assignments', () async {
    final socket = FakeSocket();
    var executions = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (_) async {
        executions++;
        return const WorkspaceAssignmentResult(summary: 'unexpected');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    connection.beginDrain();
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-assignment-paused',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-paused',
      'taskId': 'task-paused',
      'attemptId': 'attempt-paused',
      'assignmentId': 'assignment-paused',
      'idempotencyKey': 'idem-paused',
      'payload': {
        'objective': 'inspect',
        'role': 'research',
        'workerId': 'worker-1',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    }));
    await waitFor(() => socket.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'assignment.ack' &&
              (decoded['payload'] as Map?)?['accepted'] == false;
        }));
    expect(executions, 0);
    expect(connection.isDraining, isTrue);
    await connection.close();
  });

  test('allows stateful Work through ID-derived Thread directories', () async {
    final socket = FakeSocket();
    var executed = false;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (context) async {
        executed = true;
        expect(context.payload['spaceId'], 'space-1');
        expect(context.payload['threadId'], 'thread-1');
        return const WorkspaceAssignmentResult(summary: 'empty directory work');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-empty-work-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-empty-1',
      'taskId': 'task-empty-1',
      'attemptId': 'attempt-empty-1',
      'assignmentId': 'assignment-empty-1',
      'idempotencyKey': 'idem-empty-1',
      'payload': {
        'objective': 'work without a repository',
        'role': 'implementer',
        'workerId': 'worker-1',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'spaceId': 'space-1',
        'threadId': 'thread-1',
        'executionClass': 'stateful_thread',
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    }));
    await waitFor(() => socket.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'assignment.result';
        }));

    expect(executed, isTrue);
    await connection.close();
  });

  test('redelivers a terminal result on a timer after a failed send', () async {
    final socket = FlakyTerminalSocket(1);
    final directory =
        await Directory.systemTemp.createTemp('workspace-redeliver-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (context) async => const WorkspaceAssignmentResult(
        summary: 'completed by workspace',
        output: {'text': 'durable result payload'},
      ),
      assignmentJournal: journal,
      heartbeat: const Duration(hours: 1),
      terminalRedeliveryInterval: const Duration(milliseconds: 20),
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-assignment-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-1',
      'idempotencyKey': 'idem-1',
      'payload': {
        'objective': 'inspect',
        'role': 'research',
        'workerId': 'syntila.echo',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    }));
    int results() => socket.sent
        .where((message) =>
            (jsonDecode(message as String) as Map)['type'] ==
            'assignment.result')
        .length;

    // The first send is rejected; the timer, not a reconnect, redelivers it.
    await waitFor(() => results() == 1);
    expect(socket.failures, 0);
    final redelivered = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.result');
    expect((redelivered['payload'] as Map)['summary'], isNotNull);
    expect((await journal.reconcile())['assignment-1']!.status,
        AssignmentStatus.completed);

    // Until Cloud acknowledges, delivery keeps being retried.
    await waitFor(() => results() >= 2);
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'terminal-ack-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.ack',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-1',
      'idempotencyKey': 'idem-1',
      'payload': {'accepted': true, 'terminal': true, 'status': 'completed'},
    }));
    while ((await journal.reconcile())['assignment-1']?.status !=
        AssignmentStatus.reconciled) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // Wait for one in-flight timer tick to observe the reconciled journal and
    // stop scheduling further ticks, then probe the connection and verify no
    // further result is sent across another redelivery window.
    await Future<void>.delayed(const Duration(milliseconds: 85));
    final settled = results();
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'redelivery-settled-probe',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'diagnostic.probe',
      'workspaceRuntimeId': 'workspace-1',
      'executionWorkspaceId': 'workspace-1',
      'payload': {
        'probeId': 'redelivery-settled',
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      },
    }));
    await waitFor(() => socket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'diagnostic.probe.ack'));
    expect(results(), settled);
    await connection.close();
    await directory.delete(recursive: true);
  });

  test(
      'delivers a result on the new session when the Service reconnected mid-run',
      () async {
    final first = FakeSocket();
    final second = FakeSocket();
    final sockets = [first, second];
    final release = Completer<void>();
    final directory =
        await Directory.systemTemp.createTemp('workspace-reconnect-run-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => sockets.removeAt(0),
      assignmentHandler: (context) async {
        await release.future;
        return const WorkspaceAssignmentResult(
          summary: 'completed after reconnect',
          output: {'text': 'durable result payload'},
        );
      },
      assignmentJournal: journal,
      heartbeat: const Duration(hours: 1),
      reconnectBaseDelay: const Duration(milliseconds: 5),
      reconnectMaxDelay: const Duration(milliseconds: 10),
      terminalRedeliveryInterval: const Duration(milliseconds: 40),
    );
    await connection.connect();
    await completeHandshake(connection, first);
    first.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-assignment-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-1',
      'idempotencyKey': 'idem-1',
      'payload': {
        'objective': 'inspect',
        'role': 'research',
        'workerId': 'syntila.echo',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 5000,
      },
    }));
    await waitFor(() => first.sent.any((message) =>
        (jsonDecode(message as String) as Map)['type'] == 'assignment.ack'));

    // The connection drops while the Worker is still running.
    await first.close();
    await completeHandshake(connection, second, sessionId: 'session-2');

    release.complete();
    await waitFor(
      () => second.sent.any((message) =>
          (jsonDecode(message as String) as Map)['type'] ==
          'assignment.result'),
      timeout: const Duration(seconds: 5),
    );
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('replays a terminal journal result when Cloud still has it active',
      () async {
    final socket = FakeSocket();
    final directory =
        await Directory.systemTemp.createTemp('workspace-replay-');
    final journal =
        _ReconciliationJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-1',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.now().toUtc(),
      workspaceId: 'workspace-1',
      workspaceRuntimeId: 'workspace-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      idempotencyKey: 'idem-1',
      result: {
        'summary': 'recovered',
        'output': {'text': 'saved output'},
        'artifactIds': <String>[],
      },
    ));
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
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
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-sync-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'workspace.sync.result',
      'payload': {
        'desiredWorkers': [],
        'activeAssignmentIds': ['assignment-1'],
        'assignmentStates': [
          {
            'assignmentId': 'assignment-1',
            'attemptId': 'attempt-1',
            'idempotencyKey': 'idem-1',
            'status': 'running',
          },
        ],
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final replay = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.result');
    expect((replay['payload'] as Map<String, dynamic>)['summary'], 'recovered');
    expect(
        ((replay['payload'] as Map<String, dynamic>)['output'] as Map)['text'],
        'saved output');
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'terminal-ack-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.ack',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-1',
      'idempotencyKey': 'idem-1',
      'payload': {'accepted': true, 'terminal': true, 'status': 'completed'},
    }));
    await journal.reconciled.future.timeout(const Duration(seconds: 5));
    expect(
      (await journal.reconcile())['assignment-1']!.status,
      AssignmentStatus.reconciled,
    );
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('rejects assignments addressed to another workspace', () async {
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
      'messageId': 'server-assignment-2',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-2',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-2',
      'idempotencyKey': 'idem-2',
      'payload': {},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final error = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.error');
    expect((error['payload'] as Map<String, dynamic>)['error']['code'],
        'worker_not_ready');
    await connection.close();
  });

  test('rejects malformed assignment payloads before worker execution',
      () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (_) async {
        fail('malformed assignment reached the handler');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-assignment-3',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-3',
      'idempotencyKey': 'idem-3',
      'payload': {'workerId': 'syntila.echo'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final error = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.error');
    final payload = error['payload'] as Map<String, dynamic>;
    expect(payload['error']['code'], 'execution_failed');
    expect(
      jsonDecode(
        (payload['error']['details'] as Map<String, dynamic>)['diagnostic']
            as String,
      ),
      containsPair('stage', 'assignment_payload_validation'),
    );
    await connection.close();
  });

  test('rejects cross-worker Worker Session metadata', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (_) async {
        fail('malformed assignment reached the handler');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-assignment-3',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-3',
      'idempotencyKey': 'idem-3',
      'payload': {
        'workerId': 'worker-1',
        'objective': 'Hello',
        'role': 'assistant',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': <String, Object?>{},
        'contextArtifactIds': <String>[],
        'timeoutMs': 1000,
        'sessionPolicy': 'durable_session',
        'sessionKey': 'scope-A',
        'workerSession': {
          'schemaVersion': 1,
          'id': 'session-A',
          'conversationId': 'conversation-A',
          'workerId': 'worker-B',
          'baseContextRevision': 0,
        },
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final error = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.error');
    expect((error['payload'] as Map<String, dynamic>)['error']['code'],
        'execution_failed');
    await connection.close();
  });

  test('rejects provider-native Worker Session metadata', () async {
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentHandler: (_) async {
        fail('malformed assignment reached the handler');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-assignment-3',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-3',
      'idempotencyKey': 'idem-3',
      'payload': {
        'workerId': 'worker-1',
        'objective': 'Hello',
        'role': 'assistant',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': <String, Object?>{},
        'contextArtifactIds': <String>[],
        'timeoutMs': 1000,
        'sessionPolicy': 'durable_session',
        'sessionKey': 'scope-A',
        'workerSession': {
          'schemaVersion': 1,
          'id': 'session-A',
          'conversationId': 'conversation-A',
          'workerId': 'worker-1',
          'nativeSessionId': 'private-handle',
          'baseContextRevision': 0,
        },
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final error = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.error');
    expect((error['payload'] as Map<String, dynamic>)['error']['code'],
        'execution_failed');
    await connection.close();
  });

  test('replays a completed assignment without rerunning the handler',
      () async {
    final socket = FakeSocket();
    final directory =
        await Directory.systemTemp.createTemp('workspace-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    var executions = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      assignmentHandler: (_) async {
        executions += 1;
        return const WorkspaceAssignmentResult(summary: 'once');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    Map<String, Object?> assignment() => {
          'protocol': 'syntila.workspace-runtime-protocol',
          'protocolVersion': workspaceRuntimeProtocolVersion,
          'messageId': 'server-replay-${executions + 1}',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'type': 'assignment.start',
          'workspaceId': 'workspace-1',
          'workspaceRuntimeId': 'workspace-1',
          'workerId': 'worker-1',
          'runId': 'run-1',
          'taskId': 'task-1',
          'attemptId': 'attempt-1',
          'assignmentId': 'assignment-replay',
          'idempotencyKey': 'idem-replay',
          'payload': {
            'objective': 'inspect',
            'role': 'research',
            'workerId': 'syntila.echo',
            'engineVersion': '1.0.0',
            'profileDefinitionId': 'chatgpt-codex',
            'profileReleaseVersion': 1,
            'input': {},
            'contextArtifactIds': [],
            'timeoutMs': 1000,
          },
        };

    socket.controller.add(jsonEncode(assignment()));
    await waitFor(() => executions == 1);
    await waitFor(() =>
        socket.sent
            .where((message) =>
                (jsonDecode(message as String)
                    as Map<String, dynamic>)['type'] ==
                'assignment.result')
            .length ==
        1);
    socket.controller.add(jsonEncode(assignment()));
    await waitFor(() =>
        socket.sent
            .where((message) =>
                (jsonDecode(message as String)
                    as Map<String, dynamic>)['type'] ==
                'assignment.result')
            .length ==
        2);

    expect(executions, 1);
    await connection.close();
    await directory.delete(recursive: true);
  });

  test(
      'does not rerun a non-terminal assignment on duplicate delivery and re-asserts admission',
      () async {
    final socket = FakeSocket();
    final directory =
        await Directory.systemTemp.createTemp('workspace-journal-');
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    final release = Completer<void>();
    var executions = 0;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
      assignmentHandler: (_) async {
        executions += 1;
        await release.future;
        return const WorkspaceAssignmentResult(summary: 'once');
      },
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    final assignment = <String, Object?>{
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-running-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-running',
      'idempotencyKey': 'idem-running',
      'payload': {
        'objective': 'inspect',
        'role': 'research',
        'workerId': 'syntila.echo',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    };
    socket.controller.add(jsonEncode(assignment));
    await waitFor(() => executions == 1);
    socket.controller
        .add(jsonEncode({...assignment, 'messageId': 'server-running-2'}));
    List<Map<String, dynamic>> acks() => socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .where((message) => message['type'] == 'assignment.ack')
        .toList();
    // A duplicate for a live assignment re-asserts admission evidence (a
    // second accepted ack) instead of being rejected, and never re-executes.
    await waitFor(() => acks().length >= 2);

    expect(executions, 1);
    expect(
      acks().every((ack) => (ack['payload'] as Map)['accepted'] == true),
      isTrue,
    );
    release.complete();
    await waitFor(() => socket.sent.any((message) {
          final decoded = jsonDecode(message as String) as Map<String, dynamic>;
          return decoded['type'] == 'assignment.result';
        }));
    await connection.close();
    await directory.delete(recursive: true);
  });

  test('acknowledges cancellation for an already completed assignment',
      () async {
    final directory = await Directory.systemTemp.createTemp('cancelled-run-');
    addTearDown(() => directory.delete(recursive: true));
    final journal =
        AssignmentJournal(File('${directory.path}/assignments.jsonl'));
    await journal.append(AssignmentRecord(
      assignmentId: 'assignment-done',
      status: AssignmentStatus.completed,
      updatedAt: DateTime.now().toUtc(),
    ));
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
      workspaceRuntimeId: 'runtime-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal,
    );
    await connection.connect();
    await completeHandshake(connection, socket);
    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'cancel-1',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.cancel',
      'executionWorkspaceId': 'workspace-1',
      'workspaceRuntimeId': 'runtime-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-done',
      'idempotencyKey': 'idem-done',
      'payload': {'reason': 'user cancelled', 'gracePeriodMs': 1000},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final ack = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.cancel.ack');
    expect((ack['payload'] as Map<String, dynamic>)['cancelled'], isFalse);
    expect(
        (ack['payload'] as Map<String, dynamic>)['alreadyTerminated'], isTrue);
    await connection.close();
  });

  group('assignments received while synchronizing', () {
    Map<String, Object?> startMessage(String assignmentId) => {
          'protocol': 'syntila.workspace-runtime-protocol',
          'protocolVersion': workspaceRuntimeProtocolVersion,
          'messageId': 'start-$assignmentId',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'type': 'assignment.start',
          'executionWorkspaceId': 'workspace-1',
          'workspaceRuntimeId': 'runtime-1',
          'workerId': 'worker-1',
          'runId': 'run-1',
          'taskId': 'task-1',
          'attemptId': 'attempt-1',
          'assignmentId': assignmentId,
          'idempotencyKey': 'idem-$assignmentId',
          'payload': {
            'objective': 'inspect',
            'role': 'research',
            'workerId': 'syntila.echo',
            'engineVersion': '1.0.0',
            'profileDefinitionId': 'chatgpt-codex',
            'profileReleaseVersion': 1,
            'input': {},
            'contextArtifactIds': [],
            'timeoutMs': 1000,
          },
        };

    WorkspaceCloudConnection newConnection(
        FakeSocket socket, List<String> executed) {
      return WorkspaceCloudConnection(
        uri: Uri.parse(
            'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1'),
        workspaceRuntimeId: 'runtime-1',
        workspaceId: 'workspace-1',
        factory: (_) async => socket,
        heartbeat: const Duration(hours: 1),
        assignmentHandler: (context) async {
          executed.add(context.assignmentId);
          return const WorkspaceAssignmentResult(summary: 'done');
        },
      );
    }

    test('runs a buffered command once synchronization completes', () async {
      final socket = FakeSocket();
      final executed = <String>[];
      final connection = newConnection(socket, executed);
      await connection.connect();
      await completeHandshake(
        connection,
        socket,
        assignmentStates: [
          {'assignmentId': 'buffered-ok', 'status': 'dispatched'},
        ],
        beforeSyncResult: () async {
          socket.controller.add(jsonEncode(startMessage('buffered-ok')));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(executed, isEmpty);
        },
      );
      await waitFor(() => executed.contains('buffered-ok'));
      expect(executed, ['buffered-ok']);
      await connection.close();
    });

    test('drops a buffered command Cloud has already revoked or finished',
        () async {
      final socket = FakeSocket();
      final executed = <String>[];
      final connection = newConnection(socket, executed);
      await connection.connect();
      await completeHandshake(
        connection,
        socket,
        assignmentStates: [
          {'assignmentId': 'buffered-revoked', 'status': 'revocation_pending'},
          {'assignmentId': 'buffered-done', 'status': 'timed_out'},
        ],
        beforeSyncResult: () async {
          socket.controller.add(jsonEncode(startMessage('buffered-revoked')));
          socket.controller.add(jsonEncode(startMessage('buffered-done')));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        },
      );
      socket.controller.add(jsonEncode({
        'protocol': 'syntila.workspace-runtime-protocol',
        'protocolVersion': workspaceRuntimeProtocolVersion,
        'messageId': 'buffered-settled-probe',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'diagnostic.probe',
        'workspaceRuntimeId': 'runtime-1',
        'executionWorkspaceId': 'workspace-1',
        'payload': {
          'probeId': 'buffered-settled',
          'sentAt': DateTime.now().toUtc().toIso8601String(),
        },
      }));
      await waitFor(() => socket.sent.any((message) =>
          (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
          'diagnostic.probe.ack'));
      expect(executed, isEmpty);
      await connection.close();
    });

    test('rejects buffered commands explicitly when the connection ends first',
        () async {
      final socket = FakeSocket();
      final executed = <String>[];
      final connection = newConnection(socket, executed);
      await connection.connect();
      // Hello is acknowledged but the sync result never arrives.
      Map<String, dynamic> hello() => socket.sent
          .map((m) => jsonDecode(m as String) as Map<String, dynamic>)
          .firstWhere((m) => m['type'] == 'workspace.hello');
      await waitFor(() => socket.sent.any((m) =>
          (jsonDecode(m as String) as Map<String, dynamic>)['type'] ==
          'workspace.hello'));
      socket.controller.add(jsonEncode({
        'protocol': 'syntila.workspace-runtime-protocol',
        'protocolVersion': workspaceRuntimeProtocolVersion,
        'messageId': 'hello-ack',
        'correlationId': hello()['messageId'],
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'workspace.hello.ack',
        'workspaceRuntimeId': 'runtime-1',
        'executionWorkspaceId': 'workspace-1',
        'payload': {'sessionId': 'session-x'},
      }));
      await waitFor(() => socket.sent.any((m) =>
          (jsonDecode(m as String) as Map<String, dynamic>)['type'] ==
          'workspace.sync.request'));
      socket.controller.add(jsonEncode(startMessage('buffered-lost')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await connection.close();
      final acks = socket.sent
          .map((m) => jsonDecode(m as String) as Map<String, dynamic>)
          .where((m) =>
              m['type'] == 'assignment.ack' &&
              m['assignmentId'] == 'buffered-lost')
          .toList();
      expect(acks, hasLength(1));
      expect((acks.single['payload'] as Map)['accepted'], isFalse);
      expect(executed, isEmpty);
    });
  });

  test('traces admission and attaches Service facts to assignment.ack',
      () async {
    final directory = await Directory.systemTemp.createTemp('trace-epoch-');
    addTearDown(() => directory.delete(recursive: true));
    final store = WorkerDiagnosticStore(directory: directory);
    final socket = FakeSocket();
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      diagnosticStoreForWorkerType: (_) => store,
      assignmentHandler: (context) async => const WorkspaceAssignmentResult(
        summary: 'done',
        output: {'text': 'ok'},
      ),
    );
    await connection.connect();
    await completeHandshake(connection, socket);

    socket.controller.add(jsonEncode({
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'server-assignment-trace',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': 'assignment.start',
      'workspaceId': 'workspace-1',
      'workspaceRuntimeId': 'workspace-1',
      'workerId': 'worker-1',
      'runId': 'run-1',
      'taskId': 'task-1',
      'attemptId': 'attempt-1',
      'assignmentId': 'assignment-trace-1',
      'idempotencyKey': 'idem-trace-1',
      'payload': {
        'objective': 'inspect',
        'role': 'research',
        'workerId': 'syntila.echo',
        'engineVersion': '1.0.0',
        'profileDefinitionId': 'chatgpt-codex',
        'profileReleaseVersion': 1,
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 1000,
      },
    }));
    await waitFor(() => socket.sent.any((message) =>
        (jsonDecode(message as String) as Map<String, dynamic>)['type'] ==
        'assignment.result'));

    final ack = socket.sent
        .map((message) => jsonDecode(message as String) as Map<String, dynamic>)
        .firstWhere((message) => message['type'] == 'assignment.ack');
    final payload = ack['payload'] as Map<String, dynamic>;
    expect(payload['accepted'], isTrue);
    final serviceTrace = payload['serviceTrace'] as Map<String, dynamic>;
    expect(serviceTrace['syncState'], 'ready');
    expect(serviceTrace['traceEpochId'],
        connection.latencySummary()['traceEpochId']);
    expect(serviceTrace['traceEpochId'],
        matches(RegExp(r'^[A-Za-z0-9._:-]{1,128}$')));
    expect(serviceTrace['activeAssignments'], 1);
    expect(serviceTrace['receiveToAckMs'], isA<int>());

    final intervals = connection.latencySummary()['intervals'] as Map;
    expect(intervals.keys, contains('service_received->service_accepted'));
    // The terminal path releases the open trace.
    expect(connection.traceRecorder.isTracking('assignment-trace-1'), isFalse);
    final records = await store.readSafeRecords();
    final traces =
        records.where((record) => record['stage'] == 'trace').toList();
    expect(traces.length, greaterThanOrEqualTo(2));
    expect(
        traces
            .map((record) => (record['context'] as Map)['traceEpochId'])
            .toSet(),
        {serviceTrace['traceEpochId']});
    await connection.close();
  });

  group('live assignment convergence', () {
    Map<String, dynamic> assignmentStart() => {
          'protocol': 'syntila.workspace-runtime-protocol',
          'protocolVersion': workspaceRuntimeProtocolVersion,
          'messageId': 'server-assignment-live',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'type': 'assignment.start',
          'workspaceId': 'workspace-1',
          'workspaceRuntimeId': 'workspace-1',
          'workerId': 'worker-1',
          'runId': 'run-1',
          'taskId': 'task-1',
          'attemptId': 'attempt-1',
          'assignmentId': 'assignment-live-1',
          'idempotencyKey': 'idem-live-1',
          'payload': {
            'objective': 'inspect',
            'role': 'research',
            'workerId': 'syntila.echo',
            'engineVersion': '1.0.0',
            'profileDefinitionId': 'chatgpt-codex',
            'profileReleaseVersion': 1,
            'input': {},
            'contextArtifactIds': [],
            'timeoutMs': 1000,
          },
        };

    List<Map<String, dynamic>> sentOfType(FakeSocket socket, String type) =>
        socket.sent
            .map((message) =>
                jsonDecode(message as String) as Map<String, dynamic>)
            .where((message) => message['type'] == type)
            .toList();

    Map<String, dynamic> syncStates(String syncRequestId, String status) => {
          'protocol': 'syntila.workspace-runtime-protocol',
          'protocolVersion': workspaceRuntimeProtocolVersion,
          'messageId': 'server-sync-$status',
          'correlationId': syncRequestId,
          'workspaceRuntimeId': 'workspace-1',
          'executionWorkspaceId': 'workspace-1',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'type': 'workspace.sync.result',
          'payload': {
            'desiredWorkers': [],
            'activeAssignmentIds': ['assignment-live-1'],
            'assignmentStates': [
              {'assignmentId': 'assignment-live-1', 'status': status},
            ],
          },
        };

    Future<
        ({
          WorkspaceCloudConnection connection,
          FakeSocket socket,
          Completer<void> finish,
          String syncRequestId,
        })> liveAssignment() async {
      final socket = FakeSocket();
      final directory =
          await Directory.systemTemp.createTemp('workspace-live-');
      final journal =
          AssignmentJournal(File('${directory.path}/assignments.jsonl'));
      final finish = Completer<void>();
      late WorkspaceCloudConnection connection;
      connection = WorkspaceCloudConnection(
        uri: Uri.parse(
            'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
        workspaceRuntimeId: 'workspace-1',
        workspaceId: 'workspace-1',
        factory: (_) async => socket,
        assignmentJournal: journal,
        heartbeat: const Duration(hours: 1),
        assignmentHandler: (context) async {
          await connection.reportWorkerStarted(context);
          await finish.future;
          return const WorkspaceAssignmentResult(
            summary: 'done',
            output: {'text': 'ok'},
          );
        },
      );
      await connection.connect();
      await completeHandshake(connection, socket);
      socket.controller.add(jsonEncode(assignmentStart()));
      await waitFor(
          () => sentOfType(socket, 'assignment.start.ack').isNotEmpty);
      final syncRequestId = sentOfType(socket, 'workspace.sync.request')
          .first['messageId'] as String;
      return (
        connection: connection,
        socket: socket,
        finish: finish,
        syncRequestId: syncRequestId,
      );
    }

    test(
        'a replayed command for a running assignment re-asserts evidence '
        'instead of rejecting it', () async {
      final live = await liveAssignment();
      live.socket.sent.clear();

      live.socket.controller.add(jsonEncode(assignmentStart()));
      await waitFor(
          () => sentOfType(live.socket, 'assignment.start.ack').isNotEmpty);

      final acks = sentOfType(live.socket, 'assignment.ack');
      expect(acks, hasLength(1));
      expect((acks.single['payload'] as Map)['accepted'], isTrue);
      expect(
        sentOfType(live.socket, 'assignment.start.ack').single['payload'],
        containsPair('providerStarted', true),
      );
      live.finish.complete();
      await live.connection.close();
    });

    test('sync shows Cloud behind: Dispatched needs admission and start',
        () async {
      final live = await liveAssignment();
      live.socket.sent.clear();

      live.socket.controller
          .add(jsonEncode(syncStates(live.syncRequestId, 'dispatched')));
      await waitFor(
          () => sentOfType(live.socket, 'assignment.start.ack').isNotEmpty);

      expect(sentOfType(live.socket, 'assignment.ack'), hasLength(1));
      live.finish.complete();
      await live.connection.close();
    });

    test('sync shows Cloud Acknowledged: only the start evidence is re-sent',
        () async {
      final live = await liveAssignment();
      live.socket.sent.clear();

      live.socket.controller
          .add(jsonEncode(syncStates(live.syncRequestId, 'acknowledged')));
      await waitFor(
          () => sentOfType(live.socket, 'assignment.start.ack').isNotEmpty);

      expect(sentOfType(live.socket, 'assignment.ack'), isEmpty);
      live.finish.complete();
      await live.connection.close();
    });

    test('sync never re-asserts when Cloud is already Running', () async {
      final live = await liveAssignment();
      live.socket.sent.clear();

      live.socket.controller
          .add(jsonEncode(syncStates(live.syncRequestId, 'running')));
      live.socket.controller.add(jsonEncode({
        'protocol': 'syntila.workspace-runtime-protocol',
        'protocolVersion': workspaceRuntimeProtocolVersion,
        'messageId': 'sync-running-settled-probe',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'diagnostic.probe',
        'workspaceRuntimeId': 'workspace-1',
        'executionWorkspaceId': 'workspace-1',
        'payload': {
          'probeId': 'sync-running-settled',
          'sentAt': DateTime.now().toUtc().toIso8601String(),
        },
      }));
      await waitFor(
          () => sentOfType(live.socket, 'diagnostic.probe.ack').isNotEmpty);

      expect(sentOfType(live.socket, 'assignment.ack'), isEmpty);
      expect(sentOfType(live.socket, 'assignment.start.ack'), isEmpty);
      live.finish.complete();
      await live.connection.close();
    });
  });
}

// Signal durable completion rather than observing a record during its append.
class _ReconciliationJournal extends AssignmentJournal {
  _ReconciliationJournal(super.file);

  final reconciled = Completer<void>();

  @override
  Future<void> append(AssignmentRecord record) async {
    await super.append(record);
    if (record.status == AssignmentStatus.reconciled &&
        !reconciled.isCompleted) {
      reconciled.complete();
    }
  }
}
