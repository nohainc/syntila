import 'external_worker_executor.dart' show isExternalWorkerType;
import 'workspace_manager_mcp.dart';
import 'workspace_manager_external_workers.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'allowed_folders.dart';
import 'assignment_journal.dart';
import 'cloud_connection.dart';
import 'diagnostics.dart';
import 'local_worker_permissions.dart';
import 'platform_runtime.dart';
import 'work_root.dart';
import 'workspace.dart';
import 'workspace_headless_auth.dart';
import 'workspace_configuration.dart';
import 'workspace_lifecycle.dart';
import 'workspace_manager_ipc.dart';
import 'local_worker_setup.dart';
import 'workspace_registration.dart';
import 'workspace_registration_models.dart';
import 'workspace_service_state.dart';
import 'workspace_settings.dart';
import 'worker_readiness.dart';
import 'worker_check_progress.dart';
import 'worker_diagnostic_store.dart';

/// Runtime command boundary and event publisher for the local management UI.
class WorkspaceManagerService {
  static const _workerReadinessCommandTimeout = Duration(seconds: 40);

  WorkspaceManagerService(WorkspaceRuntime workspace, {this.reloadRuntime})
      : _workspace = workspace,
        _desiredCloudState = workspace.config.connectOnStart
            ? DesiredCloudConnectionState.connected
            : DesiredCloudConnectionState.disconnected;

  WorkspaceRuntime _workspace;
  DesiredCloudConnectionState _desiredCloudState;
  WorkspaceRuntime get workspace => _workspace;
  final Future<WorkspaceRuntime> Function()? reloadRuntime;
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  WorkspaceManagerIpcServer? _server;
  Future<void>? _snapshotInFlight;
  bool _snapshotDirty = false;
  Map<String, Object?>? _previousSnapshot;
  bool _closed = false;
  WorkspaceHeadlessAuth? _headlessAuth;
  WorkspaceCloudConnection? _observedConnection;
  WorkerCatalogCoordinator? _observedCatalog;
  WorkerReadinessMonitor? _observedReadiness;
  AllowedFolderRegistry? _allowedFolderRegistry;
  WorkspaceExternalWorkerCommands? _externalWorkerCommands;
  WorkspaceMcpCommands? _mcpCommands;

  Future<void> start() async {
    final paths = WorkspacePaths(workspace.config.dataDirectory);
    _server = WorkspaceManagerIpcServer(
      runtimeDirectory: paths.runtimeDirectory,
      serviceVersion: syntilaWorkspaceAppVersion,
      snapshotProvider: snapshot,
      requestHandler: _dispatchAndPublish,
      eventStream: _events.stream,
    );
    await _server!.start();
    _bindWorkspaceEvents(workspace);
    _previousSnapshot = await snapshot();
  }

  void _bindWorkspaceEvents(WorkspaceRuntime target) {
    final oldConnection = _observedConnection;
    if (oldConnection != null) oldConnection.onStateChanged = null;
    _observedCatalog?.removeListener(_handleWorkspaceChange);
    _observedReadiness?.removeListener(_handleWorkspaceChange);
    final connection = target.cloudConnection;
    _observedConnection = connection;
    if (connection != null) connection.onStateChanged = _handleWorkspaceChange;
    _observedCatalog = target.workerCatalogCoordinator;
    _observedCatalog?.addListener(_handleWorkspaceChange);
    _observedReadiness = target.workerReadinessMonitor;
    _observedReadiness?.addListener(_handleWorkspaceChange);
  }

  void _handleWorkspaceChange() => unawaited(_publishSnapshot());

  Future<Object?> _dispatchAndPublish(
    String command,
    Map<String, Object?> payload,
  ) async {
    final result = await _dispatch(command, payload);
    if (command.startsWith('folders.') && command != 'folders.list') {
      _publishAllowedFolders();
    }
    await _publishSnapshot();
    return result;
  }

  Future<Map<String, Object?>> snapshot() async {
    final connection = workspace.cloudConnection;
    final workers = await (workspace.workerSubsystem?.listWorkers() ??
        workspace.localWorkerRegistry?.list() ??
        Future.value(const <LocalWorker>[]));
    final registration = WorkspaceRegistrationStore(
      workspace.config.dataDirectory,
    ).readSync();
    final stateFile = File(
      '${workspace.config.dataDirectory.path}/workspace-state.json',
    );
    Map<String, Object?> state = const {};
    if (await stateFile.exists()) {
      try {
        final decoded = jsonDecode(await stateFile.readAsString());
        if (decoded is Map) state = Map<String, Object?>.from(decoded);
      } on Object {
        state = const {};
      }
    }
    final activeIds = connection?.activeAssignmentIds ?? const <String>[];
    final processRunning = workspace.isRunning;
    final connectionStage = connection?.connectionStage;
    final authenticated = connectionStage == WorkspaceConnectionStage.ready ||
        connectionStage == WorkspaceConnectionStage.synchronizing ||
        connectionStage == WorkspaceConnectionStage.switchingToWebSocket;
    final synchronized = connection?.lastInventorySyncAt != null;
    final cloudLifecycleState = _cloudLifecycleState(connection);
    final lifecycle = WorkspaceServiceLifecycle(
      // Host registration is intentionally owned by WorkspaceServiceManager;
      // the headless process cannot infer it when launched directly.
      installation: ServiceInstallationState.unknown,
      runtime: processRunning
          ? ServiceRuntimeState.running
          : ServiceRuntimeState.stopped,
      cloud: cloudLifecycleState,
      ipcReady: true,
      startedAt: DateTime.tryParse(state['startedAt']?.toString() ?? ''),
      lastError: state['failure']?.toString(),
    );
    final journalRecords =
        await connection?.assignmentJournal?.reconcile() ?? const {};
    final recoveryRequired = journalRecords.values
        .where((record) => record.status == AssignmentStatus.interrupted)
        .map(
          (record) => {
            'assignmentId': record.assignmentId,
            'state': record.result?['recoveryState'] ?? 'outcome_unknown',
            'workerId': record.workerId,
            'updatedAt': record.updatedAt.toIso8601String(),
          },
        )
        .toList()
      ..sort(
        (left, right) => (left['assignmentId']! as String).compareTo(
          right['assignmentId']! as String,
        ),
      );
    return {
      'service': {
        // A service snapshot only exists after the process has been launched;
        // host registration remains authoritative in WorkspaceServiceInfo.
        'registered': processRunning,
        'processState': state['processState'] ??
            (workspace.isRunning ? 'ready' : 'stopped'),
        'startedAt': state['startedAt'],
        'version': syntilaWorkspaceAppVersion,
        'installationId': workspace.installationId,
        'uptimeSeconds': _serviceUptimeSeconds(state),
        'processRunning': processRunning,
        'runtimeState': lifecycle.runtime.name,
        'ipcReady': lifecycle.ipcReady,
        'serviceHealthy': lifecycle.serviceHealthy,
      },
      'cloud': {
        'effectiveUrl': workspace.config.cloudUri == null
            ? null
            : WorkspaceConfigurationResolver.cloudHttpOrigin(
                workspace.config.cloudUri!),
        'state': WorkspaceServiceState.cloudStateFor(
          configured: workspace.config.cloudUri != null &&
              workspace.config.workspaceId != null,
          authenticated: workspace.config.authToken?.isNotEmpty == true,
          stage: connection?.connectionStage,
        ).name,
        'lifecycleState': lifecycle.cloud.name,
        'connected': connection?.isConnected ?? false,
        'desiredConnectionState': _desiredCloudState.name,
        'connectionStage': connectionStage?.name ?? 'offline',
        'authenticated': authenticated,
        'synchronized': synchronized,
        'transport': connection?.activeTransportMode,
        'acceptingNewWork': connection?.isConnected == true &&
            connection?.acceptingNewWork == true,
        'lastError': connection?.lastConnectionError,
        'reconnectCount': connection?.reconnectCount ?? 0,
        'lastInventorySyncAt':
            connection?.lastInventorySyncAt?.toIso8601String(),
      },
      'workspace': {
        'workspaceId': workspace.config.workspaceId,
        'workspaceRuntimeId': workspace.config.workspaceRuntimeId,
        'name': registration?.name,
        'cloudUrl': registration?.cloudUrl,
        'workRoot': workspace.workRoot?.path ??
            workspace.config.workRootPath ??
            WorkRootResolver().defaultPath,
      },
      'workers': workers.map((worker) => worker.toJson()).toList(),
      'workerCatalog': _workerCatalogSnapshot(),
      'assignments': {
        'activeCount': activeIds.length,
        'activeIds': activeIds,
        'recoveryRequired': recoveryRequired,
      },
    };
  }

  CloudConnectionState _cloudLifecycleState(
    WorkspaceCloudConnection? connection,
  ) {
    if (connection?.isConnected == true) {
      return CloudConnectionState.connected;
    }
    return switch (connection?.connectionStage) {
      WorkspaceConnectionStage.connecting ||
      WorkspaceConnectionStage.validating ||
      WorkspaceConnectionStage.authenticating ||
      WorkspaceConnectionStage.synchronizing ||
      WorkspaceConnectionStage.switchingToWebSocket =>
        CloudConnectionState.connecting,
      WorkspaceConnectionStage.reconnecting =>
        CloudConnectionState.reconnecting,
      _ => connection?.lastConnectionError == null
          ? CloudConnectionState.disconnected
          : CloudConnectionState.failed,
    };
  }

  Future<Map<String, Object?>> _slotSnapshot() async {
    final subsystem = workspace.workerSubsystem;
    final slots = subsystem?.slotSnapshot() ??
        const <String, Object?>{'workers': <Object?>[], 'busySessions': 0};
    final names = <String, String>{};
    final workers =
        await (subsystem?.listWorkers() ?? Future.value(const <LocalWorker>[]));
    for (final worker in workers) {
      names[worker.id] = worker.workerTypeId;
    }
    return {
      'active': slots['active'] ?? 0,
      'queued': slots['queued'] ?? 0,
      // The total Cloud last sent with an assignment (set on the web
      // Workspaces page); the local record until the first assignment.
      'limit': slots['limit'] ?? await subsystem?.parallelSlots(),
      'workers': [
        for (final raw in (slots['workers'] as List).whereType<Map>())
          {
            ...Map<String, Object?>.from(raw),
            'workerTypeId': names[raw['workerId']],
          },
      ],
      'busySessions': slots['busySessions'] ?? 0,
      'activeAssignmentIds':
          workspace.cloudConnection?.activeAssignmentIds ?? const <String>[],
    };
  }

  Map<String, Object?> _workerCatalogSnapshot() {
    final checks = workspace.workerReadinessMonitor?.checks ??
        const <String, WorkerCheckProgress>{};
    final checkJson = checks.map((key, value) => MapEntry(key, value.toJson()));
    final catalog = (workspace.workerSubsystem?.catalog ??
            workspace.workerCatalogCoordinator)
        ?.snapshot;
    if (catalog == null) {
      return {
        'descriptors': workspace.toolProfileCatalog?.workers
                .map((descriptor) => descriptor.toJson())
                .toList() ??
            const [],
        'checks': checkJson,
        'views': const [],
        'catalogConfirmed': false,
        'localRegistryLoaded': workspace.localWorkerRegistry != null,
      };
    }
    return {
      'checks': checkJson,
      'descriptors':
          catalog.descriptors.map((descriptor) => descriptor.toJson()).toList(),
      'views': catalog.workers
          .map(
            (view) => {
              if (view.descriptor != null)
                'descriptor': view.descriptor!.toJson(),
              'catalogRetired': view.catalogRetired,
              if (view.localWorker != null)
                'localWorker': view.localWorker!.toJson(),
              'localState': view.localState.name,
              'profileState': view.profileState.name,
              'profileMessage': view.profileAvailability.message,
              'profileDetails': view.profileAvailability.details,
              'providerToolState': view.providerToolState.name,
            },
          )
          .toList(),
      'catalogConfirmed': catalog.catalogConfirmed,
      'catalogError': catalog.catalogError,
      'refreshing': catalog.refreshing,
      'localRegistryLoaded': catalog.localRegistryLoaded,
      'localRegistryError': catalog.localRegistryError,
      'removingWorkerIds':
          (workspace.workerSubsystem?.removingWorkerIds ?? const <String>{})
              .toList()
            ..sort(),
    };
  }

  /// A Worker waiting for removal takes no new actions.
  void _rejectRemovingWorker(Object? workerId) {
    if (workerId is String &&
        (workspace.workerSubsystem?.isRemoving(workerId) ?? false)) {
      throw const WorkspaceManagerProtocolException(
        'worker_removing',
        'This Worker is being removed after its current work finishes.',
      );
    }
  }

  int? _serviceUptimeSeconds(Map<String, Object?> state) {
    final startedAt = DateTime.tryParse(state['startedAt']?.toString() ?? '');
    if (startedAt == null) return null;
    return DateTime.now()
        .toUtc()
        .difference(startedAt)
        .inSeconds
        .clamp(0, 1 << 31);
  }

  Future<void> _publishSnapshot() {
    if (_closed) return Future<void>.value();
    final active = _snapshotInFlight;
    if (active != null) {
      _snapshotDirty = true;
      return active;
    }
    final future = _publishSnapshotLoop();
    _snapshotInFlight = future;
    return future.whenComplete(() {
      if (identical(_snapshotInFlight, future)) _snapshotInFlight = null;
    });
  }

  Future<void> _publishSnapshotLoop() async {
    do {
      _snapshotDirty = false;
      await _publishSnapshotOnce();
    } while (!_closed && _snapshotDirty);
  }

  Future<void> _publishSnapshotOnce() async {
    final current = await snapshot();
    if (_closed) return;
    final previous = _previousSnapshot;
    if (previous == null || jsonEncode(previous) != jsonEncode(current)) {
      if (previous != null) {
        if (_nested(previous, 'cloud', 'state') !=
            _nested(current, 'cloud', 'state')) {
          _events.add({
            'name': 'cloud.connectionChanged',
            'cloud': current['cloud'],
          });
        }
        if (jsonEncode(previous['workers']) != jsonEncode(current['workers'])) {
          _events.add({
            'name': 'worker.inventoryChanged',
            'workers': current['workers'],
          });
        }
        if (jsonEncode(previous['workerCatalog']) !=
            jsonEncode(current['workerCatalog'])) {
          _events.add({
            'name': 'worker.catalogChanged',
            'workerCatalog': current['workerCatalog'],
          });
        }
        final before = _nested(previous, 'assignments', 'activeIds');
        final after = _nested(current, 'assignments', 'activeIds');
        final beforeIds =
            before is List ? before.cast<String>().toSet() : <String>{};
        final afterIds =
            after is List ? after.cast<String>().toSet() : <String>{};
        for (final id in afterIds.difference(beforeIds)) {
          _events.add({'name': 'assignment.started', 'assignmentId': id});
        }
        for (final id in beforeIds.difference(afterIds)) {
          _events.add({'name': 'assignment.completed', 'assignmentId': id});
        }
      }
      _events.add({'name': 'service.statusChanged', 'snapshot': current});
      _previousSnapshot = current;
    }
  }

  Object? _nested(Map<String, Object?> snapshot, String key, String child) {
    final value = snapshot[key];
    return value is Map ? value[child] : null;
  }

  /// The sign-in/registration helper. It replaces the runtime identity, so it
  /// only runs while Cloud is disconnected and no work is active.
  WorkspaceHeadlessAuth _headlessAuthForRegistration() {
    final connection = workspace.cloudConnection;
    if (reloadRuntime == null ||
        (connection?.activeAssignmentCount ?? 0) > 0 ||
        connection?.isConnected == true) {
      throw const WorkspaceManagerProtocolException(
        'login_not_ready',
        'Disconnect Cloud and finish active work before registering: '
            'syntila disconnect',
      );
    }
    return _headlessAuth ??= WorkspaceHeadlessAuth(
      dataDirectory: workspace.config.dataDirectory,
      cloudUrl: WorkspaceConfigurationResolver.cloudHttpOrigin(
        workspace.config.cloudUri!,
      ),
      credentialStore: workspace.credentialStore,
      reloadRuntime: _reloadRuntime,
    );
  }

  Future<Object?> _dispatch(
    String command,
    Map<String, Object?> payload,
  ) async {
    final connection = workspace.cloudConnection;
    final registry = workspace.localWorkerRegistry;
    final workerSubsystem = workspace.workerSubsystem;
    if (WorkspaceExternalWorkerCommands.handles(command)) {
      return _externalWorkers().handle(command, payload);
    }
    if (WorkspaceMcpCommands.handles(command)) {
      return _mcp().handle(command, payload);
    }
    switch (command) {
      case 'auth.register':
        final desired =
            WorkspaceSettingsStore(workspace.config.dataDirectory).readSync();
        if (desired == null ||
            WorkspaceConfigurationResolver.cloudHttpOrigin(
                    Uri.parse(desired.cloudUrl)) !=
                (workspace.config.cloudUri == null
                    ? null
                    : WorkspaceConfigurationResolver.cloudHttpOrigin(
                        workspace.config.cloudUri!))) {
          throw const WorkspaceManagerProtocolException(
              'configuration_restart_required',
              'Cloud configuration changed. Run: syntila service restart');
        }
        return _headlessAuthForRegistration().register();
      case 'auth.start':
        _headlessAuthForRegistration();
        // Only email/password sign-in is supported; there is no browser flow.
        if (payload['email'] is! String || payload['password'] is! String) {
          throw const WorkspaceManagerProtocolException(
            'invalid_login',
            'Email and password are required.',
          );
        }
        return _headlessAuth!.start(
          email: payload['email'] as String?,
          password: payload['password'] as String?,
        );
      case 'auth.status':
        return _headlessAuth?.status() ?? const {'phase': 'idle'};
      case 'service.getStatus':
        return snapshot();
      case 'service.getVersion':
        return {'version': syntilaWorkspaceAppVersion};
      case 'service.getHealth':
        return {
          'healthy': workspace.isRunning,
          'processState': workspace.isRunning ? 'ready' : 'stopped',
        };
      case 'updates.status':
        return workspace.updateStatusProvider?.call() ??
            const {'phase': 'unconfigured'};
      case 'updates.check':
        final updateHandler = workspace.updateHandler;
        if (updateHandler == null) {
          throw const WorkspaceManagerProtocolException(
            'updates_unavailable',
            'Workspace update checks are not configured for this installation.',
          );
        }
        return updateHandler(const {'action': 'check'});
      case 'service.restart':
      case 'service.shutdown':
        throw const WorkspaceManagerProtocolException(
          'host_boundary_required',
          'Service restart and shutdown must be requested through the host manager.',
        );
      case 'connection.connect':
      case 'connection.reconnect':
        if (connection == null) {
          throw const WorkspaceManagerProtocolException(
            'not_configured',
            'Workspace Cloud connection is not configured.',
          );
        }
        connection.validateConfiguration();
        if (connection.connectionStage == WorkspaceConnectionStage.ready &&
            command == 'connection.connect') {
          return snapshot();
        }
        await _setDesiredCloudState(DesiredCloudConnectionState.connected);
        connection.resumeNewWork();
        await connection.retryNow();
        return snapshot();
      case 'service.prepareStop':
        if (connection != null) {
          if (!await _drainAssignments(connection)) {
            connection.resumeNewWork();
            throw const WorkspaceManagerProtocolException(
              'assignments_active',
              'Work is still running. Let it finish before stopping the service.',
            );
          }
          await connection.close();
        }
        return snapshot();
      case 'connection.disconnect':
        if (connection == null) {
          await _setDesiredCloudState(DesiredCloudConnectionState.disconnected);
          return snapshot();
        }
        final drained = await _drainAssignments(connection);
        if (!drained) {
          connection.resumeNewWork();
          throw const WorkspaceManagerProtocolException(
            'assignments_active',
            'Active assignments did not finish within the disconnect grace period.',
          );
        }
        await connection.close();
        await _setDesiredCloudState(DesiredCloudConnectionState.disconnected);
        return snapshot();
      case 'connection.pause':
        connection?.pauseNewWork();
        return snapshot();
      case 'connection.resume':
        if (connection?.isConnected == true) connection?.resumeNewWork();
        return snapshot();
      case 'workers.list':
      case 'workers.getStatus':
        if (registry == null && workerSubsystem == null) return const [];
        final workerId = payload['workerId'];
        if (workerId is String) {
          final worker = await (workerSubsystem?.resolveWorker(workerId) ??
              registry?.find(workerId));
          if (worker == null) {
            throw const WorkspaceManagerProtocolException(
              'worker_not_found',
              'Worker does not exist.',
            );
          }
          return worker.toJson();
        }
        return (await (workerSubsystem?.listWorkers() ?? registry!.list()))
            .map((worker) => worker.toJson())
            .toList();
      case 'workers.getCatalogSnapshot':
        return _workerCatalogSnapshot();
      case 'workers.reset':
        if (registry == null) return snapshot();
        if ((connection?.activeAssignmentCount ?? 0) > 0) {
          throw const WorkspaceManagerProtocolException(
            'assignments_active',
            'Wait for active work to finish first.',
          );
        }
        await (workerSubsystem?.reset() ?? registry.reset());
        return snapshot();
      case 'workers.refreshCatalog':
        await (workerSubsystem?.refresh(force: true) ??
            workspace.workerCatalogCoordinator?.refresh(force: true));
        return _workerCatalogSnapshot();
      case 'workers.refreshWorker':
        final refreshType = payload['workerTypeId'];
        if (refreshType is! String || refreshType.isEmpty) {
          throw const WorkspaceManagerProtocolException(
            'invalid_request',
            'workerTypeId is required.',
          );
        }
        await (workerSubsystem?.refreshWorker(refreshType) ??
            workspace.workerCatalogCoordinator?.refreshWorker(refreshType));
        return _workerCatalogSnapshot();
      case 'workers.ensureProfile':
        final workerTypeId = payload['workerTypeId'];
        if (workerTypeId is! String) {
          throw const WorkspaceManagerProtocolException(
            'invalid_request',
            'workerTypeId is required.',
          );
        }
        await (workerSubsystem?.ensureProfile(
              workerTypeId,
              waitForActiveRefresh: payload['waitForActiveRefresh'] == true,
            ) ??
            workspace.workerCatalogCoordinator?.ensureWorkerProfileAvailable(
              workerTypeId,
              waitForActiveRefresh: payload['waitForActiveRefresh'] == true,
            ));
        return _workerCatalogSnapshot();
      case 'workers.configureWorker':
        final workerTypeId = payload['workerTypeId'];
        if (workerTypeId is! String || registry == null) {
          throw const WorkspaceManagerProtocolException(
            'invalid_request',
            'workerTypeId is required.',
          );
        }
        if (isExternalWorkerType(workerTypeId)) {
          throw const WorkspaceManagerProtocolException(
            'plugin_managed_via_mcp',
            'External Workers are managed via MCP.',
          );
        }
        final coordinator = workspace.workerCatalogCoordinator;
        if (coordinator == null) {
          throw const WorkspaceManagerProtocolException(
            'catalog_unavailable',
            'The Worker catalog is not available from Workspace Service.',
          );
        }
        final removing = workerSubsystem?.removingWorkerIds ?? const {};
        if ((await registry.list()).any(
          (worker) =>
              worker.workerTypeId == workerTypeId &&
              removing.contains(worker.id),
        )) {
          throw const WorkspaceManagerProtocolException(
            'worker_removing',
            'This Worker is being removed. Add it again after removal finishes.',
          );
        }
        var descriptor = coordinator.entryForWorker(workerTypeId);
        if (descriptor == null) {
          await coordinator.refresh(force: true);
          descriptor = coordinator.entryForWorker(workerTypeId);
        }
        if (descriptor == null) {
          throw const WorkspaceManagerProtocolException(
            'worker_not_found',
            'Worker is not in the approved Cloud catalog.',
          );
        }
        final worker = await LocalWorkerSetupService(registry: registry)
            .createCatalogWorker(
          entry: descriptor,
          permissions: defaultLocalWorkerPermissions,
        );
        await coordinator.ensureWorkerProfileAvailable(
          workerTypeId,
          waitForActiveRefresh: true,
        );
        await _runWorkerReadiness(
          () => workspace.workerReadinessMonitor?.checkNow(
            mode: LocalWorkerProbeMode.passive,
            workerTypeId: workerTypeId,
          ),
        );
        return (await registry.find(worker.id))?.toJson();
      case 'workers.removeWorker':
        final removeId = payload['workerId'];
        if (removeId is! String || removeId.isEmpty) {
          throw const WorkspaceManagerProtocolException(
            'invalid_request',
            'workerId is required.',
          );
        }
        if (workerSubsystem == null && registry == null) {
          throw const WorkspaceManagerProtocolException(
            'not_configured',
            'Local Worker registry is not available.',
          );
        }
        final removeTarget = await registry?.find(removeId);
        if (removeTarget != null &&
            isExternalWorkerType(removeTarget.workerTypeId)) {
          throw const WorkspaceManagerProtocolException(
            'plugin_managed_via_mcp',
            'External Workers are managed via MCP.',
          );
        }
        var removed = false;
        if (workerSubsystem != null) {
          removed = await workerSubsystem.removeWorker(removeId);
        } else {
          await registry!.remove(removeId);
          removed = true;
        }
        return {
          'workerId': removeId,
          'state': removed ? 'removed' : 'removing',
        };
      case 'workers.enableWorker':
      case 'workers.disableWorker':
        _rejectRemovingWorker(payload['workerId']);
        if (registry == null) {
          throw const WorkspaceManagerProtocolException(
            'not_configured',
            'Local Worker registry is not available.',
          );
        }
        final workerId = payload['workerId'];
        if (workerId is! String) {
          throw const WorkspaceManagerProtocolException(
            'invalid_request',
            'workerId is required.',
          );
        }
        final worker = command == 'workers.disableWorker'
            ? await (workerSubsystem?.disableWorker(workerId) ??
                registry.update(
                  workerId,
                  (current) => current.copyWith(
                    status: LocalWorkerStatus.disabled,
                    activationState: LocalWorkerActivationState.disabled,
                  ),
                ))
            : await (workerSubsystem?.enableWorker(workerId) ??
                registry.update(
                  workerId,
                  (current) => current.copyWith(
                    status: LocalWorkerStatus.needsAttention,
                    activationState: LocalWorkerActivationState.enabled,
                  ),
                ));
        if (worker == null) {
          throw const WorkspaceManagerProtocolException(
            'worker_not_found',
            'Worker does not exist.',
          );
        }
        return worker.toJson();
      case 'workers.testWorker':
      case 'worker.test':
        _rejectRemovingWorker(payload['workerId']);
        final workerId = payload['workerId'];
        if (workerId is! String || registry == null) {
          throw const WorkspaceManagerProtocolException(
            'invalid_request',
            'workerId is required.',
          );
        }
        final worker = await (workerSubsystem?.resolveWorker(workerId) ??
            registry.find(workerId));
        if (worker == null) {
          throw const WorkspaceManagerProtocolException(
            'worker_not_found',
            'Worker does not exist.',
          );
        }
        final tested = await _runWorkerReadinessResult(
          workerSubsystem?.testWorker(workerId) ??
              (() async {
                await workspace.workerReadinessMonitor?.checkNow(
                  mode: LocalWorkerProbeMode.live,
                  workerTypeId: worker.workerTypeId,
                );
                return registry.find(workerId);
              })(),
        );
        return tested?.toJson();
      case 'workers.checkReadiness':
        final workerTypeId = payload['workerTypeId'];
        if (workerTypeId != null && workerTypeId is! String) {
          throw const WorkspaceManagerProtocolException(
            'invalid_request',
            'workerTypeId must be a string.',
          );
        }
        final mode = payload['mode'] == 'live'
            ? LocalWorkerProbeMode.live
            : LocalWorkerProbeMode.passive;
        await _runWorkerReadiness(
          () =>
              workerSubsystem?.refreshReadiness(
                mode: mode,
                workerTypeId: workerTypeId as String?,
              ) ??
              workspace.workerReadinessMonitor?.checkNow(
                mode: mode,
                workerTypeId: workerTypeId as String?,
              ),
        );
        return snapshot();
      case 'workers.rollbackProfile':
        final workerTypeId = payload['workerTypeId'];
        if (workerTypeId is! String) {
          throw const WorkspaceManagerProtocolException(
            'invalid_request',
            'workerTypeId is required.',
          );
        }
        final passed = workerSubsystem != null
            ? await workerSubsystem.rollbackProfile(workerTypeId)
            : await workspace.workerReadinessMonitor?.rollbackToolProfile(
                  workerTypeId,
                ) ??
                false;
        return {'passed': passed, 'snapshot': await snapshot()};
      case 'execution.getSlots':
        return _slotSnapshot();
      case 'execution.resetSlots':
        {
          // Stop what is running or waiting, then discard bookkeeping that did
          // not release itself. Space folders and provider sessions on disk
          // are untouched; Cloud reconciles the stopped assignments on sync.
          for (final assignmentId
              in connection?.activeAssignmentIds ?? const <String>[]) {
            try {
              await connection?.cancelActiveAssignment(
                assignmentId,
                reason: 'Slots reset by Workspace user',
              );
            } on Object {
              // Continue: the reset below clears the bookkeeping regardless.
            }
          }
          final stopped = await workerSubsystem?.resetSlots() ?? 0;
          connection?.forgetActiveAssignments();
          return {...await _slotSnapshot(), 'stopped': stopped};
        }
      case 'execution.listActiveAssignments':
        return {
          'activeAssignmentIds': connection?.activeAssignmentIds ?? const [],
        };
      case 'execution.cancelAssignment':
        final assignmentId = payload['assignmentId'];
        if (assignmentId is! String) {
          throw const WorkspaceManagerProtocolException(
            'invalid_request',
            'assignmentId is required.',
          );
        }
        final cancelled =
            await connection?.cancelActiveAssignment(assignmentId) ?? false;
        return {'cancelled': cancelled};
      case 'configuration.get':
        return {
          'workspace': await snapshot().then((value) => value['workspace']),
          'workRoot': workspace.workRoot?.path ??
              workspace.config.workRootPath ??
              WorkRootResolver().defaultPath,
          'settingsFile': workspace.config.settingsFile?.path,
          'folders': workspace.config.folders,
          'serviceEnabled': workspace.config.serviceEnabled,
          'connectOnStart': workspace.config.connectOnStart,
        };
      case 'diagnostics.getLogs':
        return {'text': await _readLogTail()};
      case 'diagnostics.getMetrics':
        return {
          ...await sampleWorkspaceProcessMetrics(),
          'activeAssignments': connection?.activeAssignmentCount ?? 0,
          'workerCount': (await registry?.list())?.length ?? 0,
          'cloudConnected': connection?.isConnected ?? false,
          'reconnectCount': connection?.reconnectCount ?? 0,
        };
      case 'diagnostics.getDiagnostics':
        final paths = WorkspacePaths(workspace.config.dataDirectory);
        final file = await writeWorkspaceDiagnostics(
          config: workspace.config,
          connection: connection,
          journal: connection?.assignmentJournal,
          workerRegistry: registry,
          toolProfileReleaseStore: workspace.toolProfileReleaseStore,
          workRootPath: workspace.workRoot?.path,
          workerDiagnosticStore: (workerTypeId) => WorkerDiagnosticStore(
            directory: Directory(
              '${paths.workerStateDirectory(workerTypeId).parent.path}'
              '${Platform.pathSeparator}logs',
            ),
          ),
        );
        return {'path': file.path, 'text': await file.readAsString()};
      case 'folders.list':
        return _allowedFolderSnapshot(await _allowedFolders().list());
      case 'folders.add':
        {
          final path = payload['path'];
          final displayName = payload['displayName'];
          if (path is! String ||
              (displayName != null && displayName is! String)) {
            throw const WorkspaceManagerProtocolException(
              'invalid_request',
              'path is required.',
            );
          }
          final folder = await _allowedFolderCall(
            () => _allowedFolders().add(
              path,
              displayName: displayName as String?,
            ),
          );
          return folder.toJson();
        }
      case 'folders.remove':
        {
          final id = payload['folderId'];
          if (id is! String) {
            throw const WorkspaceManagerProtocolException(
              'invalid_request',
              'folderId is required.',
            );
          }
          // Only the allowance is forgotten; the folder stays on disk.
          return {'removed': await _allowedFolders().remove(id)};
        }
      case 'folders.rename':
        {
          final id = payload['folderId'];
          final displayName = payload['displayName'];
          if (id is! String || displayName is! String) {
            throw const WorkspaceManagerProtocolException(
              'invalid_request',
              'folderId and displayName are required.',
            );
          }
          final folder = await _allowedFolderCall(
            () => _allowedFolders().rename(id, displayName),
          );
          if (folder == null) {
            throw const WorkspaceManagerProtocolException(
              'folder_not_found',
              'Folder is not allowed.',
            );
          }
          return folder.toJson();
        }
      case 'folders.recheck':
        {
          final id = payload['folderId'];
          if (id != null && id is! String) {
            throw const WorkspaceManagerProtocolException(
              'invalid_request',
              'folderId must be a string.',
            );
          }
          return _allowedFolderSnapshot(
            await _allowedFolders().recheck(id: id as String?),
          );
        }
      default:
        throw WorkspaceManagerProtocolException(
          'unsupported_command',
          'Unsupported Workspace Manager command: $command',
        );
    }
  }

  /// MCP server management (ADR-028) over the Workspace's MCP subsystem.
  WorkspaceMcpCommands _mcp() {
    final subsystem = workspace.mcpSubsystem;
    if (subsystem == null) {
      throw const WorkspaceManagerProtocolException(
        'unsupported_command',
        'MCP servers are not available on this Workspace.',
      );
    }
    return _mcpCommands ??= WorkspaceMcpCommands(subsystem.service);
  }

  /// Plugin management (ADR-027) over the Workspace's shared plugin
  /// subsystem; the CLI only sends requests and prints results.
  WorkspaceExternalWorkerCommands _externalWorkers() {
    final subsystem = workspace.externalWorkers;
    if (subsystem == null) {
      throw const WorkspaceManagerProtocolException(
        'unsupported_command',
        'External Workers are not available on this Workspace.',
      );
    }
    return _externalWorkerCommands ??= WorkspaceExternalWorkerCommands(
      subsystem.service,
      publish: _events.add,
    );
  }

  /// Owner-managed folders that Spaces on this Workspace may attach. The
  /// Manager IPC endpoint is restricted to the owner OS account and its
  /// installation key; Cloud cannot add or change entries.
  AllowedFolderRegistry _allowedFolders() {
    final paths = WorkspacePaths(workspace.config.dataDirectory);
    return _allowedFolderRegistry ??= AllowedFolderRegistry(
      registryDirectory: paths.spaceDirectoryRegistryDirectory,
      workRoot: workspace.workRoot ??
          Directory(
            workspace.config.workRootPath ?? WorkRootResolver().defaultPath,
          ),
      applicationDataRoot: paths.applicationDataRoot,
      homeDirectory: currentPlatformRuntime.homeDirectory,
    );
  }

  Map<String, Object?> _allowedFolderSnapshot(List<AllowedFolder> folders) => {
        'folders': [for (final folder in folders) folder.toJson()],
        'maxFolders': AllowedFolderRegistry.maxFolders,
      };

  Future<T> _allowedFolderCall<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AllowedFolderViolation catch (error) {
      throw WorkspaceManagerProtocolException(error.code, error.message);
    }
  }

  /// Republishes the path-free folder list so Cloud stops offering removed
  /// or inaccessible folders without waiting for the next reconnect.
  void _publishAllowedFolders() {
    final connection = workspace.cloudConnection;
    if (connection != null) unawaited(connection.refreshWorkerInventory());
  }

  Future<void> _setDesiredCloudState(
    DesiredCloudConnectionState desired,
  ) async {
    _desiredCloudState = desired;
  }

  Future<void> _runWorkerReadiness(Future<void>? Function() operation) async {
    try {
      await operation()?.timeout(_workerReadinessCommandTimeout);
    } on TimeoutException {
      throw const WorkspaceManagerProtocolException(
        'worker_probe_timeout',
        'Worker readiness check exceeded its deadline.',
      );
    }
  }

  Future<T?> _runWorkerReadinessResult<T>(Future<T?> operation) async {
    try {
      return await operation.timeout(_workerReadinessCommandTimeout);
    } on TimeoutException {
      throw const WorkspaceManagerProtocolException(
        'worker_probe_timeout',
        'Worker readiness check exceeded its deadline.',
      );
    }
  }

  Future<void> _reloadRuntime() async {
    final rebuild = reloadRuntime;
    if (rebuild == null) {
      throw const WorkspaceManagerProtocolException(
        'configuration_reload_unavailable',
        'This service cannot reload its runtime configuration.',
      );
    }
    final current = workspace;
    if (current.cloudConnection != null &&
        !await _drainAssignments(current.cloudConnection!)) {
      current.cloudConnection!.resumeNewWork();
      throw const WorkspaceManagerProtocolException(
        'assignments_active',
        'Active assignments must finish before configuration can be reloaded.',
      );
    }
    await current.stop();
    try {
      final replacement = await rebuild();
      await replacement.start(connectCloud: false);
      _workspace = replacement;
      _allowedFolderRegistry = null;
      _bindWorkspaceEvents(replacement);
      if (_desiredCloudState == DesiredCloudConnectionState.connected) {
        // Completing configuration reload means the local runtime is ready,
        // not that Cloud is reachable. Its transport owns retry/backoff.
        unawaited(
          replacement.cloudConnection?.connect().catchError((Object _) {}) ??
              Future<void>.value(),
        );
      }
    } on Object {
      throw const WorkspaceManagerProtocolException(
        'configuration_reload_failed',
        'Workspace configuration could not be loaded. Local files were preserved.',
      );
    }
  }

  Future<bool> _drainAssignments(WorkspaceCloudConnection connection) async {
    connection.beginDrain();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (connection.activeAssignmentCount > 0 &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return connection.activeAssignmentCount == 0;
  }

  Future<String> _readLogTail() async {
    final file = WorkspacePaths(workspace.config.dataDirectory).logsFile;
    if (!await file.exists()) return '';
    final length = await file.length();
    final start = length > 256 * 1024 ? length - 256 * 1024 : 0;
    final handle = await file.open();
    try {
      await handle.setPosition(start);
      return utf8.decode(
        await handle.read(length - start),
        allowMalformed: true,
      );
    } finally {
      await handle.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _headlessAuth?.close();
    final connection = _observedConnection;
    if (connection != null) connection.onStateChanged = null;
    _observedConnection = null;
    _observedCatalog?.removeListener(_handleWorkspaceChange);
    _observedReadiness?.removeListener(_handleWorkspaceChange);
    _observedCatalog = null;
    await _server?.close();
    _server = null;
    await _events.close();
  }
}
