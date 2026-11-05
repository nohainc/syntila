import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

/// A private, per-execution MCP configuration for an official provider CLI
/// (Profile slot `mcpConfigArguments`). The file uses the common
/// `{"mcpServers": {name: {command, args, env}}}` shape and lives in a fresh
/// owner-only directory that is deleted when the execution ends. The user's own
/// CLI configuration is never read or modified.
class McpConfigFile {
  McpConfigFile._(this._directory, this.path);

  final Directory _directory;
  final String path;

  static Future<McpConfigFile> write(List<McpServerLaunch> servers) async {
    final directory = await Directory.systemTemp.createTemp('syntila-mcp-');
    if (!Platform.isWindows) {
      await Process.run('chmod', ['700', directory.path]);
    }
    final file = File('${directory.path}${Platform.pathSeparator}mcp.json');
    await file.writeAsString(
      jsonEncode({
        'mcpServers': {
          for (final server in servers)
            server.name: {
              'command': server.command,
              'args': server.arguments,
              if (server.environment.isNotEmpty) 'env': server.environment,
            },
        },
      }),
      flush: true,
    );
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', file.path]);
    }
    return McpConfigFile._(directory, file.path);
  }

  Future<void> delete() async {
    try {
      await _directory.delete(recursive: true);
    } on FileSystemException {
      // Best effort; the directory is owner-only and in the temp area.
    }
  }
}
