import 'external_worker_executor.dart' show isExternalWorkerType;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'cloud_connection.dart';
import 'assignment_startup.dart';
import 'runtime_capabilities.dart';
import 'space_directory.dart';
import 'thread_directory.dart';
import 'work_request_input_staging.dart';
import 'worker_launch_plan.dart';

/// Translate assignment policy without consulting names or providers.
///
/// Full local access is a local Workspace decision. The assignment may request
/// it, but it is accepted only when the persisted host-owner authorization for
/// the selected Worker is present.
WorkerExecutionPolicy assignmentExecutionPolicy(
  Map<String, Object?> payload, {
  bool fullAccessAuthorized = false,
}) {
  final requested = payload['executionPolicy'];
  if (requested == 'full_access') {
    if (!fullAccessAuthorized) {
      throw const AssignmentExecutionFailure(
        code: 'permission_denied',
        message: 'Full local access is not authorized for this Worker.',
      );
    }
    return WorkerExecutionPolicy.fullAccess;
  }
  if (requested != null &&
      requested != 'restricted' &&
      requested != 'provider_default') {
    throw const AssignmentExecutionFailure(
      code: 'permission_denied',
      message: 'The requested execution policy is not supported.',
    );
  }
  // A read-only assignment must stay provider-controlled even when the local
  // Worker is authorized for Full Local Access. `stateless_read` by itself is
  // not enough to force the read-only policy: some one-shot Work requests are
  // stateless while still allowing repository and shell operations.
  if (payload['readOnly'] == true) {
    return WorkerExecutionPolicy.providerDefault;
  }
  if (requested == 'provider_default') {
    return WorkerExecutionPolicy.providerDefault;
  }
  if (requested == 'restricted') {
    return WorkerExecutionPolicy.restricted;
  }
  // Once the owner has enabled Full Local Access for this Worker, ordinary
  // non-read-only assignments inherit it unless Cloud explicitly asks for a
  // narrower policy. This keeps old assignment payloads working while making
  // the local setting effective.
  if (fullAccessAuthorized) return WorkerExecutionPolicy.fullAccess;
  return payload['executionClass'] == 'stateless_read'
      ? WorkerExecutionPolicy.providerDefault
      : WorkerExecutionPolicy.restricted;
}

/// Per-file sanity bound (the largest plan limit); Cloud enforces each
/// account's own limit at upload time.
const _maxWorkRequestFileBytes = maxWorkRequestInputBytes;

/// Re-downloads an input the local store no longer has.
typedef WorkRequestInputFetcher = Future<void> Function({
  required String fileId,
  required int sizeBytes,
  required String contentDigest,
});

/// Writes each file input to `.syntila/inputs/<work-request-id>/file-NNN`
/// from the Input Delivery store. Cloud dispatches only after every input is
/// delivered; [fetch] covers a copy removed since (retention, later retry).
Future<void> _materializeWorkRequestInputs({
  required Directory threadDirectory,
  required Map<String, Object?> payload,
  WorkRequestInputStaging? staging,
  WorkRequestInputFetcher? fetch,
}) async {
  final rawRequestId = payload['workRequestId'];
  final inputValue = payload['input'];
  if (inputValue is! Map || inputValue['attachments'] is! List) return;
  final attachments = inputValue['attachments'] as List;
  if (attachments.length > 10) {
    throw StateError('too many Work Request attachments');
  }
  if (rawRequestId is! String ||
      !RegExp(r'^work-request-[0-9a-f-]{36}$').hasMatch(rawRequestId)) {
    if (attachments.any((value) => value is Map && value['kind'] == 'file')) {
      throw StateError('invalid Work Request attachment scope');
    }
    return;
  }
  final root =
      Directory('${threadDirectory.path}${Platform.pathSeparator}.syntila');
  final inputs = Directory('${root.path}${Platform.pathSeparator}inputs');
  final requestDirectory =
      Directory('${inputs.path}${Platform.pathSeparator}$rawRequestId');
  for (final directory in [root, inputs, requestDirectory]) {
    final type =
        await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory)) {
      throw StateError('unsafe Work Request input directory');
    }
    if (type == FileSystemEntityType.notFound) await directory.create();
  }
  for (var index = 0; index < attachments.length; index++) {
    final value = attachments[index];
    if (value is! Map || value['kind'] != 'file') continue;
    final fileId = value['fileId'];
    final sizeBytes = value['sizeBytes'];
    final digest = value['contentDigest'];
    if (staging == null ||
        !isWorkRequestInputId(fileId) ||
        sizeBytes is! int ||
        sizeBytes > _maxWorkRequestFileBytes ||
        digest is! String) {
      throw StateError('invalid Work Request file input');
    }
    try {
      if (fetch != null && !await staging.contains(fileId as String)) {
        await fetch(
            fileId: fileId, sizeBytes: sizeBytes, contentDigest: digest);
      }
    } on WorkRequestInputStagingException catch (error) {
      throw AssignmentExecutionFailure(
          code: 'execution_failed', message: error.message);
    } on IOException {
      throw const AssignmentExecutionFailure(
          code: 'execution_failed',
          message: 'A file for this request could not be downloaded.');
    }
    final target = File(
        '${requestDirectory.path}${Platform.pathSeparator}file-${(index + 1).toString().padLeft(3, '0')}');
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file)) {
      throw StateError('unsafe Work Request input file');
    }
    try {
      if (type == FileSystemEntityType.file) {
        // A retry reuses the copy already in the execution directory; compare
        // by streamed digest so a large file is never held in memory.
        final existing = await WorkRequestInputStaging.describe(target);
        if (existing.length != sizeBytes || existing.digest != digest) {
          throw StateError(
              'Work Request input changed across assignment retry');
        }
      } else {
        await staging.copyTo(
            fileId: fileId as String,
            sizeBytes: sizeBytes,
            contentDigest: digest,
            target: target);
      }
    } on WorkRequestInputStagingException catch (error) {
      throw AssignmentExecutionFailure(
          code: 'execution_failed', message: error.message);
    } on IOException {
      throw const AssignmentExecutionFailure(
          code: 'execution_failed',
          message: 'A file for this request could not be downloaded.');
    }
  }
}

/// Provider-independent guidance attached to every Space execution.
/// It describes the local directory contract without exposing paths or
/// turning Git operations into a Syntila-managed subsystem.
const threadExecutionGuidance = <String>[
  'This directory is the Space persistent working area shared by its Threads.',
  'Reuse existing files and repositories when they are present.',
  'Clone repositories here when the requested work needs one.',
  'Do not assume this directory is disposable; preserve useful local state.',
  'Use normal Git safety practices for fetch, branch, commit, and push.',
  'For parallel Threads using one repository, prefer a dedicated branch per Thread.',
  'Fetch before integrating remote changes.',
  'Commit and push meaningful state before moving work to another physical Workspace.',
  'Use Workspace-local Git, SSH, or provider CLI authentication for private repositories.',
];

typedef WorkerOutputImagePublisher = Future<List<Map<String, Object?>>>
    Function(WorkspaceAssignmentContext context, Directory workingDirectory);

typedef AssignmentLogicalWorkerResolver = FutureOr<AssignmentLogicalWorker?>
    Function(String workerId);
typedef ToolProfileAssignmentExecutor = Future<WorkerResult> Function(
  AssignmentLogicalWorker worker,
  Directory workingDirectory,
  WorkspaceAssignmentContext context,
  Map<String, Object?> payload, {
  void Function(WorkerProgress progress)? onProgress,
});

typedef ToolProfileActivityAssignmentExecutor = Future<WorkerResult> Function(
  AssignmentLogicalWorker worker,
  Directory workingDirectory,
  WorkspaceAssignmentContext context,
  Map<String, Object?> payload, {
  void Function(WorkerProgress progress)? onProgress,
  FutureOr<void> Function()? onSlotReserved,
  FutureOr<bool> Function()? authorizeStart,
  void Function()? onEngineProcessStarted,
  FutureOr<void> Function(WorkerActivity activity)? onActivity,
});
typedef WorkerExecutionStartedRelay = FutureOr<void> Function(
  WorkspaceAssignmentContext context,
);
typedef WorkerExecutionSlotReservedRelay = FutureOr<void> Function(
  WorkspaceAssignmentContext context,
);
typedef WorkerExecutionStartAuthorizer = FutureOr<bool> Function(
  WorkspaceAssignmentContext context,
);
typedef WorkerEngineProcessStartedRelay = void Function(
  WorkspaceAssignmentContext context,
);

class AssignmentLogicalWorker {
  const AssignmentLogicalWorker({
    required this.id,
    required this.workerTypeId,
    required this.enabled,
    required this.ready,
    required this.permissions,
    required this.localConcurrencyLimit,
    this.fullLocalAccessAuthorized = false,
    this.providerCliVersion,
    this.notReadyReason,
  });

  final String id;
  final String workerTypeId;
  final bool enabled;
  final bool ready;
  final Set<String> permissions;
  final int localConcurrencyLimit;
  final bool fullLocalAccessAuthorized;
  final String? providerCliVersion;

  /// Why the Worker is not ready when that is known locally without any
  /// network call (for example `catalog_not_synchronized`). Diagnostic only.
  final String? notReadyReason;
}

class WorkerAssignmentScope {
  const WorkerAssignmentScope({
    required this.worker,
    required this.workingDirectory,
  });

  final AssignmentLogicalWorker worker;
  final Directory workingDirectory;
}

class WorkerAssignmentHandler {
  WorkerAssignmentHandler({
    required this.resolveLogicalWorker,
    this.executeWithToolProfile,
    this.executeWithActivity,
    this.defaultWorkingDirectory,
    this.applicationStateDirectory,
    this.inputStaging,
    this.fetchInput,
    this.spaceDirectoryLifecycle,
    SpaceMutationCoordinator? spaceMutationCoordinator,
    this.threadDirectoryLifecycle,
    ThreadMutationCoordinator? threadMutationCoordinator,
    this.onProgress,
    this.onActivity,
    this.onExecutionStarted,
    this.onExecutionSlotReserved,
    this.authorizeExecutionStart,
    this.onEngineProcessStarted,
    this.cancelToolProfileAssignment,
    this.resolveLaunchPlan,
    this.onStartupStage,
    this.publishOutputImages,
  })  : spaceMutationCoordinator = spaceMutationCoordinator ??
            (spaceDirectoryLifecycle == null
                ? null
                : SpaceMutationCoordinator(
                    lifecycle: spaceDirectoryLifecycle,
                    applicationStateDirectory: applicationStateDirectory ??
                        Directory(
                            '${Directory.current.path}${Platform.pathSeparator}.syntila-mutation-state'),
                  )),
        threadMutationCoordinator = threadMutationCoordinator ??
            (threadDirectoryLifecycle == null
                ? null
                : ThreadMutationCoordinator(threadDirectoryLifecycle));

  final AssignmentLogicalWorkerResolver resolveLogicalWorker;
  final ToolProfileAssignmentExecutor? executeWithToolProfile;
  final ToolProfileActivityAssignmentExecutor? executeWithActivity;
  final Directory? defaultWorkingDirectory;
  final Directory? applicationStateDirectory;

  /// Input Delivery v1 store and its re-download fallback.
  final WorkRequestInputStaging? inputStaging;
  final WorkRequestInputFetcher? fetchInput;
  final SpaceDirectoryLifecycle? spaceDirectoryLifecycle;
  final SpaceMutationCoordinator? spaceMutationCoordinator;
  final ThreadDirectoryLifecycle? threadDirectoryLifecycle;
  final ThreadMutationCoordinator? threadMutationCoordinator;
  final WorkerProgressRelay? onProgress;
  final WorkerActivityRelay? onActivity;
  final WorkerExecutionStartedRelay? onExecutionStarted;
  final WorkerExecutionSlotReservedRelay? onExecutionSlotReserved;
  final WorkerExecutionStartAuthorizer? authorizeExecutionStart;
  final WorkerEngineProcessStartedRelay? onEngineProcessStarted;
  final Future<bool> Function(String assignmentId)? cancelToolProfileAssignment;

  /// Resolves the prepared launch plan for an admitted assignment. It must
  /// answer from local state only; it throws [AssignmentExecutionFailure] with
  /// a specific diagnostic when no compatible Profile is available.
  final Future<WorkerLaunchPlan> Function(AssignmentLogicalWorker worker)?
      resolveLaunchPlan;

  /// Receives local startup milestones (worker resolved, profile ready,
  /// waiting for Space, ...). Observation only.
  final AssignmentStartupRelay? onStartupStage;

  /// Uploads the images the Worker left for the user and returns their
  /// descriptors for the result's `output.images`.
  final WorkerOutputImagePublisher? publishOutputImages;
  final _cancellationRequests = <String>{};

  /// Wake-ups for assignments waiting on the Space/Thread mutation lock, so
  /// a cancellation or an exhausted queue allowance ends the wait at once.
  final _spaceWaitCancels = <String, void Function()>{};
  final _pinnedLaunchPlans = <String, WorkerLaunchPlan>{};

  /// The launch plan this assignment was admitted with. Later Profile
  /// activations, rollbacks and refreshes never change it, including while the
  /// assignment waits for a Space lock or a Worker slot.
  WorkerLaunchPlan? pinnedLaunchPlan(String assignmentId) =>
      _pinnedLaunchPlans[assignmentId];

  /// Resolves the local Logical Worker and Workspace-owned execution directory.
  Future<WorkerAssignmentScope> prepareAssignmentScope(
      WorkspaceAssignmentContext context) async {
    final workerId = context.payload['workerId'];
    if (workerId is! String || workerId.isEmpty) {
      throw StateError('assignment workerId is required');
    }
    final worker = await resolveLogicalWorker(workerId);
    final expectedWorkerTypeId = context.payload['workerTypeId'];
    if (expectedWorkerTypeId is! String ||
        expectedWorkerTypeId.isEmpty ||
        worker == null ||
        worker.id != workerId ||
        worker.workerTypeId != expectedWorkerTypeId ||
        !worker.enabled ||
        !worker.ready) {
      throw AssignmentExecutionFailure(
        code: 'worker_not_ready',
        message: 'Worker is not ready for assignments.',
        localDiagnostic: worker?.notReadyReason == null
            ? null
            : jsonEncode({
                'schemaVersion': 1,
                'component': 'workspace_service',
                'stage': 'worker_resolution',
                'errorCode': 'worker_not_ready',
                'providerStarted': false,
                'reason': worker!.notReadyReason,
              }),
      );
    }
    if (worker.localConcurrencyLimit < 1) {
      throw StateError('local Worker concurrency limit must be positive');
    }
    rejectWorkerControlledPaths(context.payload);
    final executionClass = context.payload['executionClass'];
    final spaceId = _requiredStringForThread(
        context.payload['spaceId'], 'spaceId', executionClass);
    _requiredStringForThread(
        context.payload['threadId'], 'threadId', executionClass);
    var directory = defaultWorkingDirectory ?? Directory.current;
    if (spaceId != null) {
      final spaceLifecycle = spaceDirectoryLifecycle;
      if (spaceLifecycle != null) {
        try {
          directory = await spaceLifecycle.ensureForExecution(
            spaceId: spaceId,
            spaceName: _spaceName(context.payload),
            adoptExistingFolder: _adoptSpaceFolder(context.payload),
            ownerUserId: _optionalString(context.payload['spaceOwnerUserId']),
          );
        } on SpaceFolderExistsException {
          throw _spaceFolderFailure();
        }
      } else {
        final legacyLifecycle = threadDirectoryLifecycle;
        if (legacyLifecycle == null) {
          throw const RuntimeViolation(
              'Space directory lifecycle is required for scoped execution');
        }
        final threadId = _requiredStringForThread(
            context.payload['threadId'], 'threadId', executionClass);
        if (threadId == null) {
          throw const RuntimeViolation(
              'Thread ID is required for legacy scoped execution');
        }
        directory = await legacyLifecycle.ensureForExecution(
          spaceId: spaceId,
          threadId: threadId,
        );
      }
      await _materializeWorkRequestInputs(
        threadDirectory: directory,
        payload: context.payload,
        staging: inputStaging,
        fetch: fetchInput,
      );
    }
    return WorkerAssignmentScope(worker: worker, workingDirectory: directory);
  }

  Future<WorkspaceAssignmentResult> call(
      WorkspaceAssignmentContext context) async {
    try {
      return await _call(context);
    } finally {
      _pinnedLaunchPlans.remove(context.assignmentId);
    }
  }

  Future<WorkspaceAssignmentResult> _call(
      WorkspaceAssignmentContext context) async {
    if (_cancellationRequests.remove(context.assignmentId)) {
      throw const AssignmentExecutionFailure(
        code: 'cancelled',
        message: 'The assignment was cancelled before Engine launch.',
      );
    }
    final scope = await prepareAssignmentScope(context);
    final worker = scope.worker;
    final workerId = worker.id;
    _startup(context, AssignmentStartupStage.workerResolved);
    // Validate the policy before any provider process is started. This keeps
    // Cloud payloads from elevating a local Worker by themselves.
    assignmentExecutionPolicy(
      context.payload,
      fullAccessAuthorized: worker.fullLocalAccessAuthorized,
    );
    if (worker.fullLocalAccessAuthorized &&
        !worker.permissions.containsAll(const {
          'repository:read',
          'repository:write',
          'shell:execute',
          'network:use',
        })) {
      throw const AssignmentExecutionFailure(
        code: 'permission_denied',
        message: 'Full local access permissions are incomplete.',
      );
    }
    final allowed = worker.permissions;
    if (context.payload['permissionSnapshot'] != null) {
      validateAssignmentScope(
        context.payload,
        localWorkerPermissions: allowed,
      );
    }
    final requestedPermissions = context.payload['permissions'];
    if (requestedPermissions != null) {
      if (requestedPermissions is! List ||
          requestedPermissions.any((item) => item is! String)) {
        throw AssignmentExecutionFailure(
          code: 'permission_denied',
          message: executionErrorMessage('permission_denied'),
        );
      }
      final denied = requestedPermissions.whereType<String>().firstWhere(
          (permission) => !runtimePermissionAllowed(permission, allowed),
          orElse: () => '');
      if (denied.isNotEmpty) {
        throw AssignmentExecutionFailure(
          code: 'permission_denied',
          message: executionErrorMessage('permission_denied'),
        );
      }
    }
    // Pin the prepared Profile now, at admission: the assignment keeps this
    // exact identity through any Space-lock or Worker-slot wait.
    final planResolver = resolveLaunchPlan;
    // Plugin Workers have no Tool Profile; their identity is verified at launch.
    if (planResolver != null && !isExternalWorkerType(worker.workerTypeId)) {
      final plan = await planResolver(worker);
      _pinnedLaunchPlans[context.assignmentId] = plan;
      _startup(context, AssignmentStartupStage.profileReady, {
        'profileReleaseVersion': plan.profileRevision,
        'profileDigest': plan.profileDigest,
        'profileResolutionSource': plan.source.name,
      });
    }
    // Local queue allowance still available to the Engine supervisor after
    // any wait for the Space lock; set once the lock is acquired.
    Duration? queueAllowanceRemaining;
    Future<WorkspaceAssignmentResult> execute() async {
      if (_cancellationRequests.remove(context.assignmentId)) {
        throw const AssignmentExecutionFailure(
          code: 'cancelled',
          message: 'The assignment was cancelled before Engine launch.',
        );
      }
      final workerPayload = <String, Object?>{
        ..._withCorrelation(context.payload, context),
        if (queueAllowanceRemaining != null)
          'queueWaitTimeoutMs': queueAllowanceRemaining!.inMilliseconds,
      };
      final profileExecutor = executeWithToolProfile;
      final activityProfileExecutor = executeWithActivity;
      if (profileExecutor == null && activityProfileExecutor == null) {
        throw StateError('Tool Profile Engine assignment runner is required');
      }
      var startupRelay = Future<void>.value();
      void relayProgress(WorkerProgress progress) {
        if (progress.message == workerProviderExecutionStartedMessage) {
          final started = onExecutionStarted;
          if (started != null) {
            startupRelay = startupRelay.then(
              (_) => Future<void>.sync(() => started(context)),
            );
          }
          return;
        }
        onProgress?.call(context, progress);
      }

      final engineResult = activityProfileExecutor != null
          ? await activityProfileExecutor(
              worker,
              scope.workingDirectory,
              context,
              workerPayload,
              onProgress: relayProgress,
              onSlotReserved: onExecutionSlotReserved == null
                  ? null
                  : () => onExecutionSlotReserved!(context),
              authorizeStart: authorizeExecutionStart == null
                  ? null
                  : () => authorizeExecutionStart!(context),
              onEngineProcessStarted: onEngineProcessStarted == null
                  ? null
                  : () => onEngineProcessStarted!(context),
              onActivity: onActivity == null
                  ? null
                  : (activity) => onActivity!(context, activity),
            )
          : await profileExecutor!(
              worker,
              scope.workingDirectory,
              context,
              workerPayload,
              onProgress: relayProgress,
            );
      await startupRelay;
      if (_cancellationRequests.remove(context.assignmentId)) {
        throw const AssignmentExecutionFailure(
          code: 'cancelled',
          message: 'The assignment was cancelled before terminal delivery.',
        );
      }
      final images = publishOutputImages == null
          ? const <Map<String, Object?>>[]
          : await publishOutputImages!(context, scope.workingDirectory);
      final output = {
        'summary': engineResult.output.isEmpty
            ? 'Worker $workerId completed assignment'
            : engineResult.output,
        'output': {
          'text': engineResult.output,
          if (images.isNotEmpty) 'images': images,
        },
        'artifactIds': engineResult.artifacts,
      };
      final summary = output['summary'];
      final nestedOutput = output['output'];
      return WorkspaceAssignmentResult(
        summary: summary is String && summary.isNotEmpty
            ? summary
            : 'Worker $workerId completed assignment',
        output: nestedOutput is Map
            ? Map<String, Object?>.from(nestedOutput)
            : output,
        artifactIds: output['artifactIds'] is List
            ? (output['artifactIds'] as List).whereType<String>().toList()
            : const [],
      );
    }

    if (context.payload['executionClass'] != 'stateful_thread') {
      return execute();
    }
    final spaceId = context.payload['spaceId'];
    final threadId = context.payload['threadId'];
    final leaseId = context.payload['leaseId'];
    final fencingToken = context.payload['fencingToken'];
    if (spaceId is! String ||
        threadId is! String ||
        leaseId is! String ||
        fencingToken is! int) {
      throw const RuntimeViolation(
          'stateful assignment requires Thread lease identity');
    }
    final spaceCoordinator = spaceMutationCoordinator;
    if (spaceCoordinator != null) {
      return _awaitMutation(
        context,
        (acquired) async {
          try {
            return await spaceCoordinator.withMutation(
              spaceId: spaceId,
              threadId: threadId,
              spaceName: _spaceName(context.payload),
              adoptExistingFolder: _adoptSpaceFolder(context.payload),
              ownerUserId: _optionalString(context.payload['spaceOwnerUserId']),
              leaseId: leaseId,
              fencingToken: fencingToken,
              action: (_) {
                acquired();
                return execute();
              },
            );
          } on SpaceFolderExistsException {
            // Same recoverable, user-confirmed outcome as the stateless path:
            // the Space's folder is occupied or claimed by another Space.
            throw _spaceFolderFailure();
          }
        },
        (remaining) => queueAllowanceRemaining = remaining,
      );
    }
    final legacyCoordinator = threadMutationCoordinator;
    if (legacyCoordinator == null) {
      throw const RuntimeViolation(
          'Space mutation coordinator is required for stateful execution');
    }
    return _awaitMutation(
      context,
      (acquired) => legacyCoordinator.withMutation(
        spaceId: spaceId,
        threadId: threadId,
        leaseId: leaseId,
        fencingToken: fencingToken,
        action: (_) {
          acquired();
          return execute();
        },
      ),
      (remaining) => queueAllowanceRemaining = remaining,
    );
  }

  AssignmentExecutionFailure _spaceFolderFailure() =>
      AssignmentExecutionFailure(
        code: 'space_folder_exists',
        message: executionErrorMessage('space_folder_exists'),
        retryable: false,
      );

  /// Waits for the Space/Thread mutation lock as a visible, cancellable and
  /// bounded queue stage. The wait happens before a Worker slot is reserved
  /// (so it never holds capacity other assignments could use), counts against
  /// the same local queue allowance as the slot wait, and ends immediately on
  /// cancellation instead of when the lock finally frees.
  Future<WorkspaceAssignmentResult> _awaitMutation(
    WorkspaceAssignmentContext context,
    Future<WorkspaceAssignmentResult> Function(void Function() acquired) start,
    void Function(Duration remaining) onAcquiredRemaining,
  ) async {
    final id = context.assignmentId;
    final allowanceValue = context.payload['queueWaitTimeoutMs'];
    final allowance = allowanceValue is int && allowanceValue > 0
        ? Duration(milliseconds: allowanceValue)
        : defaultAssignmentQueueAllowance;
    final waited = Stopwatch()..start();
    final abandoned = Completer<WorkspaceAssignmentResult>();
    Object? giveUpReason;
    Timer? timer;
    void giveUp(Object reason) {
      if (giveUpReason != null) return;
      giveUpReason = reason;
      timer?.cancel();
      _spaceWaitCancels.remove(id);
      abandoned.completeError(reason);
    }

    _spaceWaitCancels[id] = () => giveUp(const AssignmentExecutionFailure(
          code: 'cancelled',
          message: 'The assignment was cancelled while waiting for its Space.',
        ));
    timer = Timer(
      allowance,
      () => giveUp(AssignmentExecutionFailure(
        code: 'timeout',
        message: 'Another request in this Space was still running, so this '
            'one could not start within ${allowance.inMinutes > 0 ? '${allowance.inMinutes} min' : '${allowance.inSeconds} s'}. '
            'Retry when it finishes.',
        retryable: true,
        localDiagnostic: jsonEncode({
          'schemaVersion': 1,
          'component': 'workspace_service',
          'stage': 'space_wait',
          'errorCode': 'deadline_exceeded',
          'providerStarted': false,
          'queueWaitTimeoutMs': allowance.inMilliseconds,
        }),
      )),
    );
    _startup(context, AssignmentStartupStage.waitingForSpace, {
      'queueWaitTimeoutMs': allowance.inMilliseconds,
    });
    final mutation = start(() {
      final reason = giveUpReason;
      // The wait was abandoned (cancelled or out of allowance) before the
      // lock freed: release it untouched without launching anything.
      if (reason != null) throw reason;
      timer?.cancel();
      _spaceWaitCancels.remove(id);
      final remaining = allowance - waited.elapsed;
      onAcquiredRemaining(remaining < const Duration(milliseconds: 100)
          ? const Duration(milliseconds: 100)
          : remaining);
    });
    try {
      return await Future.any<WorkspaceAssignmentResult>(
          [mutation, abandoned.future]);
    } finally {
      timer.cancel();
      _spaceWaitCancels.remove(id);
    }
  }

  void _startup(
    WorkspaceAssignmentContext context,
    AssignmentStartupStage stage, [
    Map<String, Object?> detail = const {},
  ]) {
    final relay = onStartupStage;
    if (relay == null) return;
    try {
      relay(context, stage, detail);
    } on Object {
      // Observation must never affect assignment execution.
    }
  }

  bool _adoptSpaceFolder(Map<String, Object?> payload) =>
      payload['spaceFolderAdoptionConfirmed'] == true;

  String? _optionalString(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  String _spaceName(Map<String, Object?> payload) {
    final value = payload['spaceName'];
    return value is String && value.trim().isNotEmpty ? value.trim() : 'Space';
  }

  String? _requiredStringForThread(
      Object? value, String field, Object? executionClass) {
    if (value == null && executionClass != 'stateful_thread') return null;
    if (value is! String || value.trim().isEmpty) {
      throw RuntimeViolation(
          'execution assignment field $field is required for Thread CWD');
    }
    return value;
  }

  /// Ends every wait for a Space/Thread and forgets local fencing records.
  /// Part of the user-initiated slot reset; launches nothing and deletes no
  /// Space data.
  Future<void> resetSpaceState() async {
    for (final stopWaiting in _spaceWaitCancels.values.toList()) {
      stopWaiting();
    }
    _spaceWaitCancels.clear();
    await spaceMutationCoordinator?.reset();
  }

  Future<bool> cancel(String assignmentId, String reason) async {
    final stopWaiting = _spaceWaitCancels.remove(assignmentId);
    if (stopWaiting != null) {
      // Still waiting for the Space lock: nothing was launched, so ending the
      // wait is the whole cancellation.
      stopWaiting();
      return true;
    }
    _cancellationRequests.add(assignmentId);
    final cancel = cancelToolProfileAssignment;
    if (cancel == null) return true;
    final cancelled = await cancel(assignmentId);
    if (cancelled) _cancellationRequests.remove(assignmentId);
    return cancelled || _cancellationRequests.contains(assignmentId);
  }

  bool isCancellationRequested(String assignmentId) =>
      _cancellationRequests.contains(assignmentId);

  Map<String, Object?> _withCorrelation(
    Map<String, Object?> payload,
    WorkspaceAssignmentContext context,
  ) =>
      {
        ...payload,
        'syntila': {
          'workspaceId': context.workspaceId,
          'workspaceRuntimeId': context.workspaceRuntimeId,
          'workerId': context.workerId,
          'runId': context.runId,
          'taskId': context.taskId,
          'attemptId': context.attemptId,
          'assignmentId': context.assignmentId,
          'idempotencyKey': context.idempotencyKey,
          if (payload['spaceId'] is String) 'spaceId': payload['spaceId'],
          if (payload['threadId'] is String) 'threadId': payload['threadId'],
          if (payload['workRequestId'] is String)
            'workRequestId': payload['workRequestId'],
          'threadExecutionGuidance': threadExecutionGuidance,
        },
      };
}

typedef WorkerProgressRelay = FutureOr<void> Function(
  WorkspaceAssignmentContext context,
  WorkerProgress progress,
);

typedef WorkerActivityRelay = FutureOr<void> Function(
  WorkspaceAssignmentContext context,
  WorkerActivity activity,
);
