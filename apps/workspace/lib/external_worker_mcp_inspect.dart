import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart'
    show McpServerLaunch;

import 'mcp_engine_probe.dart';
import 'mcp_registry.dart';
import 'mcp_service.dart';
import 'external_worker_service.dart';
import 'external_worker_store.dart';

/// Lists an installed MCP Worker's tools through the Engine's one-shot
/// `--mcp-probe` mode, requiring the Syntila Worker profile marker. The Service
/// never starts the server itself, and nothing is called.
class EngineExternalWorkerMcpInspect implements ExternalWorkerMcpInspectPort {
  EngineExternalWorkerMcpInspect(this._probe,
      {Map<String, String>? environment})
      : _environment = environment ?? Platform.environment;

  final EngineMcpProbe _probe;
  final Map<String, String> _environment;

  @override
  Future<List<Map<String, Object?>>> listWorkerTools(
    InstalledExternalWorker plugin,
  ) async {
    final access = Map<String, Object?>.from(
      plugin.manifest.raw['access'] as Map,
    );
    final names = List<String>.from(access['env'] as List);
    final launch = McpServerLaunch(
      name: plugin.pluginId,
      command: plugin.executablePath,
      arguments: plugin.artifact.args,
      environment: {
        for (final name in names)
          if (_environment[name] != null) name: _environment[name]!,
      },
    );
    final record = McpServerRecord(
      serverId: plugin.pluginId,
      displayName: plugin.manifest.displayName,
      command: plugin.executablePath,
      commandSha256: plugin.artifactDigest,
      arguments: plugin.artifact.args,
      environmentNames: names,
    );
    try {
      return await _probe.listTools(
        record,
        launch,
        requireWorkerProfile: true,
      );
    } on McpPolicyException catch (error) {
      throw ExternalWorkerException(error.code, error.message);
    }
  }
}
