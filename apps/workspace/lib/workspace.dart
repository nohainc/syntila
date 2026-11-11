import 'mcp_subsystem.dart';
import 'external_worker_subsystem.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cloud_connection.dart';
import 'local_worker_registry.dart';
import 'workspace_configuration.dart';
import 'secure_credentials.dart';
import 'platform_runtime.dart';
import 'work_root.dart';
import 'workspace_paths.dart';
import 'worker_readiness.dart';
import 'tool_profile_catalog.dart';
import 'worker_profile_store.dart';
import 'worker_catalog_coordinator.dart';
import 'workspace_service_state.dart';
import 'workspace_registration_models.dart';
import 'workspace_worker_subsystem.dart';

export 'local_worker_registry.dart';
export 'release_trust_roots.dart';
export 'tool_profile_release_verifier.dart';
export 'tool_profile_catalog.dart';
export 'worker_profile_store.dart';
export 'worker_catalog_coordinator.dart';
export 'workspace_paths.dart';
export 'workspace_background_service.dart';
export 'workspace_service_lifecycle.dart';
export 'space_directory.dart';
export 'workspace_worker_subsystem.dart';

typedef WorkspaceStatusProvider = Future<Map<String, Object?>> Function();
typedef WorkspaceUpdateHandler = Future<Map<String, Object?>> Function(
    Map<String, Object?> request);

class WorkspaceConfig {
  const WorkspaceConfig({
    required this.dataDirectory,
    this.cloudUri,
    this.workspaceRuntimeId,
    this.installationId,
    this.workspaceId,
    this.authToken,
    this.workRootPath,
    this.serviceEnabled = true,
    this.connectOnStart = false,
    this.legacyParallelSlots,
    this.folders = const {},
    this.settingsFile,
  });

  final Directory dataDirectory;
  final Uri? cloudUri;
  final String? workspaceRuntimeId;
  final String? installationId;
  final String? workspaceId;
  final String? authToken;
  final String? workRootPath;
  final bool serviceEnabled;
  final bool connectOnStart;

  /// See [WorkspaceSettings.legacyParallelSlots]; Cloud owns slots.
  final int? legacyParallelSlots;
  final Map<String, String> folders;
  final File? settingsFile;

  WorkRootResolver get workRootResolver =>
      WorkRootResolver(overridePath: workRootPath);

  factory WorkspaceConfig.fromArgs(
    List<String> args, {
    SecureCredentialStore? credentialStore,
    bool ignoreSavedRegistration = false,
  }) {
    final resolved = const WorkspaceConfigurationResolver().resolve(
      args,
      credentialStore: credentialStore,
      ignoreSavedRegistration: ignoreSavedRegistration,
    );
    return WorkspaceConfig(
      dataDirectory: resolved.dataDirectory,
      cloudUri: resolved.cloudUri,
      workspaceRuntimeId: resolved.workspaceRuntimeId,
      installationId: resolved.installationId,
      workspaceId: resolved.workspaceId,
      authToken: resolved.credentials.runtimeToken,
      workRootPath: resolved.workRootPath,
      serviceEnabled: resolved.settings.serviceEnabled,
      connectOnStart: resolved.settings.connectOnStart,
      legacyParallelSlots: resolved.settings.legacyParallelSlots,
      folders: resolved.settings.folders,
      settingsFile: resolved.settingsFile,
    );
  }

  static Directory resolveDataDirectory(List<String> args) {
    return WorkspaceConfigurationResolver.resolveDataDirectory(args);
  }
}

class WorkspaceLogger {
  WorkspaceLogger(
    this._output, {
    this.redact = _identity,
    this.context = const {},
  });
  IOSink _output;
  final String Function(String) redact;
  final Map<String, Object?> context;

  static String _identity(String value) => value;

  void attach(IOSink output) => _output = output;

  void info(String message, [Map<String, Object?> details = const {}]) {
    final record = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': 'info',
      'severity': 'info',
      'event': message,
      'message': message,
      'serviceVersion': context['serviceVersion'],
      'workspaceId': context['workspaceId'],
      if (details.isNotEmpty) 'details': _sanitize(details),
    };
    _output.writeln(redact(jsonEncode(record)));
  }

  static Object? _sanitize(Object? value, {int depth = 0}) {
    if (depth > 5) return '[depth limited]';
    if (value is String) {
      return value.length > 512 ? '${value.substring(0, 512)}…' : value;
    }
    if (value == null || value is num || value is bool) return value;
    if (value is List) {
      return value
          .take(50)
          .map((item) => _sanitize(item, depth: depth + 1))
          .toList();
    }
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries.take(80))
          entry.key.toString(): RegExp(
            r'(secret|token|password|api[_-]?key|authorization|cookie|raw[_-]?credential|private[_-]?key)',
            caseSensitive: false,
          ).hasMatch(entry.key.toString())
              ? '[redacted]'
              : _sanitize(entry.value, depth: depth + 1),
      };
    }
    return '[${value.runtimeType}]';
  }
}

class WorkspaceRuntime {
  WorkspaceRuntime({
    required this.config,
    IOSink? logOutput,
    this.cloudConnection,
    this.statusProvider,
    this.updateStatusProvider,
    this.updateHandler,
    SecureCredentialStore? credentialStore,
    this.toolProfileReleaseStore,
    this.toolProfileCatalog,
    this.workerCatalogCoordinator,
    this.workerSubsystem,
    this.externalWorkers,
    this.mcpSubsystem,
    LocalWorkerRegistry? localWorkerRegistry,
    this.workerReadinessMonitor,
    this.workerShutdownHandler,
    this.workerRecoveryHandler,
    String Function(String)? redactLog,
    this.logFileMaxBytes = 1024 * 1024,
  })  : _configuredLogOutput = logOutput,
        credentialStore =
            credentialStore ?? const PlatformSecureCredentialStore(),
        localWorkerRegistry = localWorkerRegistry ??
            (config.workspaceId == null
                ? null
                : LocalWorkerRegistry(
                    dataDirectory: config.dataDirectory,
                    workspaceId: config.workspaceId!,
                  )),
        _log = WorkspaceLogger(
          logOutput ?? stdout,
          redact: redactLog ?? WorkspaceLogger._identity,
          context: {
            'serviceVersion': syntilaWorkspaceAppVersion,
            if (config.workspaceId != null) 'workspaceId': config.workspaceId,
          },
        ) {
    if (logFileMaxBytes <= 0) {
      throw ArgumentError.value(
        logFileMaxBytes,
        'logFileMaxBytes',
        'must be positive',
      );
    }
  }

  final WorkspaceConfig config;
  final SecureCredentialStore credentialStore;
  final WorkerProfileStorePort? toolProfileReleaseStore;
  final ToolProfileCatalogClient? toolProfileCatalog;
  final WorkerCatalogCoordinator? workerCatalogCoordinator;

  /// Service-owned facade for registry, Profiles, readiness and execution.
  final WorkspaceWorkerSubsystem? workerSubsystem;

  /// Custom Worker plugins (ADR-027): store, registry, lease and runtime.
  final ExternalWorkerSubsystem? externalWorkers;

  /// MCP server registry and consent (ADR-028).
  final McpSubsystem? mcpSubsystem;
  final LocalWorkerRegistry? localWorkerRegistry;
  final WorkerReadinessMonitor? workerReadinessMonitor;
  final Future<void> Function()? workerShutdownHandler;
  final Future<int> Function()? workerRecoveryHandler;
  final WorkspaceCloudConnection? cloudConnection;
  final WorkspaceStatusProvider? statusProvider;
  final WorkspaceStatusProvider? updateStatusProvider;
  final WorkspaceUpdateHandler? updateHandler;
  final IOSink? _configuredLogOutput;
  final int logFileMaxBytes;
  final WorkspaceLogger _log;
  IOSink? _ownedLogOutput;
  RandomAccessFile? _lock;
  Directory? _workRoot;
  bool _running = false;
  DateTime? _startedAt;
  Timer? _stateTimer;
  Timer? _logRotationTimer;
  Future<void> _stateWriteQueue = Future<void>.value();
  final List<StreamSubscription<ProcessSignal>> _signalSubscriptions = [];

  String? get installationId => config.installationId;
  bool get isRunning => _running;
  Directory? get workRoot => _workRoot;
  Future<void> start({bool connectCloud = true}) async {
    if (_running) return;
    await config.dataDirectory.create(recursive: true);
    await currentPlatformRuntime.restrictPermissions(
      config.dataDirectory.path,
      directory: true,
    );
    final lockFile = WorkspacePaths(
      config.dataDirectory,
    ).installationLockFile(config.installationId);
    try {
      _lock = await lockFile.open(mode: FileMode.writeOnlyAppend);
      await _lock!.lock(FileLock.exclusive);
    } on FileSystemException {
      await _lock?.close();
      _lock = null;
      throw StateError('another Workspace instance already owns the lock');
    }
    try {
      await _writeServiceState(WorkspaceServiceProcessState.starting);
      await _writeServiceState(WorkspaceServiceProcessState.initializing);
      // The installation lock is held before journal recovery, so no second
      // process can classify or replay the same in-flight assignments.
      await cloudConnection?.assignmentJournal?.recoverAfterRestart();
      final reapedWorkers = await workerRecoveryHandler?.call() ?? 0;
      if (reapedWorkers > 0) {
        _log.info('Recovered orphaned Worker Engine processes', {
          'processCount': reapedWorkers,
        });
      }
      _workRoot = await config.workRootResolver.resolve();
      final paths = WorkspacePaths(config.dataDirectory);
      paths.validateWorkRootSeparation(_workRoot!);
      await paths.prepareRuntimeDirectories();
      if (_configuredLogOutput == null) {
        _ownedLogOutput = await _openLogFile();
        _log.attach(_ownedLogOutput!);
        _logRotationTimer = Timer.periodic(const Duration(seconds: 30), (_) {
          unawaited(_rotateLogIfNeeded());
        });
      }
      workerCatalogCoordinator?.start();
      await workerReadinessMonitor?.start();
      _signalSubscriptions.addAll(
        currentPlatformRuntime.watchTermination(() => unawaited(stop())),
      );
      _running = true;
      _startedAt = DateTime.now().toUtc();
      await _writeServiceState(WorkspaceServiceProcessState.ready);
      _stateTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(_writeServiceState(WorkspaceServiceProcessState.ready));
      });
    } on Object catch (error) {
      _running = false;
      _stateTimer?.cancel();
      _stateTimer = null;
      _logRotationTimer?.cancel();
      _logRotationTimer = null;
      await workerReadinessMonitor?.dispose();
      workerCatalogCoordinator?.dispose();
      toolProfileCatalog?.close();
      final subscriptions =
          List<StreamSubscription<void>>.from(_signalSubscriptions);
      _signalSubscriptions.clear();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await _lock?.unlock();
      await _lock?.close();
      _lock = null;
      await _ownedLogOutput?.flush();
      await _ownedLogOutput?.close();
      _ownedLogOutput = null;
      if (_configuredLogOutput == null) _log.attach(stdout);
      await _writeServiceState(
        WorkspaceServiceProcessState.failed,
        failure: error.toString(),
      );
      rethrow;
    }
    if (connectCloud) {
      try {
        await cloudConnection?.connect();
      } on Object {
        // Keep the process and local runtime state alive. The headless service
        // entry point retries this initial Cloud connection with backoff.
        await _writeServiceState(WorkspaceServiceProcessState.ready);
        rethrow;
      }
    }
    _log.info('Workspace started', {
      'dataDirectory': config.dataDirectory.path,
      'workRoot': _workRoot!.path,
    });
  }

  Future<void> stop() async {
    if (!_running) return;
    await _writeServiceState(WorkspaceServiceProcessState.stopping);
    _running = false;
    _stateTimer?.cancel();
    _stateTimer = null;
    _logRotationTimer?.cancel();
    _logRotationTimer = null;
    await workerReadinessMonitor?.dispose();
    workerCatalogCoordinator?.dispose();
    toolProfileCatalog?.close();
    final subscriptions =
        List<StreamSubscription<void>>.from(_signalSubscriptions);
    _signalSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    try {
      await cloudConnection?.close();
    } finally {
      await workerShutdownHandler?.call();
    }
    await _writeServiceState(WorkspaceServiceProcessState.stopped);
    await _lock?.unlock();
    await _lock?.close();
    _lock = null;
    _log.info('Workspace stopped');
    await _ownedLogOutput?.flush();
    await _ownedLogOutput?.close();
    _ownedLogOutput = null;
    if (_configuredLogOutput == null) _log.attach(stdout);
  }

  Future<void> _writeServiceState(
    WorkspaceServiceProcessState processState, {
    String? failure,
  }) {
    final connection = cloudConnection;
    final nextWrite = _stateWriteQueue.then(
      (_) => writeWorkspaceServiceState(
        config.dataDirectory,
        WorkspaceServiceState(
          processState: processState,
          cloudState: WorkspaceServiceState.cloudStateFor(
            configured: config.cloudUri != null && config.workspaceId != null,
            authenticated: config.authToken?.isNotEmpty == true,
            stage: connection?.connectionStage,
          ),
          installationId: config.installationId,
          updatedAt: DateTime.now().toUtc(),
          startedAt: _startedAt,
          executionState: (connection?.activeAssignmentCount ?? 0) > 0
              ? WorkspaceServiceExecutionState.executing
              : WorkspaceServiceExecutionState.idle,
          activeAssignments: connection?.activeAssignmentCount ?? 0,
          failure: failure,
        ),
      ),
    );
    _stateWriteQueue = nextWrite.catchError((Object _) {});
    return nextWrite;
  }

  Future<IOSink> _openLogFile() async {
    final logsDirectory = WorkspacePaths(config.dataDirectory).logsDirectory;
    await logsDirectory.create(recursive: true);
    await currentPlatformRuntime.restrictPermissions(
      logsDirectory.path,
      directory: true,
    );
    final current = File('${logsDirectory.path}/workspace.log');
    if (await current.exists() && await current.length() >= logFileMaxBytes) {
      await _rotateLogFile(current);
    }
    await current.create();
    await currentPlatformRuntime.restrictPermissions(
      current.path,
      directory: false,
    );
    return current.openWrite(mode: FileMode.append);
  }

  Future<void> _rotateLogIfNeeded() async {
    if (!_running || _configuredLogOutput != null) return;
    final current = WorkspacePaths(config.dataDirectory).logsFile;
    if (!await current.exists() || await current.length() < logFileMaxBytes) {
      return;
    }
    await _ownedLogOutput?.flush();
    await _ownedLogOutput?.close();
    _ownedLogOutput = null;
    await _rotateLogFile(current);
    await current.create();
    await currentPlatformRuntime.restrictPermissions(
      current.path,
      directory: false,
    );
    _ownedLogOutput = current.openWrite(mode: FileMode.append);
    _log.attach(_ownedLogOutput!);
  }

  Future<void> _rotateLogFile(File current) async {
    final previous = File('${current.path}.1');
    if (await previous.exists()) await previous.delete();
    await current.rename(previous.path);
    final length = await previous.length();
    if (length <= logFileMaxBytes) return;
    final handle = await previous.open();
    late final List<int> tail;
    try {
      await handle.setPosition(length - logFileMaxBytes);
      tail = await handle.read(logFileMaxBytes);
    } finally {
      await handle.close();
    }
    await previous.writeAsBytes(tail, flush: true);
  }
}

/// Source-compatibility alias for local fixtures and older integrations. New
/// runtime code should use [WorkspaceRuntime] to make service ownership clear.
typedef Workspace = WorkspaceRuntime;
