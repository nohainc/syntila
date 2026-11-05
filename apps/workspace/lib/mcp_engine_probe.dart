import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart'
    show McpServerLaunch;

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

  static const _inherited = <String>{
    'PATH',
    'HOME',
    'LANG',
    'TMPDIR',
    'TEMP',
    'TMP',
    'SYSTEMROOT',
    'USERPROFILE',
    'APPDATA',
    'LOCALAPPDATA',
  };

  @override
  Future<List<Map<String, Object?>>> listTools(
    McpServerRecord server,
    McpServerLaunch launch,
  ) async {
    final engine = locateEngine();
    if (engine == null) {
      throw const McpPolicyException(
        'mcp_probe_failed',
        'The Worker Engine is not available.',
      );
    }
    await workingDirectory.create(recursive: true);
    final process = await Process.start(
      engine.executable,
      [...engine.argumentsPrefix, '--mcp-probe'],
      workingDirectory: workingDirectory.path,
      environment: {
        for (final e in Platform.environment.entries)
          if (_inherited.contains(e.key)) e.key: e.value,
      },
      includeParentEnvironment: false,
    );
    unawaited(process.stderr.drain<void>().catchError((_) {}));
    process.stdin.writeln(
      jsonEncode({
        'server': launch.toJson(),
        'commandSha256': server.commandSha256,
        'workingDirectory': workingDirectory.path,
      }),
    );
    await process.stdin.flush();
    await process.stdin.close();
    final String line;
    try {
      line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(timeout);
    } on Object {
      process.kill(ProcessSignal.sigkill);
      throw McpPolicyException(
        'mcp_probe_failed',
        'The MCP server "${server.serverId}" could not be inspected.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      throw const McpPolicyException(
        'mcp_probe_failed',
        'The Engine returned an unreadable probe result.',
      );
    }
    if (decoded is! Map || decoded['ok'] != true) {
      final code = decoded is Map ? '${decoded['code']}' : 'mcp_probe_failed';
      final message =
          decoded is Map ? '${decoded['message']}' : 'Probe failed.';
      throw McpPolicyException(code, message);
    }
    return [
      for (final tool in decoded['tools'] as List)
        Map<String, Object?>.from(tool as Map),
    ];
  }
}
