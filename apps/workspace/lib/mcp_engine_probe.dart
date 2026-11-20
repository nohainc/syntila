import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart'
    show McpServerLaunch;

import 'package:syntila_mcp_worker_store/syntila_mcp_worker_store.dart';

import 'mcp_registry.dart';
import 'mcp_service.dart';

/// Lists an MCP server's tools by running the Engine in its one-shot
/// `--mcp-probe` mode. The Service never starts an MCP server itself and never
/// calls a tool; the Engine applies the digest pin, limits and process-tree
/// cleanup.
class EngineMcpProbe implements McpProbePort {
  EngineMcpProbe({
    required this.locateEngine,
    required this.workingDirectory,
    this.timeout = const Duration(seconds: 45),
  });

  /// The Engine is located after the Workspace is built, so it is read lazily.
  /// Returns null when no Engine is available.
  final ({String executable, List<String> argumentsPrefix})? Function()
      locateEngine;
  final Directory workingDirectory;
  final Duration timeout;

  @override
  Future<List<Map<String, Object?>>> listTools(
    McpServerRecord server,
    McpServerLaunch launch, {
    bool requireWorkerProfile = false,
  }) =>
      _run(server.serverId, {
        'server': launch.toJson(),
        'commandSha256': server.commandSha256,
        'workingDirectory': workingDirectory.path,
        if (requireWorkerProfile) 'requireWorkerProfile': true,
      });

  @override
  Future<List<Map<String, Object?>>> listRemoteTools(
    McpServerRecord server,
    McpRemoteTarget remote, {
    bool requireWorkerProfile = false,
  }) =>
      _run(server.serverId, {
        'remote': {
          'endpoint': remote.endpoint.toString(),
          if (remote.bearerToken != null) 'bearerToken': remote.bearerToken,
          if (remote.insecureLoopback) 'allowInsecureLoopback': true,
        },
        if (requireWorkerProfile) 'requireWorkerProfile': true,
      });

  Future<List<Map<String, Object?>>> _run(
    String serverId,
    Map<String, Object?> request,
  ) async {
    try {
      return await McpEngineInspection(
        locateEngine: locateEngine,
        workingDirectory: workingDirectory,
        timeout: timeout,
      ).run(serverId, request);
    } on ExternalWorkerException catch (error) {
      throw McpPolicyException(error.code, error.message);
    }
  }
}
