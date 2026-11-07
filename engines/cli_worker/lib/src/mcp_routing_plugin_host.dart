import 'dart:async';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';

import 'mcp_host.dart';
import 'mcp_worker_runner.dart';
import 'plugin_host.dart';

/// The plugin-mode Engine's host: NDJSON plugins run exactly as before; a
/// launch with [PluginLaunch.mcpToolPins] runs as an MCP Worker through
/// [McpWorkerRunner]. Keeping the dispatch behind the same `run` signature means
/// the Engine's probe, model discovery, continuity, redaction and failure
/// mapping apply to both executors unchanged.
class McpRoutingPluginHost extends PluginHost {
  McpRoutingPluginHost({super.supervisor, super.resourceLimits}) {
    _mcp = McpHost(pluginHost: this);
    _runner = McpWorkerRunner(_mcp);
  }

  late final McpHost _mcp;
  late final McpWorkerRunner _runner;

  /// Stops every warm MCP server. The Engine calls this when its input ends so
  /// no server process or idle timer keeps the Engine alive.
  Future<void> close() => _mcp.closeAll();

  @override
  Future<PluginRunOutcome> run(
    PluginLaunch launch,
    PluginRunRequest request, {
    void Function(PluginFrame frame)? onFrame,
    void Function()? onWorkStarted,
    Future<void>? cancel,
  }) {
    final pins = launch.mcpToolPins;
    if (pins == null) {
      return Future.value(
        const PluginRunFailure(
          code: PluginHostFailure.protocolUnsupported,
          message:
              'NDJSON plugin protocol is unsupported; only kind: "mcp" is supported.',
        ),
      );
    }
    final spec = McpServerSpec(
      serverId: launch.pluginId,
      workspaceId: 'engine',
      launch: launch,
      requireWorkerProfile: true,
      pins: ToolPins(pins),
    );
    if (request.discoverModels) return _runner.models(spec);
    final probe = request.probeMode;
    if (probe != null) return _runner.probe(spec, probe);
    onWorkStarted?.call();
    return _runner.run(
      spec,
      request,
      cancel: cancel,
      workingDirectory: launch.workingDirectory,
      onProgress: onFrame == null
          ? null
          : (percentage, message) => onFrame(
              PluginFrame('progress', {
                'type': 'progress',
                'id': request.executeId,
                if (percentage != null) 'percent': percentage,
                'message': message,
              }),
            ),
    );
  }
}
