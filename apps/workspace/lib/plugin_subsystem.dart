import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';

import 'local_worker_registry.dart';
import 'platform_runtime.dart';
import 'plugin_cloud.dart';
import 'plugin_engine_conformance.dart';
import 'plugin_registry.dart';
import 'plugin_service.dart';
import 'plugin_store.dart';
import 'plugin_worker_runtime.dart';
import 'secure_credentials.dart';
import 'workspace.dart' show WorkspaceConfig;
import 'workspace_configuration.dart';
import 'workspace_paths.dart';

/// The Service's whole plugin feature (ADR-027), built once from the running
/// Workspace and shared by the management IPC and the Worker runtime so both
/// see the same store and registry.
class PluginSubsystem {
  const PluginSubsystem({
    required this.store,
    required this.registry,
    required this.service,
    required this.runtime,
  });

  final PluginStore store;
  final PluginRegistry registry;

  /// Management commands (import, register, enable, ...).
  final WorkspacePluginService service;

  /// Readiness, pre-spawn verification and inventory for plugin Workers.
  final PluginWorkerRuntime runtime;

  /// [engineSupervisor] is read lazily because the Engine is located after
  /// this is built. [afterWorkerChange] runs a readiness check after a plugin
  /// Worker is created or re-enabled.
  static PluginSubsystem build({
    required WorkspaceConfig config,
    required SecureCredentialStore credentialStore,
    required CliWorkerEngineSupervisor? Function() engineSupervisor,
    required LocalWorkerRegistry? workers,
    Future<void> Function(String pluginRef)? afterWorkerChange,
    PlatformRuntime? platform,
  }) {
    final paths = WorkspacePaths(config.dataDirectory);
    final plugins = paths.pluginsDirectory;
    final home = (platform ?? currentPlatformRuntime).homeDirectory;
    final store = PluginStore(
      root: plugins,
      forbiddenRoots: [
        paths.applicationDataRoot.path,
        config.dataDirectory.path,
        for (final name in const [
          '.ssh',
          '.aws',
          '.gnupg',
          '.codex',
          '.claude',
          '.gemini',
          '.config',
        ])
          '$home${Platform.pathSeparator}$name',
      ],
    );
    final registry = PluginRegistry(File('${plugins.path}/registry.json'));
    Directory engineState(String pluginId) =>
        Directory('${plugins.path}/engine-state/$pluginId');
    final cloudUri = config.cloudUri;
    final runtime = PluginWorkerRuntime(
      store: store,
      registry: registry,
      engineStateDirectory: engineState,
      probe: ({
        required executor,
        required workerTypeId,
        required stateDirectory,
        required mode,
      }) {
        final supervisor = engineSupervisor();
        if (supervisor == null) {
          throw StateError('The Worker Engine is not available');
        }
        return supervisor.probe(
          null,
          pluginExecutor: executor,
          pluginWorkerTypeId: workerTypeId,
          stateDirectory: stateDirectory,
          mode: mode,
          timeout: const Duration(seconds: 25),
        );
      },
    );
    final service = WorkspacePluginService(
      store: store,
      registry: registry,
      cloud: HttpPluginCloud(
        cloudUrl: cloudUri == null
            ? ''
            : WorkspaceConfigurationResolver.cloudHttpOrigin(cloudUri),
        credentialStore: credentialStore,
        workspaceId: config.workspaceId,
      ),
      conformance: _LazyConformance(
        () => engineSupervisor(),
        store,
        engineState,
      ),
      workerHost: workers == null
          ? const _NoWorkers()
          : LocalPluginWorkerHost(
              workers: workers,
              afterChange: afterWorkerChange,
            ),
      activeAssignments: (pluginRef) async {
        final supervisor = engineSupervisor();
        if (supervisor == null || workers == null) return 0;
        var count = 0;
        for (final worker in await workers.list()) {
          if (worker.workerTypeId != pluginRef) continue;
          count += supervisor.activeAssignmentCountFor(worker.id) +
              supervisor.queuedAssignmentCountFor(worker.id);
        }
        return count;
      },
    );
    return PluginSubsystem(
      store: store,
      registry: registry,
      service: service,
      runtime: runtime,
    );
  }
}

class _NoWorkers implements PluginWorkerHost {
  const _NoWorkers();
  @override
  Future<void> activate({
    required String pluginRef,
    required String pluginId,
    required String displayName,
  }) async {}
  @override
  Future<void> deactivate(String pluginRef) async {}
  @override
  Future<void> remove(String pluginRef) async {}
}

class _LazyConformance implements PluginConformancePort {
  _LazyConformance(this._supervisor, this._store, this._engineState);

  final CliWorkerEngineSupervisor? Function() _supervisor;
  final PluginStore _store;
  final Directory Function(String pluginId) _engineState;

  @override
  Future<Map<String, Object?>> run(
    InstalledPlugin plugin, {
    required String workerTypeId,
    required bool declaresResume,
    required Map<String, Object?> declaredCapabilities,
    void Function(String progress)? onProgress,
  }) {
    final supervisor = _supervisor();
    if (supervisor == null) {
      throw const PluginServiceException(
        'plugin_conformance_failed',
        'The Worker Engine is not available on this Workspace.',
      );
    }
    return EnginePluginConformance(
      supervisor: supervisor,
      store: _store,
      engineStateDirectory: _engineState,
    ).run(
      plugin,
      workerTypeId: workerTypeId,
      declaresResume: declaresResume,
      declaredCapabilities: declaredCapabilities,
      onProgress: onProgress,
    );
  }
}
