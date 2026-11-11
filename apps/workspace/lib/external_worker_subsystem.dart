import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';

import 'local_worker_registry.dart';
import 'mcp_engine_probe.dart';
import 'external_worker_mcp_inspect.dart';
import 'platform_runtime.dart';
import 'external_worker_cloud.dart';
import 'external_worker_registry.dart';
import 'external_worker_service.dart';
import 'external_worker_store.dart';
import 'external_worker_runtime.dart';
import 'secure_credentials.dart';
import 'workspace.dart' show WorkspaceConfig;
import 'workspace_configuration.dart';
import 'workspace_paths.dart';

/// The Service's whole plugin feature (ADR-027), built once from the running
/// Workspace and shared by the management IPC and the Worker runtime so both
/// see the same store and registry.
class ExternalWorkerSubsystem {
  const ExternalWorkerSubsystem({
    required this.store,
    required this.registry,
    required this.service,
    required this.runtime,
  });

  final ExternalWorkerStore store;
  final ExternalWorkerRegistry registry;

  /// Management commands (import, register, enable, ...).
  final ExternalWorkerService service;

  /// Readiness, pre-spawn verification and inventory for plugin Workers.
  final ExternalWorkerRuntime runtime;

  /// [engineSupervisor] is read lazily because the Engine is located after
  /// this is built. [afterWorkerChange] runs a readiness check after a plugin
  /// Worker is created or re-enabled.
  static ExternalWorkerSubsystem build({
    required WorkspaceConfig config,
    required SecureCredentialStore credentialStore,
    required CliWorkerEngineSupervisor? Function() engineSupervisor,
    required LocalWorkerRegistry? workers,
    Future<void> Function(String pluginRef)? afterWorkerChange,
    PlatformRuntime? platform,
  }) {
    final paths = WorkspacePaths(config.dataDirectory);
    final plugins = paths.externalWorkersDirectory;
    final home = (platform ?? currentPlatformRuntime).homeDirectory;
    final store = ExternalWorkerStore(
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
    final registry =
        ExternalWorkerRegistry(File('${plugins.path}/registry.json'));
    Directory engineState(String pluginId) =>
        Directory('${plugins.path}/engine-state/$pluginId');
    final cloudUri = config.cloudUri;
    final runtime = ExternalWorkerRuntime(
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
    final service = ExternalWorkerService(
      store: store,
      registry: registry,
      cloud: HttpExternalWorkerCloud(
        cloudUrl: cloudUri == null
            ? ''
            : WorkspaceConfigurationResolver.cloudHttpOrigin(cloudUri),
        credentialStore: credentialStore,
        workspaceId: config.workspaceId,
      ),
      mcpInspect: EngineExternalWorkerMcpInspect(
        EngineMcpProbe(
          workingDirectory: Directory('${plugins.path}/mcp-probe'),
          locateEngine: () {
            final supervisor = engineSupervisor();
            if (supervisor == null) return null;
            return (
              executable: supervisor.engineExecutable,
              argumentsPrefix: supervisor.engineArgumentsPrefix,
            );
          },
        ),
      ),
      workerHost: workers == null
          ? const _NoWorkers()
          : LocalExternalWorkerHost(
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
    return ExternalWorkerSubsystem(
      store: store,
      registry: registry,
      service: service,
      runtime: runtime,
    );
  }
}

class _NoWorkers implements ExternalWorkerHost {
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
