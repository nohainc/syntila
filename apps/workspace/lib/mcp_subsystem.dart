import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';

import 'mcp_engine_probe.dart';
import 'mcp_registry.dart';
import 'mcp_service.dart';
import 'workspace.dart' show WorkspaceConfig;
import 'workspace_paths.dart';

/// MCP server management (ADR-028) built over the Workspace's data directory
/// and the supervised Engine, which runs every probe.
class McpSubsystem {
  const McpSubsystem({required this.service});

  final McpService service;

  /// [engineSupervisor] is read lazily because the Engine is located after
  /// this is built.
  static McpSubsystem build({
    required WorkspaceConfig config,
    required CliWorkerEngineSupervisor? Function() engineSupervisor,
  }) {
    final directory = WorkspacePaths(config.dataDirectory).mcpDirectory;
    return McpSubsystem(
      service: McpService(
        McpRegistry(File('${directory.path}/servers.json')),
        EngineMcpProbe(
          workingDirectory: Directory('${directory.path}/probe'),
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
    );
  }
}
