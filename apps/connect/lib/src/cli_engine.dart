import 'dart:async';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'engine.dart';
import 'folders.dart';
import 'journal.dart';
import 'mcp_worker_runner.dart';
import 'output_images.dart';
import 'server_api.dart';

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
    this.fullAccess,
    this.placeInputs,
  });

  /// The owner's local choice (read per assignment): the provider CLI may run
  /// any command without asking. Null or false keeps the restricted policy.
  final Future<bool> Function()? fullAccess;

  /// The folders this computer allows. A stateful step that names a Space
  /// folder runs there, and only if that folder is still allowed with write.
  final AllowedFolders? folders;

  /// Puts the request's delivered files under `.syntila/inputs/` in the
  /// working directory right before launch (Input Delivery v1).
  final Future<void> Function(
    Directory workingDirectory,
    Map<String, Object?> payload,
  )?
  placeInputs;

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
        // The CLI answered but listed no models (or could not be started):
        // keep what it said, not only a code.
        final said = [
          for (final check in result.checks)
            if (check.status == ProbeCheckStatus.failed) check.message,
        ].join('\n');
        return {
          'status': result.issueCode ?? 'no_models',
          if (said.isNotEmpty) 'message': said,
        };
      }
      return {
        'status': 'ok',
        'modelCatalog': catalog.toJson(includeNativeIds: false),
        if (result.providerToolName != null)
          'providerToolName': result.providerToolName,
        if (result.providerToolVersion != null)
          'providerToolVersion': result.providerToolVersion,
      };
    } on Object catch (error) {
      final said = (error is FormatException ? error.message : '$error')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return {
        'status': 'probe_failed',
        if (said.isNotEmpty)
          'message': said.length > 600 ? '${said.substring(0, 600)}…' : said,
      };
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
          'errorMessage':
              'The Worker Profile is not available on this computer.',
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

  Future<WorkerExecutionPolicy> _policyFor(
    EngineRequest request,
    Map<String, Object?> snapshot,
  ) async {
    bool allowed;
    try {
      allowed = await (fullAccess?.call() ?? Future.value(false));
    } on Object {
      allowed = false;
    }
    // A Person Share is another person's Chat on this computer: always the
    // provider's read-only mode, never full access (ADR-043).
    if (snapshot['personShare'] == true) {
      return WorkerExecutionPolicy.providerDefault;
    }
    final readOnly =
        request.payload['readOnly'] == true || snapshot['readOnly'] == true;
    // Read-only steps (Chat, Research, ...) see the Space folder but stay in
    // the provider's read-only mode, with or without full access. Plan is the
    // exception with full access: it explores the project with shell commands,
    // which a headless provider mode cannot approve.
    if (readOnly) {
      return allowed && snapshot['role'] == 'plan'
          ? WorkerExecutionPolicy.fullAccess
          : WorkerExecutionPolicy.providerDefault;
    }
    return allowed
        ? WorkerExecutionPolicy.fullAccess
        : WorkerExecutionPolicy.restricted;
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
            !RegExp(r'^plugin-[0-9a-f]{12}$').hasMatch(type)) {
          throw StateError('invalid MCP Worker target');
        }
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
    final personShare = snapshot['personShare'] == true;
    // A Person Share never sees a folder of this computer; it answers in the
    // empty scratch directory of its assignment.
    final spaceFolderId = personShare ? null : snapshot['spaceFolderId'];
    // Steps without a Thread lease (Chat, Plan, Research) read the folder and
    // work without it; stateful steps need write access to it.
    final readsFolder = snapshot['leaseId'] == null;
    if (spaceFolderId is String) {
      String? path;
      final granted = folders == null
          ? const <Map<String, String>>[]
          : await folders!.list();
      for (final folder in granted) {
        if (folder['id'] == spaceFolderId &&
            (folder['mode'] == 'write' || readsFolder)) {
          path = folder['path'];
        }
      }
      try {
        if (path == null || !await Directory(path).exists()) {
          throw FolderRejectedException('the Space folder is not allowed here');
        }
        await folders!.require(path, write: !readsFolder);
        workingDirectory = Directory(path);
      } on FolderRejectedException {
        // Not required without a lease: keep the scratch directory.
        if (readsFolder) {
          path = null;
        } else {
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
    }
    if (placeInputs != null) {
      try {
        await workingDirectory.create(recursive: true);
        await placeInputs!(workingDirectory, request.payload);
      } on Object catch (error) {
        run._finish(
          EngineOutcome(TerminalKind.failed, {
            'errorCode': 'execution_failed',
            'message':
                'The files for this request could not be prepared: $error',
            // Only a bounded, path-free description crosses the network.
            'providerFailure': {
              'schemaVersion': 1,
              'source': 'agent',
              'providerErrorText':
                  error is ServerRefusal &&
                      error.status >= 400 &&
                      error.status <= 599
                  ? 'The request’s attachment could not be downloaded (HTTP ${error.status}).'
                  : 'The request’s attached files could not be prepared on this Worker.',
            },
            'retryable': true,
          }),
        );
        return run;
      }
    }
    // Images for the user go to the assignment's own folder, outside the
    // Space folder, so the project is never touched.
    final imagesDirectory = Directory(
      '${workRoot.path}/${request.assignmentId}/outputs',
    );
    try {
      await imagesDirectory.create(recursive: true);
    } on Object {
      // Linked provider images are still picked up.
    }
    // Read-only steps (Chat, Plan, Research) cannot save files; their
    // linked provider images are still picked up.
    final readOnlyStep =
        personShare ||
        request.payload['readOnly'] == true ||
        snapshot['readOnly'] == true;
    final imageDirectories = [
      imagesDirectory.path,
      // The Engine copies Codex's images here.
      '${workingDirectory.path}/.syntila/outputs/${request.assignmentId}',
    ];
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
            prompt: readOnlyStep
                ? prompt
                : promptWithOutputImages(prompt, imagesDirectory.path),
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
            executionPolicy: await _policyFor(request, snapshot),
            onExecutionStarted: run._providerDidStart,
            onActivity: request.onActivity,
          )
          .then<void>(
            (result) async {
              var text = result.output;
              var images = const <String>[];
              try {
                images = await collectOutputImages(
                  imageDirectories,
                  linkedImages(text, [
                    ...imageDirectories,
                    ...providerImageRoots(Platform.environment),
                  ]),
                );
                text = withoutImageLinks(text, images);
              } on Object {
                images = const [];
              }
              run._finish(
                EngineOutcome(TerminalKind.completed, {
                  'summary': 'Completed',
                  'output': {'text': text},
                  'artifactIds': result.artifacts,
                  if (images.isNotEmpty) localOutputImagesKey: images,
                }),
              );
            },
            onError: (Object error) => run._finish(
              outcomeForError(error, cancelled: run.cancelRequested),
            ),
          ),
    );
    return run;
  }
}

/// Engine issue codes as the Cloud's execution error codes. A code the Cloud
/// does not list ends as `execution_failed`; the original text still travels.
String _cloudCodeForIssue(String issue) => switch (issue) {
  'provider_tool_unavailable' => 'cli_not_found',
  'provider_authentication_required' => 'authentication_required',
  'unsupported_provider_tool_version' => 'unsupported_cli_version',
  'deadline_exceeded' => 'timeout',
  'cancelled' => 'cancelled',
  'model_not_supported' => 'model_not_supported',
  'quota_exhausted' => 'quota_exhausted',
  'provider_unavailable' => 'provider_unavailable',
  'permission_denied' => 'permission_denied',
  'context_limit_exceeded' => 'context_limit_exceeded',
  _ => 'execution_failed',
};

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
      // What the Engine reported, not only its code.
      if (error.diagnostics != null && error.diagnostics!.isNotEmpty)
        'detail': error.diagnostics,
    });
  }
  if (error is CliWorkerEngineProbeException) {
    // The provider CLI's own failure text travels with the failure so the owner
    // sees what the CLI said (the Cloud stores it encrypted).
    final code = _cloudCodeForIssue(error.issueCode);
    final detail = SafeProviderDiagnostics.safeFailureDetail(
      error.localDiagnostics ?? error.safeMessage,
    );
    return EngineOutcome(TerminalKind.failed, {
      'errorCode': code,
      'message': error.safeMessage,
      'retryable': !const {
        'cancelled',
        'permission_denied',
        'authentication_required',
        'cli_not_found',
        'unsupported_cli_version',
        'model_not_supported',
        'quota_exhausted',
        'context_limit_exceeded',
      }.contains(code),
      if (error.providerFailure != null)
        'providerFailure': error.providerFailure,
      if (detail != null) 'detail': detail,
      'diagnostic': error.runtimeType.toString(),
    });
  }
  if (error is TimeoutException) {
    return const EngineOutcome(TerminalKind.failed, {
      'errorCode': 'timeout',
      'message': 'The Worker did not finish in time',
      'retryable': true,
    });
  }
  final detail = SafeProviderDiagnostics.safeFailureDetail(error);
  return EngineOutcome(TerminalKind.failed, {
    'errorCode': 'execution_failed',
    'message': 'The Engine could not run this assignment',
    'retryable': false,
    if (detail != null) 'detail': detail,
    // Local only (never sent to the Cloud): the agent log names the exception.
    'diagnostic': error.runtimeType.toString(),
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
