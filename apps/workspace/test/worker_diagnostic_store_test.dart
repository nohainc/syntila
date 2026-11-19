import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/worker_diagnostic_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('worker-diagnostics-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('Worker JSONL import drops prompts, paths, and credential fields',
      () async {
    final store = WorkerDiagnosticStore(
      directory: Directory('${temporary.path}/logs'),
    );
    await store.recordWorkerStderrLine(
      jsonEncode({
        'level': 'info',
        'event': 'assignment.started',
        'message': 'user prompt: do something private',
        'context': {
          'assignmentId': 'assignment-1',
          'prompt': 'full sensitive prompt',
          'fileContents': 'private source text',
          'apiKey': 'secret-key-value',
          'providerToolName': 'Codex CLI',
          'providerToolVersion': '1.2.3',
          'workspaceVersion': '8.2.0',
          'engineVersion': '1.3.0',
          'profileDefinitionId': 'chatgpt-codex',
          'profileReleaseVersion': 9,
          'profileResolutionSource': 'stable',
          'probeStage': 'live',
          'failureLayer': 'provider_tool',
          'durationMs': 345,
          'errorCode': 'provider_auth_required',
          'profilePayload': {'secret': 'profile-private-value'},
          'stderr': 'Authorization: Bearer live-provider-token',
          'environment': {
            'HOME': '/Users/vitaliinoha',
            'API_KEY': 'env-secret'
          },
          'sourceCode': 'class PrivateSource {}',
          'cookie': 'session=private-cookie',
          'misleadingNested': {'message': 'raw provider output'},
        },
      }),
      workerTypeId: 'chatgpt',
      workerVersion: '1.0.0-beta+2',
      protocolStage: 'execute',
      runId: 'assignment-1',
    );

    final report = await store.createCopyableReport();
    expect(report, contains('chatgpt'));
    expect(report, contains('1.0.0-beta+2'));
    expect(report, contains('assignment-1'));
    expect(report, contains('Codex CLI'));
    expect(report, contains('1.2.3'));
    expect(report, contains('8.2.0'));
    expect(report, contains('1.3.0'));
    expect(report, contains('chatgpt-codex'));
    expect(report, contains('"profileReleaseVersion":9'));
    expect(report, contains('"profileResolutionSource":"stable"'));
    expect(report, contains('"probeStage":"live"'));
    expect(report, contains('"failureLayer":"provider_tool"'));
    expect(report, contains('"durationMs":345'));
    expect(report, contains('provider_auth_required'));
    expect(report, isNot(contains('full sensitive prompt')));
    expect(report, isNot(contains('private source text')));
    expect(report, isNot(contains('secret-key-value')));
    expect(report, isNot(contains('profile-private-value')));
    expect(report, isNot(contains('do something private')));
    expect(report, isNot(contains('live-provider-token')));
    expect(report, isNot(contains('env-secret')));
    expect(report, isNot(contains('PrivateSource')));
    expect(report, isNot(contains('private-cookie')));
    expect(report, isNot(contains('raw provider output')));
  });

  test('records the normalized diagnostic envelope and correlation fields',
      () async {
    final store = WorkerDiagnosticStore(
      directory: Directory('${temporary.path}/logs'),
    );
    await store.record(
      workerTypeId: 'gemini',
      workerVersion: '2.0.0',
      protocolStage: 'execute',
      event: 'assignment.failed',
      requestId: 'request-1',
      assignmentId: 'assignment-1',
      workspaceId: 'workspace-1',
      component: 'workspace_service',
      operation: 'assignment',
      stage: 'provider_session',
      level: 'error',
      errorCode: 'session_resume_failed',
      retryable: true,
      context: {
        'providerToolVersion': '1.2.3',
        'elapsedMs': 12,
        'cacheHit': true,
        'verified': true,
        'mcpPreparationMs': 15,
        'remainingPreparationMs': 5,
        'outputAgeMs': 17,
        'commandPath': '/private/command',
        'prompt': 'must not be exported',
      },
    );

    final decoded = jsonDecode(await store.currentFile.readAsString())
        as Map<String, dynamic>;
    expect(decoded['context']['elapsedMs'], 12);
    expect(decoded['context']['cacheHit'], true);
    expect(decoded['context']['verified'], true);
    expect(decoded['context']['mcpPreparationMs'], 15);
    expect(decoded['context']['remainingPreparationMs'], 5);
    expect(decoded['context']['outputAgeMs'], 17);
    expect(jsonEncode(decoded), isNot(contains('/private/command')));
    expect(decoded['schemaVersion'], 1);
    expect(decoded['eventId'], startsWith('diag-'));
    expect(decoded['requestId'], 'request-1');
    expect(decoded['assignmentId'], 'assignment-1');
    expect(decoded['workspaceId'], 'workspace-1');
    expect(decoded['component'], 'workspace_service');
    expect(decoded['stage'], 'provider_session');
    expect(decoded['severity'], 'error');
    expect(decoded['retryable'], isTrue);
    expect(jsonEncode(decoded), isNot(contains('must not be exported')));
  });

  test('preserves safe Profile diagnostics in reports', () async {
    final store = WorkerDiagnosticStore(
      directory: Directory('${temporary.path}/logs'),
    );
    await store.record(
      workerTypeId: 'chatgpt',
      workerVersion: '8.2.0',
      protocolStage: 'profile_probe',
      event: 'profile.probe.failed',
      errorCode: 'profile_invalid',
      context: {
        'profileDigest': 'a' * 64,
        'privateDetail': 'must not be exported',
      },
    );

    final report = await store.createCopyableReport();
    expect(report, contains('profile_invalid'));
    expect(report, contains('a' * 64));
    expect(report, isNot(contains('must not be exported')));
  });

  test('rotates Worker logs by both size and retained file count', () async {
    final logDirectory = Directory('${temporary.path}/logs');
    final store = WorkerDiagnosticStore(
      directory: logDirectory,
      maxFileBytes: 700,
      maxFiles: 2,
    );
    for (var index = 0; index < 12; index++) {
      await store.record(
        workerTypeId: 'gemini',
        workerVersion: '2.0.0',
        protocolStage: 'execute',
        event: 'assignment.activity',
        runId: 'run-$index',
        context: {'assignmentId': 'run-$index'},
      );
    }

    final files =
        await logDirectory.list().where((entity) => entity is File).toList();
    expect(files, hasLength(2));
    for (final file in files.cast<File>()) {
      expect(await file.length(), lessThanOrEqualTo(700));
    }
    final report = await store.createCopyableReport();
    expect(report, contains('run-11'));
    expect(report, isNot(contains('run-0"')));
  });

  test('copyable report ignores an incomplete crash-tail record', () async {
    final store = WorkerDiagnosticStore(
      directory: Directory('${temporary.path}/logs'),
    );
    await store.record(
      workerTypeId: 'test',
      workerVersion: '0.1.0',
      protocolStage: 'execute',
      event: 'assignment.failed',
      errorCode: 'worker_internal_failure',
      processExitCode: 9,
    );
    await store.currentFile.writeAsString('{truncated', mode: FileMode.append);
    await store.record(
      workerTypeId: 'test',
      workerVersion: '0.1.0',
      protocolStage: 'process_start',
      event: 'process.restarted',
    );

    final report = await store.createCopyableReport();
    expect(report, contains('worker_internal_failure'));
    expect(report, contains('process.restarted'));
    expect(report, contains('processExitCode'));
    expect(report, isNot(contains('{truncated')));
  });

  test('reads bounded safe records for disconnected report assembly', () async {
    final store = WorkerDiagnosticStore(
      directory: Directory('${temporary.path}/logs'),
    );
    for (var index = 0; index < 3; index++) {
      await store.record(
        workerTypeId: 'gemini',
        workerVersion: '2.0.0',
        protocolStage: 'execute',
        event: 'assignment.activity',
        assignmentId: 'assignment-$index',
        context: {
          'status': 'step-$index',
          'prompt': 'must not be retained',
        },
      );
    }

    final records = await store.readSafeRecords(maxRecords: 2);
    expect(records, hasLength(2));
    expect(records.first['assignmentId'], 'assignment-2');
    expect(jsonEncode(records), isNot(contains('must not be retained')));
  });
}
