import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart'
    show McpServerLaunch;

import 'mcp_host.dart';
import 'plugin_host.dart';

/// One-shot `--mcp-probe` mode: lists a server's tools through the Engine's
/// [McpHost] so the Service never starts an MCP server itself.
///
/// stdin: one JSON line
/// `{"server": <McpServerLaunch>, "commandSha256": "<hex>", "workingDirectory": "<abs>"}`
/// plus an optional `"requireWorkerProfile": true` that makes a server without
/// the Syntila Worker profile marker fail.
/// stdout: exactly one JSON line, `{"ok":true,"tools":[...]}` or
/// `{"ok":false,"code":"...","message":"..."}`. Nothing else is written to
/// stdout. The probe never calls a tool.
const mcpProbeFlag = '--mcp-probe';
const mcpProbeDeadline = Duration(seconds: 30);

Future<Map<String, Object?>> runMcpProbe(
  Map<String, Object?> request, {
  PluginHost? pluginHost,
  Duration deadline = mcpProbeDeadline,
}) async {
  final plugins = pluginHost ?? PluginHost();
  final host = McpHost(pluginHost: plugins);
  final data = await Directory.systemTemp.createTemp('syntila-mcp-probe-');
  try {
    final server = McpServerLaunch.fromJson(
      Map<String, Object?>.from(request['server'] as Map),
    );
    final sha = request['commandSha256'];
    final cwd = request['workingDirectory'];
    if (sha is! String || cwd is! String || !Directory(cwd).isAbsolute) {
      throw const FormatException('invalid probe request');
    }
    final spec = McpServerSpec(
      serverId: server.name,
      workspaceId: 'probe',
      requireWorkerProfile: request['requireWorkerProfile'] == true,
      launch: PluginLaunch(
        executable: server.command,
        arguments: server.arguments,
        artifactSha256: sha,
        pluginId: server.name,
        version: '0',
        dataDirectory: data.path,
        workingDirectory: cwd,
        environment: {...PluginHost.buildEnvironment(), ...server.environment},
        hostVersion: '0',
      ),
    );
    final lease = await host.acquire(spec).timeout(deadline);
    final tools = lease.tools;
    lease.release();
    return {'ok': true, 'tools': tools};
  } on TimeoutException {
    return {
      'ok': false,
      'code': McpFailure.timeout,
      'message': 'The MCP server did not answer in time.',
    };
  } on McpException catch (error) {
    return {'ok': false, 'code': error.code, 'message': error.message};
  } on PluginLaunchException catch (error) {
    return {'ok': false, 'code': error.code, 'message': error.message};
  } on FormatException catch (error) {
    return {'ok': false, 'code': 'invalid_request', 'message': error.message};
  } finally {
    await host.closeAll();
    try {
      await data.delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  }
}

/// Entry point for `--mcp-probe`.
Future<void> runMcpProbeMode() async {
  final line = await stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 10));
  Map<String, Object?> result;
  try {
    result = await runMcpProbe(
      Map<String, Object?>.from(jsonDecode(line) as Map),
    );
  } on Object {
    result = {
      'ok': false,
      'code': 'invalid_request',
      'message': 'Malformed probe request.',
    };
  }
  stdout.writeln(jsonEncode(result));
  await stdout.flush();
}
