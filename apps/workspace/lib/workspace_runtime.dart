import 'development_tool_profiles.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:syntila_workspace/workspace.dart';
import 'package:syntila_workspace/workspace_configuration.dart';
import 'package:syntila_workspace/assignment_journal.dart';
import 'package:syntila_workspace/platform_runtime.dart';
import 'package:syntila_workspace/allowed_folders.dart';
import 'package:syntila_workspace/cloud_connection.dart';
import 'package:syntila_workspace/assignment_startup.dart';
import 'package:syntila_workspace/input_delivery.dart';
import 'package:syntila_workspace/work_request_input_staging.dart';
import 'package:syntila_workspace/worker_executor.dart';
import 'package:syntila_workspace/worker_launch_plan.dart';
import 'package:syntila_workspace/self_update.dart';
import 'package:syntila_workspace/secure_credentials.dart';
import 'package:syntila_workspace/workspace_registration.dart';
import 'package:syntila_workspace/workspace_transport.dart';
import 'package:syntila_workspace/worker_readiness.dart';
import 'package:syntila_workspace/bundled_cli_worker_engine_loader.dart';
import 'package:syntila_workspace/cli_worker_engine_supervisor.dart';
import 'package:syntila_workspace/worker_diagnostic_store.dart';

String _runtimeFailureDiagnostic(
  String stage,
  String code, {
  String? detail,
  Map<String, Object?> context = const {},
}) =>
    jsonEncode({
      'schemaVersion': 1,
      'component': 'workspace_service',
      'stage': stage,
      'errorCode': code,
      'providerStarted': false,
      ...context,
      if (detail != null) 'detail': detail,
    });

Future<WorkspaceRuntime> buildWorkspaceRuntime(
  WorkspaceConfig config, {
  List<String> restartArgs = const [],
  SecureCredentialStore? credentialStore,
}) async {
  final workerTrustPolicy = workspaceReleaseTrustPolicy();
  final workspacePaths = WorkspacePaths(config.dataDirectory);
  WorkerDiagnosticStore diagnosticStoreForWorkerType(String workerTypeId) =>
      WorkerDiagnosticStore(
        directory: Directory(
          '${workspacePaths.workerStateDirectory(workerTypeId).parent.path}'
          '${Platform.pathSeparator}logs',
        ),
      );
  final secureCredentialStore = credentialStore ??
      PlatformSecureCredentialStore(
        credentialDirectory: Directory(
          '${config.dataDirectory.path}/Credentials',
        ),
      );
  final releaseTrustPolicy = workerTrustPolicy;
  CliWorkerEngineSupervisor? cliWorkerEngineSupervisor;
  final installationId = await InstallationIdentityStore(
    config.dataDirectory,
  ).getOrCreate(initialIdentity: config.installationId);
  final effectiveConfig = config.installationId == installationId
      ? config
      : WorkspaceConfig(
          dataDirectory: config.dataDirectory,
          cloudUri: config.cloudUri,
          workspaceRuntimeId: config.workspaceRuntimeId,
          installationId: installationId,
          workspaceId: config.workspaceId,
          authToken: config.authToken,
          workRootPath: config.workRootPath,
          serviceEnabled: config.serviceEnabled,
          connectOnStart: config.connectOnStart,
          legacyParallelSlots: config.legacyParallelSlots,
          folders: config.folders,
          settingsFile: config.settingsFile,
        );
  final localWorkspaceId = await LocalWorkspaceIdentityStore(
    effectiveConfig.dataDirectory,
  ).getOrCreate(initialIdentity: effectiveConfig.workspaceId);
  WorkspaceCloudConnection? connection;
  late final WorkerCatalogCoordinator? workerCatalogCoordinator;
  late final WorkspaceWorkerSubsystem workerSubsystem;
  final localWorkerRegistry = LocalWorkerRegistry(
    dataDirectory: effectiveConfig.dataDirectory,
    workspaceId: localWorkspaceId,
    onChanged: () async {
      await workerCatalogCoordinator?.refreshLocalWorkers();
      await connection?.refreshWorkerInventory();
    },
    onWorkerRemoving: (workerId) async {
      await cliWorkerEngineSupervisor?.cancelWorker(workerId);
    },
  );
  // Report a pre-Cloud local value once so Cloud can adopt it for a
  // Workspace that has no slot total yet. Cloud never lets it override.
  final legacySlots = effectiveConfig.legacyParallelSlots;
  if (legacySlots != null) {
    await localWorkerRegistry.setParallelSlots(legacySlots);
  }
  const developmentDraftRoot = String.fromEnvironment(
    'SYNTILA_DEVELOPMENT_PROFILE_DIRECTORY',
  );
  DevelopmentToolProfiles? developmentProfiles;
  if (developmentDraftRoot.isNotEmpty) {
    final cloudUri = effectiveConfig.cloudUri;
    if (cloudUri == null) {
      throw StateError(
        'Unsigned development Profiles require a loopback Cloud connection',
      );
    }
    developmentProfiles = DevelopmentToolProfiles(
      draftsRoot: Directory(developmentDraftRoot),
      snapshotsRoot: Directory(
        '${config.dataDirectory.absolute.path}/development_profiles',
      ),
      cloudUri: cloudUri,
      releaseBuild: const bool.fromEnvironment('dart.vm.product'),
    );
  }
  final toolProfileReleaseStore = WorkerProfileStore(
    profilesRoot: WorkspacePaths(config.dataDirectory).profilesDirectory,
    trustPolicy: workerTrustPolicy,
    developmentProfiles: developmentProfiles,
  );
  final launchPlans = WorkerLaunchPlanCache(
    store: toolProfileReleaseStore,
    engineVersion: cliWorkerEngineVersion,
  );
  final bundledEngine = await loadBundledCliWorkerEngine(
    enginesDirectory: workspacePaths.enginesDirectory,
  );
  cliWorkerEngineSupervisor = bundledEngine == null
      ? null
      : CliWorkerEngineSupervisor(
          engineExecutable: bundledEngine.path,
          processRegistryDirectory: workspacePaths.runtimeDirectory,
        );
  late final WorkerReadinessMonitor readinessMonitor;
  final toolProfileCatalog = config.cloudUri == null
      ? null
      : ToolProfileCatalogClient(
          cloudUri: config.cloudUri!,
          store: toolProfileReleaseStore,
          trustPolicy: workerTrustPolicy,
          workspaceRuntimeId: config.workspaceRuntimeId,
          authToken: config.authToken,
          candidateValidator: (candidate, profileFile) async {
            final supervisor = cliWorkerEngineSupervisor;
            if (supervisor == null) return false;
            final workers = (await localWorkerRegistry.list())
                .where(
                  (worker) =>
                      worker.workerTypeId == candidate.logicalWorkerTypeId,
                )
                .toList();
            if (workers.isEmpty) return false;
            final worker = workers.first;
            final result = await supervisor.probe(
              candidate,
              profileFile: profileFile,
              stateDirectory: workspacePaths.workerStateDirectory(worker.id),
              mode: WorkerProbeMode.passive,
              timeout: const Duration(seconds: 20),
            );
            if (!result.ready) {
              throw WorkerProfileProbeFailure(
                result.issueCode ?? 'provider_failure',
              );
            }
            return true;
          },
          onRevocationsApplied: (workerTypeIds) async {
            for (final workerTypeId in workerTypeIds) {
              unawaited(
                readinessMonitor
                    .checkNow(
                      mode: LocalWorkerProbeMode.passive,
                      workerTypeId: workerTypeId,
                      includeDisabled: true,
                    )
                    .catchError((_) {}),
              );
            }
          },
        );
  if (toolProfileCatalog != null) {
    workerCatalogCoordinator = WorkerCatalogCoordinator(
      catalog: toolProfileCatalog,
      releaseStore: toolProfileReleaseStore,
      registry: localWorkerRegistry,
      onCatalogReconciled: () async {
        await connection?.refreshWorkerInventory();
      },
      refreshReadiness: () => readinessMonitor
          .checkNow(
            mode: LocalWorkerProbeMode.passive,
            rerunWhenActive: true,
            includeDisabled: true,
          )
          .then((_) => connection?.refreshWorkerInventory()),
    );
  } else {
    workerCatalogCoordinator = null;
  }
  // Prepare each enabled Worker's launch plan ahead of any assignment, at
  // startup and whenever the catalog or a Profile resolution changes. The
  // cache validates itself against the store, so a repeated warm is cheap.
  var warmingLaunchPlans = false;
  Future<void> warmLaunchPlans() async {
    final coordinator = workerCatalogCoordinator;
    if (coordinator == null || warmingLaunchPlans) return;
    warmingLaunchPlans = true;
    try {
      for (final worker in await localWorkerRegistry.list()) {
        if (worker.activationState != LocalWorkerActivationState.enabled) {
          continue;
        }
        final descriptor = coordinator.entryForWorker(worker.workerTypeId);
        if (descriptor == null) continue;
        await launchPlans.warm(
          workerTypeId: worker.workerTypeId,
          profileDefinitionId: descriptor.profileDefinitionId,
          providerCliVersion: worker.toolVersion,
        );
      }
    } on Object {
      // Warming is best effort; the hot path reports real problems.
    } finally {
      warmingLaunchPlans = false;
    }
  }

  workerCatalogCoordinator?.addListener(() => unawaited(warmLaunchPlans()));
  unawaited(warmLaunchPlans());
  List<String> activeWorkerIds;
  try {
    activeWorkerIds = (await localWorkerRegistry.list())
        .where((worker) => worker.status == LocalWorkerStatus.ready)
        .map((worker) => worker.id)
        .toList();
  } on Object catch (error) {
    stderr.writeln(
      'Workspace local Worker registry unavailable at startup: $error',
    );
    activeWorkerIds = const <String>[];
  }
  final workRoot = await config.workRootResolver.resolve();
  workspacePaths.validateWorkRootSeparation(workRoot);
  final spaceDirectoryLifecycle = SpaceDirectoryLifecycle(
    SpaceDirectoryResolver(
      workRoot: workRoot,
      registryDirectory: workspacePaths.spaceDirectoryRegistryDirectory,
    ),
  );
  final allowedFolders = AllowedFolderRegistry(
    registryDirectory: workspacePaths.spaceDirectoryRegistryDirectory,
    workRoot: workRoot,
    applicationDataRoot: workspacePaths.applicationDataRoot,
    homeDirectory: currentPlatformRuntime.homeDirectory,
  );
  final inputStaging = WorkRequestInputStaging(
    Directory(
      '${workspacePaths.applicationSupportDirectory.path}${Platform.pathSeparator}staged-inputs',
    ),
  );
  final inputCloudUri = config.cloudUri;
  final inputRuntimeId = config.workspaceRuntimeId;
  final inputToken = config.authToken;
  final inputDelivery = inputCloudUri == null ||
          inputRuntimeId == null ||
          inputRuntimeId.isEmpty ||
          inputToken == null ||
          inputToken.isEmpty
      ? null
      : InputDeliveryAgent(
          cloud: HttpInputDeliveryCloud(
            cloudUri: inputCloudUri,
            workspaceRuntimeId: inputRuntimeId,
            authToken: inputToken,
          ),
          staging: inputStaging,
          pushConnected: () => connection?.isConnected ?? false,
        );
  late final WorkerAssignmentHandler workerHandler;
  workerHandler = WorkerAssignmentHandler(
    resolveLogicalWorker: (workerId) async {
      final worker = await localWorkerRegistry.find(workerId);
      if (worker == null) {
        return null;
      }
      // The assignment hot path never waits for the network. The locally known
      // catalog entry decides eligibility; when it is unknown because the
      // catalog has never synchronized, the assignment fails promptly with a
      // specific reason and a background refresh repairs the next attempt.
      final catalogCoordinator = workerCatalogCoordinator;
      final catalogEntry = catalogCoordinator?.entryForWorker(
        worker.workerTypeId,
      );
      final catalogAvailable =
          catalogCoordinator == null || catalogEntry != null;
      final catalogConfirmed =
          catalogCoordinator?.snapshot.catalogConfirmed ?? true;
      if (!catalogAvailable && !catalogConfirmed) {
        unawaited(catalogCoordinator.refresh().catchError((_) {}));
      }
      return AssignmentLogicalWorker(
        id: worker.id,
        workerTypeId: worker.workerTypeId,
        enabled: catalogAvailable &&
            worker.activationState == LocalWorkerActivationState.enabled,
        ready: catalogAvailable && worker.status == LocalWorkerStatus.ready,
        permissions: worker.localPermissions.toSet(),
        localConcurrencyLimit: worker.localConcurrencyLimit,
        fullLocalAccessAuthorized: worker.fullLocalAccessAuthorized,
        providerCliVersion: worker.toolVersion,
        notReadyReason: catalogAvailable
            ? null
            : catalogConfirmed
                ? 'worker_type_not_in_catalog'
                : 'catalog_not_synchronized',
      );
    },
    resolveLaunchPlan: (worker) async {
      final coordinator = workerCatalogCoordinator;
      final descriptor = coordinator?.entryForWorker(worker.workerTypeId);
      if (descriptor == null) {
        throw AssignmentExecutionFailure(
          code: 'worker_not_ready',
          message: executionErrorMessage('worker_not_ready'),
          localDiagnostic: _runtimeFailureDiagnostic(
            'profile_resolution',
            'worker_not_ready',
            detail: 'The Worker type is not in the local catalog',
            context: {'reason': 'catalog_entry_missing'},
          ),
        );
      }
      final result = await launchPlans.resolve(
        workerTypeId: worker.workerTypeId,
        profileDefinitionId: descriptor.profileDefinitionId,
        providerCliVersion: worker.providerCliVersion,
      );
      final plan = result.plan;
      if (plan != null) return plan;
      // Nothing is fetched here. Repair the local Profile in the background
      // so the next assignment can start, and fail this one promptly.
      if (coordinator != null &&
          result.unavailable == WorkerLaunchUnavailable.noProfile) {
        unawaited(
          coordinator
              .ensureWorkerProfileAvailable(worker.workerTypeId)
              .catchError((_) {}),
        );
      }
      const code = 'worker_not_ready';
      throw AssignmentExecutionFailure(
        code: code,
        message: executionErrorMessage(code),
        localDiagnostic: _runtimeFailureDiagnostic(
          'profile_resolution',
          code,
          detail: 'No compatible launch plan was available locally',
          context: {'reason': result.unavailable!.name},
        ),
      );
    },
    defaultWorkingDirectory: workRoot,
    applicationStateDirectory: workspacePaths.applicationSupportDirectory,
    inputStaging: inputStaging,
    fetchInput: inputDelivery?.ensure,
    spaceDirectoryLifecycle: spaceDirectoryLifecycle,
    onActivity: (context, activity) async {
      await connection?.reportWorkerActivity(context, activity);
    },
    onStartupStage: (context, stage, detail) => connection
        ?.traceAssignmentStage(context, stage.wireName, extra: detail),
    onExecutionStarted: (context) async {
      await connection?.reportWorkerStarted(context);
    },
    onExecutionSlotReserved: (context) async {
      // Stamp T8 first (synchronous); the awaited diagnostic below is the
      // pre-existing write that precedes Engine spawn and is measured as-is.
      connection?.traceAssignmentStage(context, 'slot_reserved');
      await connection?.recordAssignmentDiagnostic(
        context,
        event: 'assignment.slot_reserved',
        stage: 'slot_reservation',
      );
    },
    authorizeExecutionStart: (context) async =>
        await connection?.requestStartPermit(context) ?? true,
    onEngineProcessStarted: (context) =>
        connection?.traceAssignmentStage(context, 'engine_process_created'),
    cancelToolProfileAssignment: cliWorkerEngineSupervisor?.cancel,
    executeWithActivity: (
      worker,
      workingDirectory,
      context,
      payload, {
      onProgress,
      onSlotReserved,
      authorizeStart,
      onEngineProcessStarted,
      onActivity,
    }) async {
      final supervisor = cliWorkerEngineSupervisor;
      final coordinator = workerCatalogCoordinator;
      if (coordinator == null || supervisor == null) {
        throw AssignmentExecutionFailure(
          code: 'worker_not_ready',
          message: executionErrorMessage('worker_not_ready'),
          localDiagnostic: _runtimeFailureDiagnostic(
            'profile_resolution',
            'worker_not_ready',
            detail: 'Tool Profile Engine is unavailable',
          ),
        );
      }
      // Use the plan pinned at admission so a Profile activated while this
      // assignment waited cannot change what it launches. A direct caller
      // without a pinned plan resolves from the local cache; no network.
      Future<WorkerLaunchPlan> unpinnedPlan() async {
        final descriptor = coordinator.entryForWorker(worker.workerTypeId);
        final prepared = descriptor == null
            ? null
            : await launchPlans.resolve(
                workerTypeId: worker.workerTypeId,
                profileDefinitionId: descriptor.profileDefinitionId,
                providerCliVersion: worker.providerCliVersion,
              );
        final prepare = prepared?.plan;
        if (prepare != null) return prepare;
        const code = 'worker_not_ready';
        throw AssignmentExecutionFailure(
          code: code,
          message: executionErrorMessage(code),
          localDiagnostic: _runtimeFailureDiagnostic(
            'profile_resolution',
            code,
            detail: 'No admitted Tool Profile release was available',
          ),
        );
      }

      final plan = workerHandler.pinnedLaunchPlan(context.assignmentId) ??
          await unpinnedPlan();
      final release = plan.release;
      final workerSessionValue = payload['workerSession'];
      final workerSession = workerSessionValue == null
          ? null
          : WorkerSessionContext.fromJson(
              Map<String, Object?>.from(workerSessionValue as Map),
            );
      final input = payload['input'];
      final modelValue =
          payload['model'] ?? (input is Map ? input['model'] : null);
      final reasoningEffortValue = payload['reasoningEffort'] ??
          (input is Map ? input['reasoningEffort'] : null);
      final sessionPolicyValue = payload['sessionPolicy'] ??
          (input is Map ? input['sessionPolicy'] : null) ??
          'stateless';
      final sessionKeyValue =
          payload['sessionKey'] ?? (input is Map ? input['sessionKey'] : null);
      if (!const {
            'stateless',
            'durable_session',
          }.contains(sessionPolicyValue) ||
          (sessionPolicyValue == 'durable_session') !=
              (sessionKeyValue is String)) {
        throw AssignmentExecutionFailure(
          code: 'execution_failed',
          message: executionErrorMessage('execution_failed'),
          localDiagnostic: _runtimeFailureDiagnostic(
            'assignment_payload_validation',
            'execution_failed',
            detail: 'Session policy and logical session key did not match',
            context: {
              'sessionPolicy': sessionPolicyValue.toString(),
              'hasSessionKey': sessionKeyValue is String,
              'hasWorkerSession': workerSession != null,
            },
          ),
        );
      }
      final prompt = input is Map && input['prompt'] is String
          ? input['prompt'] as String
          : payload['prompt'] is String
              ? payload['prompt'] as String
              : jsonEncode(payload);
      final timeoutValue = payload['timeoutMs'];
      if (timeoutValue is! int || timeoutValue < 1) {
        throw AssignmentExecutionFailure(
          code: 'execution_failed',
          message: executionErrorMessage('execution_failed'),
          localDiagnostic: _runtimeFailureDiagnostic(
            'assignment_payload_validation',
            'execution_failed',
            detail:
                'Assignment timeout was missing or outside the allowed range',
          ),
        );
      }
      final queueWaitTimeoutValue = payload['queueWaitTimeoutMs'];
      final queueWaitTimeout = queueWaitTimeoutValue is int
          ? Duration(milliseconds: queueWaitTimeoutValue)
          : CliWorkerEngineSupervisor.defaultQueueWaitTimeout;
      // Parallel slots are one Workspace-wide pool owned by Cloud. Cloud
      // admits each assignment against that total and stamps the current
      // value into the assignment, so this limit never makes work wait here.
      // An older Cloud omits it; the local Worker record is the fallback.
      final cloudSlots = payload['maxConcurrentAssignments'];
      final effectiveConcurrency =
          cloudSlots is int ? cloudSlots : worker.localConcurrencyLimit;
      if (effectiveConcurrency < 1) {
        throw AssignmentExecutionFailure(
          code: 'worker_not_ready',
          message: executionErrorMessage('worker_not_ready'),
          localDiagnostic: _runtimeFailureDiagnostic(
            'assignment_capacity',
            'worker_not_ready',
            detail: 'The effective Cloud and local Worker capacity was invalid',
          ),
        );
      }
      // Additional folders: IDs from Cloud become local paths only here, after
      // a fresh access check. A Profile that cannot pass them fails clearly
      // instead of running without the folders.
      List<String> additionalDirectories = const [];
      try {
        final folderIds = assignmentAdditionalFolderIds(payload);
        if (folderIds.isNotEmpty) {
          if (!profileSupportsAdditionalDirectories(release.profile)) {
            throw const AllowedFolderViolation(
              'profile_unsupported',
              'This Worker cannot use additional folders yet. Detach the '
                  "Space's additional folders or choose another Worker.",
            );
          }
          additionalDirectories = await allowedFolders.resolveForExecution(
            folderIds,
          );
        }
      } on AllowedFolderViolation catch (error) {
        throw AssignmentExecutionFailure(
          code: 'worker_not_ready',
          message: error.message,
          localDiagnostic: _runtimeFailureDiagnostic(
            'additional_folders',
            'worker_not_ready',
            detail: error.code,
          ),
        );
      }
      final profileFile = plan.profileFile;
      // T7: Profile resolved and its execution file located.
      connection?.traceAssignmentStage(context, 'profile_resolved');
      try {
        if (workerHandler.isCancellationRequested(context.assignmentId)) {
          throw const AssignmentExecutionFailure(
            code: 'cancelled',
            message: 'The assignment was cancelled before Engine launch.',
          );
        }
        return await supervisor.execute(
          release,
          profileFile: profileFile,
          stateDirectory: workspacePaths.workerStateDirectory(worker.id),
          workingDirectory: workingDirectory,
          workerId: worker.id,
          maxConcurrentAssignments: effectiveConcurrency,
          assignmentId: context.assignmentId,
          attemptId: context.attemptId,
          executionId: context.executionId,
          prompt: prompt,
          timeout: Duration(milliseconds: timeoutValue),
          queueWaitTimeout: queueWaitTimeout,
          sessionPolicy: sessionPolicyValue == 'durable_session'
              ? WorkerSessionPolicy.durableSession
              : WorkerSessionPolicy.stateless,
          sessionKey: sessionKeyValue as String?,
          workerSession: workerSession,
          statelessContext: payload["statelessContext"] == null
              ? null
              : ConversationBootstrap.fromJson(
                  Map<String, Object?>.from(
                    payload["statelessContext"] as Map,
                  ),
                ),
          model: modelValue is String && modelValue.trim().isNotEmpty
              ? modelValue.trim()
              : null,
          reasoningEffort: reasoningEffortValue is String &&
                  reasoningEffortValue.trim().isNotEmpty
              ? reasoningEffortValue.trim()
              : null,
          // Static capability identity is bound by the admitted Worker Profile;
          // only Service-owned provider catalogs have an Engine catalog pin.
          catalogRevision:
              (release.profile['model'] as Map?)?['discovery'] == null
                  ? null
                  : (payload['executionSelection'] as Map?)?['catalogRevision']
                      as String?,
          executionPolicy: assignmentExecutionPolicy(
            context.payload,
            fullAccessAuthorized: worker.fullLocalAccessAuthorized,
          ),
          additionalDirectories: additionalDirectories,
          // The user chose to compact the Worker session after a context
          // overflow; Cloud sends this only for a durable-session retry.
          compactContext: payload['contextCompaction'] == true &&
              sessionPolicyValue == 'durable_session',
          onProgress: onProgress,
          onSlotReserved: onSlotReserved,
          authorizeStart: authorizeStart,
          onProcessStarted: onEngineProcessStarted,
          onQueued: (queue) => connection?.traceAssignmentStage(
            context,
            AssignmentStartupStage.queuedForSlot.wireName,
            extra: {
              'queuePosition': queue.position,
              'activeAssignments': queue.active,
              'slotLimit': queue.limit,
              'waitingForSession': queue.waitingForSession,
              'queueWaitTimeoutMs': queue.queueWaitTimeout.inMilliseconds,
            },
          ),
          onInitialized: () => connection?.traceAssignmentStage(
            context,
            AssignmentStartupStage.engineInitialized.wireName,
          ),
          onActivity: onActivity,
        );
      } finally {
        // The service republishes bounded Engine metadata after execution;
        // no additional readiness/model request is necessary.
        if ((release.profile['model'] as Map?)?['discovery'] != null) {
          try {
            final file = File(
              '${workspacePaths.workerStateDirectory(worker.id).path}/model-catalog.json',
            );
            if (await file.length() > 128 * 1024) {
              throw const FormatException('Catalog exceeds limit');
            }
            final catalog = DiscoveredModelCatalog.fromJson(
              Map<String, Object?>.from(
                jsonDecode(await file.readAsString()) as Map,
              ),
            );
            final currentDescriptor = coordinator.entryForWorker(
              worker.workerTypeId,
            );
            final currentResolution = currentDescriptor == null
                ? null
                : await launchPlans.resolve(
                    workerTypeId: worker.workerTypeId,
                    profileDefinitionId: currentDescriptor.profileDefinitionId,
                    providerCliVersion: catalog.providerToolVersion,
                  );
            if (catalog.profileDigest == release.payloadDigest &&
                currentResolution?.plan?.profileDigest ==
                    catalog.profileDigest) {
              await localWorkerRegistry.update(
                worker.id,
                (current) => current.toolVersion != null &&
                        current.toolVersion != catalog.providerToolVersion
                    ? current
                    : current.copyWith(
                        modelCatalog: catalog.withStale(
                          catalog.stale || current.modelCatalog?.stale == true,
                        ),
                      ),
              );
            }
          } on Object {
            // A catalog/cache failure must not replace the assignment outcome.
          }
        }
      }
    },
  );
  WorkspaceUpdateController? updateController;
  String? updateAvailable;
  var lastUpdateCheck = DateTime.fromMillisecondsSinceEpoch(0);
  const packageManager = String.fromEnvironment(
    'SYNTILA_WORKSPACE_PACKAGE_MANAGER',
  );
  if (config.cloudUri != null && packageManager != 'apt') {
    updateController = WorkspaceUpdateController(
      cloudUri: config.cloudUri!,
      currentVersion: syntilaWorkspaceAppVersion,
      client: const WorkspaceReleaseClient(),
      updater: WorkspaceUpdater(
        WorkspacePaths(config.dataDirectory).updatesDirectory,
        trustPolicy: releaseTrustPolicy,
      ),
      operatingSystem: Platform.operatingSystem,
      authToken: config.authToken,
    );
  }
  Future<void> refreshUpdateAvailability() async {
    if (updateController == null ||
        DateTime.now().difference(lastUpdateCheck) <
            const Duration(minutes: 5)) {
      return;
    }
    lastUpdateCheck = DateTime.now();
    try {
      final release = await updateController.check();
      updateAvailable = release?.version;
    } on Object {
      // Status remains useful while Cloud is offline; the next interval
      // retries the check.
    }
  }

  connection = config.cloudUri != null &&
          config.workspaceRuntimeId != null &&
          config.workspaceId != null
      ? WorkspaceCloudConnection(
          uri: config.cloudUri!,
          workspaceRuntimeId: config.workspaceRuntimeId!,
          workspaceId: config.workspaceId!,
          credentialAvailable: config.authToken?.isNotEmpty == true,
          activeWorkerIds: activeWorkerIds,
          assignmentHandler: (context) => workerSubsystem.execute(context),
          assignmentCancellationHandler: (assignmentId, reason) =>
              workerSubsystem.cancel(assignmentId, reason),
          diagnosticStoreForWorkerType: diagnosticStoreForWorkerType,
          localQueueLengthProvider: () =>
              cliWorkerEngineSupervisor?.queuedAssignmentCount ?? 0,
          deadAssignmentIdsProvider: cliWorkerEngineSupervisor == null
              ? null
              : () =>
                  cliWorkerEngineSupervisor?.deadAssignmentIds ??
                  const <String>{},
          workerInventoryProvider: () async {
            final localWorkers = await localWorkerRegistry.list();
            return workerCatalogCoordinator?.inventoryForWorkers(
                  localWorkers,
                  engineVersion: cliWorkerEngineVersion,
                  engineAvailable: cliWorkerEngineSupervisor != null,
                ) ??
                const <Map<String, Object?>>[];
          },
          allowedFolderProvider: () async => [
            for (final folder in await allowedFolders.list())
              folder.toCloudSummary(),
          ],
          inputAvailableHandler: inputDelivery?.wake,
          workerUsageProvider: (workerId) async {
            final supervisor = cliWorkerEngineSupervisor;
            final worker = await localWorkerRegistry.find(workerId);
            final descriptor = worker == null
                ? null
                : workerCatalogCoordinator?.entryForWorker(worker.workerTypeId);
            if (supervisor == null || worker == null || descriptor == null) {
              return const {
                'status': 'error',
                'errorCode': 'worker_not_ready',
                'errorMessage':
                    'The Worker is not available on this Workspace.',
              };
            }
            final plan = (await launchPlans.resolve(
              workerTypeId: worker.workerTypeId,
              profileDefinitionId: descriptor.profileDefinitionId,
              providerCliVersion: worker.toolVersion,
            ))
                .plan;
            if (plan == null) {
              return const {
                'status': 'error',
                'errorCode': 'worker_not_ready',
                'errorMessage': 'The Worker Profile is not ready.',
              };
            }
            // The Profile owns whether and how usage is read.
            if (plan.release.profile['usage'] == null) {
              return const {
                'status': 'unavailable',
                'errorCode': 'usage_not_configured',
                'errorMessage': 'This Worker Profile has no usage command.',
              };
            }
            try {
              final usage = await supervisor.usage(
                plan.release,
                profileFile: plan.profileFile,
                stateDirectory: workspacePaths.workerStateDirectory(worker.id),
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
            }
          },
          onSessionReady: () async {
            inputDelivery?.start();
            await workerCatalogCoordinator?.refresh(force: true);
          },
          onKnownSpaces: (spaceIds) async {
            await spaceDirectoryLifecycle.forgetSpacesExcept(spaceIds);
          },
          workspaceUpdateAvailableHandler: (payload) async {
            final controller = updateController;
            if (controller == null) return;
            final release = controller.acceptAvailable(payload);
            updateAvailable = release.version;
          },
          assignmentJournal: AssignmentJournal(
            File('${config.dataDirectory.path}/assignments.jsonl'),
          ),
          factory: (uri) => connectWebSocketWorkspaceTransport(
            uri,
            authToken: config.authToken,
          ),
          fallbackFactory: (uri) {
            final gatewayPath = uri.path.indexOf('/api/workspace-gateway');
            final basePath =
                gatewayPath < 0 ? '' : uri.path.substring(0, gatewayPath);
            final baseUri = uri.replace(
              scheme: uri.scheme == 'wss' ? 'https' : 'http',
              path: basePath,
              query: null,
              fragment: null,
            );
            return HttpLongPollWorkspaceTransport.connect(
              baseUri: baseUri,
              workspaceRuntimeId: config.workspaceRuntimeId!,
              runtimeCredential: config.authToken!,
            );
          },
        )
      : null;
  readinessMonitor = WorkerReadinessMonitor(
    registry: localWorkerRegistry,
    toolProfileReleaseStore: toolProfileReleaseStore,
    workerCatalogCoordinator: workerCatalogCoordinator,
    cliWorkerEngineSupervisor: cliWorkerEngineSupervisor,
    workerStateDirectory: workspacePaths.workerStateDirectory,
    profileDiagnosticStoreForWorker: diagnosticStoreForWorkerType,
  );
  workerSubsystem = WorkspaceWorkerSubsystem(
    registry: localWorkerRegistry,
    releaseStore: toolProfileReleaseStore,
    catalog: workerCatalogCoordinator,
    readiness: readinessMonitor,
    engineSupervisor: cliWorkerEngineSupervisor,
    assignmentHandler: workerHandler,
    workerStateDirectory: workspacePaths.workerStateDirectory,
    onRemovalChanged: () => unawaited(
      workerCatalogCoordinator?.refreshLocalWorkers() ?? Future.value(),
    ),
  );
  final engine = WorkspaceRuntime(
    config: effectiveConfig,
    credentialStore: secureCredentialStore,
    localWorkerRegistry: localWorkerRegistry,
    workerReadinessMonitor: readinessMonitor,
    workerSubsystem: workerSubsystem,
    workerShutdownHandler: () async {
      await workerSubsystem.shutdown();
    },
    workerRecoveryHandler: () async =>
        await workerSubsystem.recoverOrphanedProcesses(),
    cloudConnection: connection,
    toolProfileReleaseStore: toolProfileReleaseStore,
    toolProfileCatalog: toolProfileCatalog,
    workerCatalogCoordinator: workerCatalogCoordinator,
    statusProvider: () async {
      await refreshUpdateAvailability();
      final workers = await localWorkerRegistry.list();
      return {
        'appVersion': syntilaWorkspaceAppVersion,
        'workers': workers.length,
        'workerIds': workers.map((worker) => worker.id).toList(),
        'activeTasks': connection?.activeAssignmentCount ?? 0,
        'activeAssignmentIds': connection?.activeAssignmentIds ?? const [],
        'cloudConnected': connection?.isConnected ?? false,
        'lastUpdateCheckAt': lastUpdateCheck.toUtc().toIso8601String(),
        'lastUpdateCheckStatus':
            updateController?.status.phase ?? 'unconfigured',
        if (updateAvailable != null) 'updateAvailable': updateAvailable,
      };
    },
    updateStatusProvider: () async =>
        updateController?.status.toJson() ??
        (packageManager == 'apt'
            ? const {'phase': 'managed', 'packageManager': 'apt'}
            : const {'phase': 'unconfigured'}),
    updateHandler: (request) async {
      final controller = updateController;
      if (controller == null) {
        throw StateError(
          packageManager == 'apt'
              ? 'Update this installation using apt, then restart the user service.'
              : 'Workspace updates are not configured',
        );
      }
      final action = request['action'] as String? ?? 'status';
      if (action == 'check') {
        final release = await controller.check();
        updateAvailable = release?.version;
      } else if (action == 'apply') {
        await controller.apply(
          hasActiveAssignments: () async =>
              (connection?.activeAssignmentCount ?? 0) > 0,
          healthCheck: (executable) async =>
              await executable.exists() && await executable.length() > 0,
          restartBootstrap: (executable) async {
            try {
              await Process.start(
                executable.path,
                restartArgs,
                mode: ProcessStartMode.detachedWithStdio,
              );
              // Allow the IPC response to flush and release the engine lock
              // before the replacement process starts using the same data
              // directory.
              unawaited(
                Future<void>.delayed(
                  const Duration(milliseconds: 150),
                  () => exit(0),
                ),
              );
              return true;
            } on Object {
              return false;
            }
          },
        );
        updateAvailable = controller.availableRelease?.version;
      } else if (action != 'status') {
        throw StateError('unsupported Workspace update action: $action');
      }
      return controller.status.toJson();
    },
  );
  return engine;
}
