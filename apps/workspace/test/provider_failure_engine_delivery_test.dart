@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_protocol/workspace_runtime_protocol.dart'
    show workspaceRuntimeProtocolVersion;
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:syntila_workspace/assignment_journal.dart';
import 'package:syntila_workspace/cli_worker_engine_supervisor.dart';
import 'package:syntila_workspace/tool_profile_release_verifier.dart';
import 'package:syntila_workspace/cloud_connection.dart'
    hide providerFailureDetailsCapability;
import 'package:syntila_workspace/cloud_connection.dart' as cloud
    show providerFailureDetailsCapability;
import 'package:syntila_workspace/provider_failure_cipher.dart';
import 'package:syntila_workspace/secure_credentials.dart';
import 'package:test/test.dart';

import 'support/cloud_connection_test_support.dart';

class _Credentials implements SecureCredentialStore {
  final values = <String, String>{};
  @override
  String? readSync(String key) => values[key];
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test('real Engine failure survives Workspace journal and delivery replay',
      () async {
    final repository = Directory.current.parent.parent.path;
    final root =
        await Directory.systemTemp.createTemp('provider-failure-chain-');
    final codex = Platform.environment['SYNTILA_TEST_FAILURE_SHAPE'] == 'codex';
    final sensitive =
        Platform.environment['SYNTILA_TEST_FAILURE_SHAPE'] == 'agy-sensitive';
    final stderrOnly =
        Platform.environment['SYNTILA_TEST_FAILURE_SHAPE'] == 'agy-stderr';
    final stderrResponse = Platform.environment['SYNTILA_TEST_FAILURE_SHAPE'] ==
        'agy-stderr-response';
    final whitespace =
        Platform.environment['SYNTILA_TEST_FAILURE_SHAPE'] == 'agy-whitespace';
    final profileName = codex ? 'chatgpt-codex' : 'gemini-antigravity';
    final profile = jsonDecode(await File(
            '$repository/packages/tool-profile/test/fixtures/$profileName.v1.json')
        .readAsString()) as Map<String, dynamic>;
    final provider = profile['providerTool'] as Map<String, dynamic>;
    final providerScript = codex
        ? 'codex_failure_provider.dart'
        : 'antigravity_profile_provider.dart';
    final script =
        '$repository/packages/tool-profile/test/fixtures/provider-cli/$providerScript';
    provider['executableCandidates'] = ['dart'];
    (provider['discovery'] as Map)['standardLocations'] = <String>[];
    (provider['versionProbe'] as Map)['arguments'] = [
      'run',
      script,
      '--version'
    ];
    provider['supportedVersions'] = [
      {'min': '0.0.0', 'maxExclusive': '2.0.0'}
    ];
    if (!codex) {
      ((profile['model'] as Map)['discovery'] as Map)['arguments'] = [
        'run',
        script,
        'models'
      ];
    }
    final execution = profile['execution'] as Map<String, dynamic>;
    execution['failureExtraction'] = codex
        ? {
            'providerErrorText': r'$.error.message',
            'source': 'structured_error',
          }
        : {
            'nativeErrorCode': r'$.result.code',
            'providerErrorText': r'$.result.error',
            'failedRunResponse': r'$.result.response',
            'source': 'structured_error',
          };
    execution['arguments'] = [
      'run',
      script,
      ...(execution['arguments'] as List)
    ];
    final bytes = utf8.encode(jsonEncode(profile));
    final profileFile = File('${root.path}/profile.json')
      ..writeAsBytesSync(bytes);
    final stateDirectory = await Directory('${root.path}/state').create();
    final workingDirectory = await Directory('${root.path}/work').create();
    final registry = await Directory('${root.path}/registry').create();
    final admission = ToolProfileReleaseAdmission(
      profile: profile,
      profileDefinitionId: profile['profileDefinitionId'] as String,
      releaseVersion: profile['releaseVersion'] as int,
      logicalWorkerTypeId: profile['logicalWorkerTypeId'] as String,
      providerToolName: provider['name'] as String,
      payloadDigest: sha256.convert(bytes).toString(),
      channel: 'stable',
    );
    final supervisor = CliWorkerEngineSupervisor(
      engineExecutable: Platform.resolvedExecutable,
      engineArgumentsPrefix: [
        '$repository/engines/cli_worker/bin/syntila_cli_worker.dart'
      ],
      environmentOverrides: {
        'PATH':
            '${File(Platform.resolvedExecutable).parent.path}:${Platform.environment['PATH'] ?? ''}',
        'HOME': root.path,
      },
      processRegistryDirectory: registry,
    );
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/journal.jsonl');
    final credentials = _Credentials();
    AssignmentJournal journal() => AssignmentJournal(file,
        providerFailureCipher:
            ProviderFailureCipher(credentials, file, 'fixture'));
    final socket = FakeSocket();
    var executions = 0;
    Object? engineDiagnostics;
    final connection = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
      assignmentJournal: journal(),
      assignmentHandler: (_) async {
        executions++;
        try {
          await supervisor.execute(
            admission,
            profileFile: profileFile,
            stateDirectory: stateDirectory,
            workingDirectory: workingDirectory,
            workerId: 'worker-1',
            maxConcurrentAssignments: 1,
            assignmentId: 'assignment-1',
            attemptId: 'attempt-1',
            prompt: codex
                ? 'Provider event failure'
                : stderrOnly
                    ? 'Failure on stderr only'
                    : stderrResponse
                        ? 'Failure stderr with response'
                        : whitespace
                            ? 'Failure with whitespace'
                            : sensitive
                                ? 'Failure with sensitive oversized response'
                                : 'Failure with response',
            timeout: const Duration(seconds: 20),
            sessionPolicy: WorkerSessionPolicy.stateless,
          );
        } on CliWorkerEngineProbeException catch (error) {
          engineDiagnostics = error.localDiagnostics;
          rethrow;
        }
        throw StateError('The fixture must fail');
      },
    );
    addTearDown(connection.close);
    await connection.connect();
    await completeHandshake(connection, socket,
        extraCloudCapabilities: [cloud.providerFailureDetailsCapability]);
    final assignment = {
      'protocol': 'syntila.workspace-runtime-protocol',
      'protocolVersion': workspaceRuntimeProtocolVersion,
      'messageId': 'failure',
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
        'workerId': 'gemini',
        'engineVersion': '1.2.0',
        'profileDefinitionId': 'gemini-antigravity',
        'profileReleaseVersion': 1,
        'input': {},
        'contextArtifactIds': [],
        'timeoutMs': 20000
      },
    };
    List<Map> errors() => socket.sent
        .map((line) => jsonDecode(line as String) as Map)
        .where((message) => message['type'] == 'assignment.error')
        .toList();
    socket.controller.add(jsonEncode(assignment));
    await waitFor(() => errors().isNotEmpty,
        timeout: const Duration(seconds: 30));
    final expected = codex
        ? {
            'schemaVersion': 1,
            'source': 'structured_error',
            'providerErrorText': 'permission denied by sandbox',
          }
        : stderrOnly
            ? {
                'schemaVersion': 1,
                'source': 'stderr',
                'providerErrorText': 'fixture stderr-only failure',
              }
            : stderrResponse
                ? {
                    'schemaVersion': 1,
                    'source': 'stderr',
                    'providerErrorText': 'fixture stderr-only failure',
                    'failedRunResponse': 'Partial answer',
                    'nativeErrorCode': 'OUTPUT_LIMIT',
                  }
                : whitespace
                    ? {
                        'schemaVersion': 1,
                        'source': 'structured_error',
                        'providerErrorText': '  ',
                        'failedRunResponse': '\n \n',
                        'nativeErrorCode': 'OUTPUT_LIMIT',
                      }
                    : sensitive
                        ? {
                            'schemaVersion': 1,
                            'source': 'structured_error',
                            'nativeErrorCode': 'OUTPUT_LIMIT',
                            'failedRunResponse': '界' * 10922,
                            'truncated': true,
                            'omitted': true,
                            'omittedFields': ['providerErrorText'],
                          }
                        : {
                            'schemaVersion': 1,
                            'source': 'structured_error',
                            'nativeErrorCode': 'OUTPUT_LIMIT',
                            'providerErrorText': 'Output limit reached',
                            'failedRunResponse': 'Partial answer'
                          };
    expect((errors().first['payload'] as Map)['providerFailure'], expected,
        reason: '${errors().first}');
    expect((errors().first['payload'] as Map)['status'], 'failed');
    expect(((errors().first['payload'] as Map)['error'] as Map)['code'],
        codex ? 'permission_denied' : 'execution_failed');
    if (stderrOnly) {
      expect((errors().first['payload'] as Map)['processExitCode'], 7);
      expect(expected.containsKey('nativeErrorCode'), isFalse);
    }
    final outputPath = Platform.environment['SYNTILA_TEST_FAILURE_PAYLOAD'];
    if (outputPath != null) {
      await File(outputPath).writeAsString(jsonEncode(errors().first));
    }
    final record = await journal().find('assignment-1');
    expect(record!.status,
        anyOf(AssignmentStatus.failed, AssignmentStatus.resultPendingUpload));
    expect(record.result!['providerFailure'], expected);
    final disk = await file.readAsString();
    expect(engineDiagnostics.toString(),
        isNot(contains('fixture_private_diagnostic_marker')));
    expect(engineDiagnostics.toString(),
        isNot(contains('fixture_stderr_private_marker')));
    expect(disk, isNot(contains('fixture_private_diagnostic_marker')));
    expect(disk, isNot(contains('fixture_stderr_private_marker')));
    expect(disk, isNot(contains('Output limit reached')));
    expect(disk, isNot(contains('Partial answer')));
    expect(disk, isNot(contains('permission denied by sandbox')));
    expect(disk, isNot(contains('secret_token_1234567890')));
    expect(disk, isNot(contains('fixture stderr-only failure')));
    socket.controller.add(jsonEncode(assignment));
    await waitFor(() => errors().length >= 2);
    expect((errors().last['payload'] as Map)['providerFailure'], expected);
    expect(executions, 1);
    await connection.close();
    final restartedSocket = FakeSocket();
    final restarted = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => restartedSocket,
      assignmentJournal: journal(),
      assignmentHandler: (_) async {
        executions++;
        throw StateError('A replay must not execute the assignment again');
      },
    );
    addTearDown(restarted.close);
    await restarted.connect();
    await completeHandshake(restarted, restartedSocket,
        extraCloudCapabilities: [cloud.providerFailureDetailsCapability]);
    restartedSocket.controller.add(jsonEncode(assignment));
    await waitFor(() => restartedSocket.sent.any((line) =>
        (jsonDecode(line as String) as Map)['type'] == 'assignment.error'));
    final recoveredError = restartedSocket.sent
        .map((line) => jsonDecode(line as String) as Map)
        .firstWhere((message) => message['type'] == 'assignment.error');
    expect((recoveredError['payload'] as Map)['providerFailure'], expected);
    expect(executions, 1);
    await restarted.close();
    final oldSocket = FakeSocket();
    final oldCloud = WorkspaceCloudConnection(
      uri: Uri.parse(
          'wss://cloud.test/api/workspace-gateway/connect?workspaceRuntimeId=workspace-1'),
      workspaceRuntimeId: 'workspace-1',
      workspaceId: 'workspace-1',
      factory: (_) async => oldSocket,
      assignmentJournal: journal(),
      assignmentHandler: (_) async {
        executions++;
        throw StateError('A replay must not execute the assignment again');
      },
    );
    addTearDown(oldCloud.close);
    await oldCloud.connect();
    await completeHandshake(oldCloud, oldSocket);
    oldSocket.controller.add(jsonEncode(assignment));
    await waitFor(() => oldSocket.sent.any((line) =>
        (jsonDecode(line as String) as Map)['type'] == 'assignment.error'));
    final legacyError = oldSocket.sent
        .map((line) => jsonDecode(line as String) as Map)
        .firstWhere((message) => message['type'] == 'assignment.error');
    final legacyPayload = legacyError['payload'] as Map;
    expect(legacyPayload['status'], 'failed');
    expect(legacyPayload.containsKey('providerFailure'), isFalse);
    expect((legacyPayload['error'] as Map)['code'],
        codex ? 'permission_denied' : 'execution_failed');
    expect(executions, 1);
  });
}
