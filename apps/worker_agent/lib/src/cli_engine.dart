import 'dart:async';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'engine.dart';
import 'journal.dart';

/// Finds the pinned Profile for an assignment. Null means it is not available
/// locally, and the assignment fails instead of running with another Profile.
///
/// The payload keys that identify the Profile (`profileDigest`,
/// `workerTypeId`) are provisional until ADR-035 fixes the execution snapshot
/// in P5.
typedef ProfileResolver =
    Future<ToolProfileCandidate?> Function(Map<String, Object?> payload);

/// The adapter between the Agent and the existing generic CLI Worker Engine.
/// The Engine stays a separately supervised child process, and the provider
/// CLI runs inside it on demand. Nothing here builds a command line from Cloud
/// data: the signed Profile decides how the provider is invoked.
class CliEngineLauncher implements EngineLauncher {
  CliEngineLauncher({
    required this.supervisor,
    required this.engineExecutable,
    required this.resolveProfile,
    required this.workerId,
    required this.stateDirectory,
    required this.workRoot,
    this.maxConcurrent = 1,
  });

  final CliWorkerEngineSupervisor supervisor;
  final String engineExecutable;
  final ProfileResolver resolveProfile;
  final String workerId;
  final Directory stateDirectory;
  final Directory workRoot;
  final int maxConcurrent;

  @override
  Future<String?> probe() async =>
      await File(engineExecutable).exists() ? null : 'engine_unavailable';

  @override
  Future<int> recoverOrphans() => supervisor.recoverOrphanedProcesses();

  @override
  Future<EngineRun> launch(EngineRequest request) async {
    final run = _CliRun(request.assignmentId, supervisor);
    final candidate = await resolveProfile(request.payload);
    if (candidate == null) {
      run._finish(
        const EngineOutcome(TerminalKind.failed, {
          'errorCode': 'worker_not_ready',
          'message': 'The pinned Worker Profile is not available on this host',
          'retryable': false,
        }),
      );
      return run;
    }
    final input = request.payload['input'];
    final prompt = input is Map && input['prompt'] is String
        ? input['prompt'] as String
        : request.payload['prompt'] is String
        ? request.payload['prompt'] as String
        : null;
    if (prompt == null) {
      run._finish(
        const EngineOutcome(TerminalKind.failed, {
          'errorCode': 'execution_failed',
          'message': 'The assignment carried no prompt',
          'retryable': false,
        }),
      );
      return run;
    }
    String? text(String key) {
      final value = request.payload[key] ?? (input is Map ? input[key] : null);
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    final queueWait = request.payload['queueWaitTimeoutMs'];
    unawaited(
      supervisor
          .execute(
            candidate,
            stateDirectory: stateDirectory,
            workingDirectory: Directory(
              '${workRoot.path}/${request.assignmentId}',
            ),
            workerId: workerId,
            maxConcurrentAssignments: maxConcurrent,
            assignmentId: request.assignmentId,
            attemptId: request.attemptId,
            prompt: prompt,
            timeout: request.timeout,
            queueWaitTimeout: queueWait is int
                ? Duration(milliseconds: queueWait)
                : null,
            sessionPolicy: WorkerSessionPolicy.stateless,
            model: text('model'),
            reasoningEffort: text('reasoningEffort'),
            executionPolicy: WorkerExecutionPolicy.restricted,
          )
          .then<void>(
            (result) => run._finish(
              EngineOutcome(TerminalKind.completed, {
                'summary': 'Completed',
                'output': result.output,
                'artifactIds': result.artifacts,
              }),
            ),
            onError: (Object error) => run._finish(
              outcomeForError(error, cancelled: run.cancelRequested),
            ),
          ),
    );
    return run;
  }
}

/// A failed or cancelled outcome that carries only a stable code: never the
/// provider's output, paths or credentials.
EngineOutcome outcomeForError(Object error, {required bool cancelled}) {
  if (cancelled) {
    return const EngineOutcome(TerminalKind.cancelled, {'reason': 'Cancelled'});
  }
  if (error is WorkerFailure) {
    return EngineOutcome(TerminalKind.failed, {
      'errorCode': error.code,
      'message': error.message,
      'retryable': error.retryable,
    });
  }
  if (error is TimeoutException) {
    return const EngineOutcome(TerminalKind.failed, {
      'errorCode': 'timeout',
      'message': 'The Worker did not finish in time',
      'retryable': true,
    });
  }
  return const EngineOutcome(TerminalKind.failed, {
    'errorCode': 'execution_failed',
    'message': 'The Engine could not run this assignment',
    'retryable': false,
  });
}

class _CliRun implements EngineRun {
  _CliRun(this.assignmentId, this._supervisor);

  final String assignmentId;
  final CliWorkerEngineSupervisor _supervisor;
  final Completer<EngineOutcome> _outcome = Completer();
  bool cancelRequested = false;

  @override
  Future<EngineOutcome> get outcome => _outcome.future;

  void _finish(EngineOutcome outcome) {
    if (!_outcome.isCompleted) _outcome.complete(outcome);
  }

  @override
  Future<void> cancel() async {
    cancelRequested = true;
    await _supervisor.cancel(assignmentId);
  }
}
