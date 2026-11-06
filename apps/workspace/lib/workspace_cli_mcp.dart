part of 'workspace_cli.dart';

/// Rendering for `syntila mcp ...`. Like plugins, the CLI never starts a
/// server and never reads one's files; it prints what the Service returned. A
/// consent document is shown in full, including every tool definition, and
/// accepting it means rerunning the command with `--accept <documentHash>`.
extension _McpOutput on WorkspaceCli {
  bool _printMcpResult(String command, Object? result) {
    if (result is! Map) return false;
    try {
      return _renderMcpResult(command, result);
    } on Object {
      return false;
    }
  }

  bool _renderMcpResult(String command, Map result) {
    switch (command) {
      case 'mcp.list':
        final servers = (result['servers'] as List).whereType<Map>();
        if (servers.isEmpty) out.writeln('No MCP servers.');
        final bindings = result['bindings'] is Map
            ? Map<String, Object?>.from(result['bindings'] as Map)
            : const <String, Object?>{};
        for (final server in servers) {
          final state = server['enabled'] == true
              ? 'enabled'
              : server['consented'] == true
                  ? 'consented, disabled'
                  : 'not consented';
          out.writeln(
            '${server['serverId']}  ${server['displayName']}  ($state)  '
            '${server['remote'] == true ? 'remote ${server['endpoint']}  ' : ''}'
            'tools: ${(server['tools'] as List).join(', ')}',
          );
        }
        for (final entry in bindings.entries) {
          out.writeln(
            'Worker ${entry.key} may use: ${(entry.value as List).join(', ')}',
          );
        }
        return true;
      case 'mcp.bind':
        out.writeln(
          '${result['workerTypeId']} may now receive ${result['serverId']} '
          'when it is consented and enabled.',
        );
        return true;
      case 'mcp.unbind':
        out.writeln(
          '${result['workerTypeId']} no longer receives ${result['serverId']}.',
        );
        return true;
      case 'mcp.add':
      case 'mcp.addRemote':
        out.writeln('Added ${result['serverId']}.');
        out.writeln('Next: ${result['next']}');
        return true;
      case 'mcp.consent':
        if (result['consentRequired'] == true) {
          _printMcpConsent(result);
        } else {
          out.writeln('Consent recorded for ${result['serverId']}.');
          out.writeln('Next: syntila mcp enable ${result['serverId']}');
        }
        return true;
      case 'mcp.enable':
        out.writeln('Enabled ${result['serverId']}.');
        return true;
      case 'mcp.disable':
        out.writeln('Disabled ${result['serverId']}.');
        return true;
      case 'mcp.remove':
        out.writeln('Removed ${result['serverId']}.');
        return true;
    }
    return false;
  }

  void _printMcpConsent(Map result) {
    final doc = Map<String, Object?>.from(result['document'] as Map);
    out.writeln('Review before you consent to this MCP server');
    out.writeln('  Server:     ${doc['serverId']}');
    if (doc['transport'] == 'remote') {
      out.writeln('  Remote:     ${doc['endpoint']}');
      out.writeln(
        '  Token:      ${doc['tokenEnvironmentName'] ?? 'none (no credential is sent)'}'
        '${doc['tokenEnvironmentName'] == null ? '' : ' (read from this environment variable when used)'}',
      );
      out.writeln(
        'Everything you send this server leaves this computer. Its tools '
        'run on someone else\'s machine.',
      );
    } else {
      out.writeln('  Command:    ${doc['command']}');
      out.writeln('  Digest:     ${doc['commandSha256']}');
      out.writeln('  Arguments:  ${(doc['arguments'] as List).join(' ')}');
      out.writeln(
        '  Environment names it may read: '
        '${(doc['environmentNames'] as List).join(', ')}',
      );
    }
    final tools = (doc['tools'] as List).whereType<Map>().toList();
    out.writeln('  Tools (${tools.length}):');
    for (final tool in tools) {
      out.writeln('    ${tool['name']}: ${tool['description'] ?? ''}');
    }
    out.writeln(
      'Tool descriptions come from the server and are untrusted. If any tool '
      'changes later, calls to it are blocked until you consent again.',
    );
    out.writeln('Document hash: ${result['documentHash']}');
    out.writeln(
      'To accept, rerun with --accept ${result['documentHash']}',
    );
  }
}
