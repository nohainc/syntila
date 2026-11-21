import 'dart:async';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'engine.dart';
import 'folders.dart';
import 'journal.dart';
import 'mcp_worker_runner.dart';

/// Finds the pinned Profile for an assignment. Null means it is not available
/// locally, and the assignment fails instead of running with another Profile.
///
/// The payload keys that identify the Profile (`profileDigest`,
/// `workerTypeId`) are provisional until ADR-035 fixes the execution snapshot
/// in P5.
typedef ProfileResolver =
    Future<({ToolProfileCandidate candidate, File profileFile})?> Function(
      Map<String, Object?> payload,
    );

/// The adapter between the Agent and the existing generic CLI Worker Engine.
/// The Engine stays a separately supervised child process, and the provider
/// CLI runs inside it on demand. Nothing here builds a command line from Cloud
/// data: the signed Profile decides how the provider is invoked.
class CliEngineLauncher
    implements EngineLauncher, ModelCatalogSource, UsageSource {
  CliEngineLauncher({
    required this.supervisor,
    required this.engineExecutable,
    required this.resolveProfile,
    required this.workerId,
    required this.stateDirectory,
    required this.workRoot,
    this.maxConcurrent = 1,
    this.mcpWorkerRunner,
    this.folders,
  });

  /// The folders this computer allows. A stateful step that names a Space
  /// folder runs there, and only if that folder is still allowed with write.
  final AllowedFolders? folders;

  final CliWorkerEngineSupervisor supervisor;
  final String engineExecutable;
  final ProfileResolver resolveProfile;
  final String workerId;
  final Directory stateDirectory;
  final Directory workRoot;
  final int maxConcurrent;
  final McpWorkerRunner? mcpWorkerRunner;

  @override
  Future<String?> probe() async =>
      await File(engineExecutable).exists() ? null : 'engine_unavailable';

  @override
  Future<int> recoverOrphans() => supervisor.recoverOrphanedProcesses();

  @override
  Future<Map<String, Object?>> discoverModels(Map<String, Object?> pin) async {
    try {
      final resolved = await resolveProfile(pin);
      if (resolved == null) return {'status': 'profile_unavailable'};
      final result = await supervisor.probe(
        resolved.candidate,
        profileFile: resolved.profileFile,
        stateDirectory: stateDirectory,
        mode: WorkerProbeMode.passive,
        timeout: const Duration(seconds: 25),
      );
      final catalog = result.modelCatalog;
      if (catalog == null) {
        // The CLI answered but listed no models (or could not be started).
        return {'status': result.issueCode ?? 'no_models'};
      }
      return {
        'status': 'ok',
        'modelCatalog': catalog.toJson(includeNativeIds: false),
        if (result.providerToolName != null)
          'providerToolName': result.providerToolName,
        if (result.providerToolVersion != null)
          'providerToolVersion': result.providerToolVersion,
      };
    } on Object {
      return {'status': 'probe_failed'};
    }
  }

  @override
  Future<Map<String, Object?>> readUsage(Map<String, Object?> pin) async {
    try {
      final resolved = await resolveProfile(pin);
      if (resolved == null) {
        return {
          'status': 'error',
          'errorCode': 'worker_not_ready',
          'errorMessage': 'The Worker Profile is not available on this computer.',
        };
      }
      if (resolved.candidate.profile['usage'] == null) {
        return {
          'status': 'unavailable',
          'errorCode': 'usage_not_configured',
          'errorMessage': 'This Worker Profile has no usage command.',
        };
      }
      final usage = await supervisor.usage(
        resolved.candidate,
        profileFile: resolved.profileFile,
        stateDirectory: stateDirectory,
      );
      return {
        'status': 'ok',
        'output': usage.output,
        'errorOutput': usage.errorOutput,
        'exitCode': usage.exitCode,
        'truncated': usage.truncated,
      };
    } on CliWorkerEngineProbeException catch (error) {
      return {
        'status': 'error',
        'errorCode': error.issueCode,
        'errorMessage': error.safeMessage,
      };
    } on Object {
      return {
        'status': 'error',
        'errorCode': 'usage_failed',
        'errorMessage': 'The usage report could not be read.',
      };
    }
  }

  @override
  Future<EngineRun> launch(EngineRequest request) async {
    final run = _CliRun(request.assignmentId, supervisor);
    final snapshot = request.payload['snapshot'];
    if (snapshot is! Map<String, Object?>) {
      run._finish(
        const EngineOutcome(TerminalKind.failed, {
          'errorCode': 'execution_failed',
          'message': 'The assignment snapshot is invalid',
          'retryable': false,
        }),
      );
      return run;
    }
    final plugin = snapshot['plugin'];
    ({ToolProfileCandidate candidate, File profileFile})? resolved;
    WorkerExecutor? executor;
    if (plugin != null) {
      try {
        final runner = mcpWorkerRunner;
        final type = snapshot['workerTypeId'];
        if (runner == null ||
            type is! String ||
            !RegExp(r'^plugin-[0-9a-f]{12}$').hasMatch(type))
          throw StateError('invalid MCP Worker target');
        executor = await runner.prepare(plugin);
      } on Object {
        run._finish(
          const EngineOutcome(TerminalKind.failed, {
            'errorCode': 'worker_not_ready',
            'message': 'The MCP Worker is unavailable or needs inspection',
            'retryable': false,
          }),
        );
        return run;
      }
    } else {
      resolved = await resolveProfile(snapshot);
    }
    if (plugin == null && resolved == null) {
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
        : snapshot['objective'] is String
        ? snapshot['objective'] as String
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
      final value = snapshot[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    final queueWait = snapshot['queueWaitTimeoutMs'];
    final policy = snapshot['sessionPolicy'];
    final key = snapshot['sessionKey'];
    WorkerSessionContext? workerSession;
    ConversationBootstrap? statelessContext;
    try {
      if (policy == 'durable_session') {
        if (key is! String ||
            key.isEmpty ||
            snapshot['statelessContext'] != null) {
          throw const FormatException('Invalid durable session');
        }
        final raw = snapshot['workerSession'];
        if (raw == null && snapshot['workRequestId'] != null) {
          throw const FormatException('Missing Worker session context');
        }
        if (raw != null) {
          if (raw is! Map<String, Object?>) {
            throw const FormatException('Invalid Worker session');
          }
          workerSession = WorkerSessionContext.fromJson(raw);
          if (workerSession.workerId != workerId) {
            throw const FormatException('Wrong Worker session');
          }
        }
      } else if (policy == 'stateless') {
        if (key != null || snapshot['workerSession'] != null) {
          throw const FormatException('Invalid stateless session');
        }
        final raw = snapshot['statelessContext'];
        if (raw == null && snapshot['workRequestId'] != null) {
          throw const FormatException('Missing conversation context');
        }
        if (raw != null) {
          if (raw is! Map<String, Object?>) {
            throw const FormatException('Invalid conversation context');
          }
          statelessContext = ConversationBootstrap.fromJson(raw);
        }
      } else {
        throw const FormatException('Invalid session policy');
      }
    } on FormatException {
      run._finish(
        const EngineOutcome(TerminalKind.failed, {
          'errorCode': 'execution_failed',
          'message': 'The assignment session is invalid',
          'retryable': false,
        }),
      );
      return run;
    }
    var workingDirectory = Directory(
      '${workRoot.path}/${request.assignmentId}',
    );
    final spaceFolderId = snapshot['spaceFolderId'];
    if (spaceFolderId is String) {
      String? path;
      final granted = folders == null
          ? const <Map<String, String>>[]
          : await folders!.list();
      for (final folder in granted) {
        if (folder['id'] == spaceFolderId && folder['mode'] == 'write') {
          path = folder['path'];
        }
      }
      try {
        if (path == null || !await Directory(path).exists()) {
          throw FolderRejectedException('the Space folder is not allowed here');
        }
        await folders!.require(path, write: true);
        workingDirectory = Directory(path);
      } on FolderRejectedException {
        run._finish(
          const EngineOutcome(TerminalKind.failed, {
            'errorCode': 'folder_not_approved',
            'message': 'The Space folder is not allowed on this computer',
            'retryable': false,
          }),
        );
        return run;
      }
    }
    unawaited(
      supervisor
          .execute(
            resolved?.candidate,
            profileFile: resolved?.profileFile,
            pluginExecutor: executor,
            pluginWorkerTypeId: executor == null
                ? null
                : snapshot['workerTypeId'] as String,
            stateDirectory: stateDirectory,
            workingDirectory: workingDirectory,
            workerId: workerId,
            maxConcurrentAssignments: maxConcurrent,
            assignmentId: request.assignmentId,
            attemptId: request.attemptId,
            prompt: prompt,
            timeout: request.timeout,
            queueWaitTimeout: queueWait is int
                ? Duration(milliseconds: queueWait)
                : null,
            sessionPolicy: policy == 'durable_session'
                ? WorkerSessionPolicy.durableSession
                : WorkerSessionPolicy.stateless,
            sessionKey: key as String?,
            workerSession: workerSession,
            statelessContext: statelessContext,
            model: text('model'),
            reasoningEffort: text('reasoningEffort'),
            executionPolicy: WorkerExecutionPolicy.restricted,
            onExecutionStarted: run._providerDidStart,
            onActivity: request.onActivity,
          )
          .then<void>(
            (result) => run._finish(
              EngineOutcome(TerminalKind.completed, {
                'summary': 'Completed',
                'output': {'text': result.output},
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

class _CliRun implements EngineRun, EngineStartEvidence {
  _CliRun(this.assignmentId, this._supervisor);

  final String assignmentId;
  final CliWorkerEngineSupervisor _supervisor;
  final Completer<EngineOutcome> _outcome = Completer();
  final Completer<bool> _started = Completer();
  bool cancelRequested = false;

  @override
  Future<EngineOutcome> get outcome => _outcome.future;

  @override
  Future<bool> get providerStarted => _started.future;

  void _providerDidStart() {
    if (!_started.isCompleted) _started.complete(true);
  }

  void _finish(EngineOutcome outcome) {
    if (!_started.isCompleted) _started.complete(false);
    if (!_outcome.isCompleted) _outcome.complete(outcome);
  }

  @override
  Future<void> cancel() async {
    cancelRequested = true;
    await _supervisor.cancel(assignmentId);
  }
}
