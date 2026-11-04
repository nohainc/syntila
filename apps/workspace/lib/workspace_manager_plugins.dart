import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';

import 'local_worker_registry.dart';
import 'platform_runtime.dart';
import 'plugin_cloud.dart';
import 'plugin_engine_conformance.dart';
import 'plugin_entitlement.dart';
import 'plugin_registry.dart';
import 'plugin_service.dart';
import 'plugin_store.dart';
import 'release_trust_roots.dart';
import 'secure_credentials.dart';
import 'workspace_configuration.dart';
import 'workspace_manager_ipc.dart';
import 'workspace.dart' show WorkspaceConfig;
import 'workspace_paths.dart';

/// Builds the plugin service from the running Workspace's own state. The
/// Service owns every plugin operation; the CLI is an IPC client only.
WorkspacePluginService buildWorkspacePluginService({
  required WorkspaceConfig config,
  required SecureCredentialStore credentialStore,
  required CliWorkerEngineSupervisor? engineSupervisor,
  required LocalWorkerRegistry? localWorkers,
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
  final cloudUri = config.cloudUri;
  return WorkspacePluginService(
    store: store,
    registry: PluginRegistry(File('${plugins.path}/registry.json')),
    entitlement: PluginEntitlementStore(
      file: File('${plugins.path}/entitlement.json'),
      verifier: PluginLeaseVerifier(workspaceEntitlementTrustKeys()),
      workspaceId: config.workspaceId ?? '',
      installationId: config.installationId ?? '',
    ),
    cloud: HttpPluginCloud(
      cloudUrl: cloudUri == null
          ? ''
          : WorkspaceConfigurationResolver.cloudHttpOrigin(cloudUri),
      credentialStore: credentialStore,
      workspaceId: config.workspaceId,
      workspaceRuntimeId: config.workspaceRuntimeId,
      runtimeToken: config.authToken,
    ),
    conformance: engineSupervisor == null
        ? const _UnavailableConformance()
        : EnginePluginConformance(
            supervisor: engineSupervisor,
            store: store,
            engineStateDirectory: (pluginId) =>
                Directory('${plugins.path}/engine-state/$pluginId'),
          ),
    activeAssignments: (pluginRef) async {
      final supervisor = engineSupervisor;
      if (supervisor == null || localWorkers == null) return 0;
      var count = 0;
      for (final worker in await localWorkers.list()) {
        if (worker.workerTypeId != pluginRef) continue;
        count += supervisor.activeAssignmentCountFor(worker.id) +
            supervisor.queuedAssignmentCountFor(worker.id);
      }
      return count;
    },
  );
}

class _UnavailableConformance implements PluginConformancePort {
  const _UnavailableConformance();

  @override
  Future<Map<String, Object?>> run(
    InstalledPlugin plugin, {
    required String workerTypeId,
    required bool declaresResume,
    required Map<String, Object?> declaredCapabilities,
    void Function(String progress)? onProgress,
  }) =>
      throw const PluginServiceException(
        'plugin_conformance_failed',
        'The Worker Engine is not available on this Workspace.',
      );
}

/// Translates `plugins.*` IPC commands into [WorkspacePluginService] calls and
/// service errors into stable IPC error codes.
class WorkspacePluginCommands {
  WorkspacePluginCommands(this.service, {required this.publish});

  final WorkspacePluginService service;

  /// Emits an event to subscribed IPC clients.
  final void Function(Map<String, Object?> event) publish;

  static final _idPattern = RegExp(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$');
  static final _versionPattern = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
  );

  static bool handles(String command) => command.startsWith('plugins.');

  Future<Object?> handle(String command, Map<String, Object?> payload) async {
    try {
      return await _handle(command, payload);
    } on PluginServiceException catch (error) {
      final details = error.details;
      final suffix = details is List && details.isNotEmpty
          ? ' ${details.take(5).join('; ')}'
          : '';
      throw WorkspaceManagerProtocolException(
        error.code,
        '${error.message}$suffix',
      );
    }
  }

  String _id(Map<String, Object?> payload) {
    final value = payload['pluginId'];
    if (value is! String || value.length > 48 || !_idPattern.hasMatch(value)) {
      throw const WorkspaceManagerProtocolException(
        'invalid_request',
        'pluginId must be a lowercase plugin ID.',
      );
    }
    return value;
  }

  String? _version(Map<String, Object?> payload) {
    final value = payload['version'];
    if (value == null) return null;
    if (value is! String || !_versionPattern.hasMatch(value)) {
      throw const WorkspaceManagerProtocolException(
        'invalid_request',
        'version must be MAJOR.MINOR.PATCH.',
      );
    }
    return value;
  }

  String? _hash(Map<String, Object?> payload) {
    final value = payload['acceptHash'];
    if (value == null) return null;
    if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw const WorkspaceManagerProtocolException(
        'invalid_request',
        'acceptHash must be a SHA-256 hex digest.',
      );
    }
    return value;
  }

  String _absolutePath(Map<String, Object?> payload, String key) {
    final value = payload[key];
    if (value is! String ||
        value.isEmpty ||
        value.length > 4096 ||
        value.contains('\u0000') ||
        !File(value).isAbsolute) {
      throw WorkspaceManagerProtocolException(
        'invalid_request',
        '$key must be an absolute path.',
      );
    }
    return value;
  }

  Future<Object?> _handle(String command, Map<String, Object?> payload) {
    switch (command) {
      case 'plugins.list':
        return service.list();
      case 'plugins.show':
        return service.show(_id(payload), _version(payload));
      case 'plugins.import':
        return service.import(_absolutePath(payload, 'path'));
      case 'plugins.validate':
        return service.validate(_id(payload), _version(payload));
      case 'plugins.test':
        final id = _id(payload);
        return service.test(
          id,
          version: _version(payload),
          onProgress: (message) => publish({
            'name': 'plugin.testProgress',
            'pluginId': id,
            'message': message,
          }),
        );
      case 'plugins.register':
        return service.register(
          _id(payload),
          version: _version(payload),
          acceptHash: _hash(payload),
        );
      case 'plugins.enable':
        return service.enable(
          _id(payload),
          version: _version(payload),
          acceptHash: _hash(payload),
          shareable: payload['shareable'] == true,
        );
      case 'plugins.disable':
        return service.disable(_id(payload));
      case 'plugins.remove':
        return service.remove(_id(payload));
      case 'plugins.export':
        return service.export(
          _id(payload),
          _absolutePath(payload, 'outputPath'),
          version: _version(payload),
        );
      case 'plugins.entitlement':
        return service.entitlementStatus();
      default:
        throw WorkspaceManagerProtocolException(
          'unsupported_command',
          'Unsupported Workspace Manager command: $command',
        );
    }
  }
}
