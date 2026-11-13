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

  static const _prefix = 'syntila-mcp-';

  /// Removes private config directories an Engine left behind when it was
  /// killed before its `finally` ran (a SIGKILL or power loss). Only
  /// directories this class creates (the prefix) and that are older than
  /// [olderThan] are touched, so a live execution's directory is never removed.
  static Future<int> sweepStale({
    Duration olderThan = const Duration(hours: 24),
    Directory? root,
  }) async {
    var removed = 0;
    try {
      final base = root ?? Directory.systemTemp;
      final cutoff = DateTime.now().subtract(olderThan);
      await for (final entry in base.list(followLinks: false)) {
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (entry is! Directory || !name.startsWith(_prefix)) continue;
        try {
          if ((await entry.stat()).modified.isAfter(cutoff)) continue;
          await entry.delete(recursive: true);
          removed++;
        } on FileSystemException {
          // Best effort.
        }
      }
    } on FileSystemException {
      // Best effort.
    }
    return removed;
  }

  static Future<McpConfigFile> write(List<McpServerLaunch> servers) async {
    await sweepStale();
    final directory = await Directory.systemTemp.createTemp(_prefix);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['700', directory.path]);
    }
    final file = File('${directory.path}${Platform.pathSeparator}mcp.json');
    await file.writeAsString(
      jsonEncode({
        'mcpServers': {
          for (final server in servers)
            server.name: server.isRemote
                ? {
                    'type': 'http',
                    'url': server.url,
                    if (server.headers.isNotEmpty) 'headers': server.headers,
                  }
                : {
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

/// The same per-execution servers as an inline TOML table, for provider CLIs
/// whose MCP configuration is a `-c mcp_servers=<table>` override instead of a
/// file (Profile placeholder `{{mcpServersToml}}`).
///
/// Secrets never go on the command line, where other local users could read
/// them: each server lists only the NAMES of its environment variables
/// (`env_vars`), and the values are returned in [environment] for the Engine to
/// put in the provider process environment. Two servers that need the same
/// variable with different values cannot share one provider environment, so
/// that is refused rather than silently resolved.
class McpInlineToml {
  McpInlineToml._(this.servers, this.environment);

  final String servers;
  final Map<String, String> environment;

  static McpInlineToml build(List<McpServerLaunch> launches) {
    final environment = <String, String>{};
    final entries = <String>[];
    for (final server in launches) {
      if (server.isRemote) {
        final fields = <String>[
          'url=${_string(server.url!)}',
          'default_tools_approval_mode="approve"',
        ];
        final auth = server.headers['Authorization'] ??
            server.headers['authorization'];
        if (auth != null && auth.startsWith('Bearer ')) {
          final tokenVar =
              'SYNTILA_MCP_TOKEN_${server.name.toUpperCase().replaceAll('-', '_')}';
          environment[tokenVar] = auth.substring('Bearer '.length);
          fields.add('bearer_token_env_var=${_string(tokenVar)}');
        }
        entries.add('${_string(server.name)}={${fields.join(',')}}');
        continue;
      }
      for (final entry in server.environment.entries) {
        final existing = environment[entry.key];
        if (existing != null && existing != entry.value) {
          throw FormatException(
            'MCP servers define conflicting values for ${entry.key}',
          );
        }
        environment[entry.key] = entry.value;
      }
      final fields = <String>[
        'command=${_string(server.command!)}',
        // Selecting the server on the Step is the approval; the CLI's own
        // approval policy is `never` in non-interactive runs, which would
        // otherwise refuse every call.
        'default_tools_approval_mode="approve"',
        if (server.arguments.isNotEmpty)
          'args=[${server.arguments.map(_string).join(',')}]',
        if (server.environment.isNotEmpty)
          'env_vars=[${(server.environment.keys.toList()..sort()).map(_string).join(',')}]',
      ];
      entries.add('${_string(server.name)}={${fields.join(',')}}');
    }
    return McpInlineToml._('{${entries.join(',')}}', environment);
  }

  /// A TOML basic string: quotes, backslashes and control characters escaped.
  static String _string(String value) {
    final out = StringBuffer('"');
    for (final unit in value.runes) {
      switch (unit) {
        case 0x22:
          out.write(r'\"');
        case 0x5c:
          out.write(r'\\');
        case 0x08:
          out.write(r'\b');
        case 0x09:
          out.write(r'\t');
        case 0x0a:
          out.write(r'\n');
        case 0x0c:
          out.write(r'\f');
        case 0x0d:
          out.write(r'\r');
        default:
          if (unit < 0x20 || unit == 0x7f) {
            out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
          } else {
            out.writeCharCode(unit);
          }
      }
    }
    out.write('"');
    return out.toString();
  }
}
