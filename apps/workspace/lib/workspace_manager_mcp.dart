import 'dart:io';

import 'mcp_service.dart';
import 'workspace_manager_ipc.dart';

/// Translates `mcp.*` IPC commands into [McpService] calls and policy errors
/// into stable IPC error codes. Like `plugins.*`, the CLI only sends requests
/// and prints results: it never starts a server.
class WorkspaceMcpCommands {
  WorkspaceMcpCommands(this.service);

  final McpService service;

  static final _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  static bool handles(String command) => command.startsWith('mcp.');

  Future<Object?> handle(String command, Map<String, Object?> payload) async {
    try {
      return await _handle(command, payload);
    } on McpPolicyException catch (error) {
      throw WorkspaceManagerProtocolException(error.code, error.message);
    }
  }

  String _id(Map<String, Object?> payload) {
    final value = payload['serverId'];
    if (value is! String || !_idPattern.hasMatch(value)) {
      throw const WorkspaceManagerProtocolException(
        'invalid_request',
        'serverId must be a lowercase server ID.',
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

  List<String> _strings(Map<String, Object?> payload, String key) {
    final value = payload[key] ?? const <Object?>[];
    if (value is! List || value.any((item) => item is! String)) {
      throw WorkspaceManagerProtocolException(
        'invalid_request',
        '$key must be a list of strings.',
      );
    }
    return List<String>.from(value);
  }

  Future<Object?> _handle(String command, Map<String, Object?> payload) async {
    switch (command) {
      case 'mcp.list':
        return {'servers': service.list()};
      case 'mcp.add':
        final command = payload['command'];
        final name = payload['displayName'];
        if (command is! String ||
            command.length > 4096 ||
            !File(command).isAbsolute ||
            name is! String) {
          throw const WorkspaceManagerProtocolException(
            'invalid_request',
            'command must be an absolute path and displayName a string.',
          );
        }
        return service.add(
          serverId: _id(payload),
          displayName: name,
          command: command,
          arguments: _strings(payload, 'arguments'),
          environmentNames: _strings(payload, 'environmentNames'),
        );
      case 'mcp.consent':
        return service.consent(_id(payload), acceptHash: _hash(payload));
      case 'mcp.enable':
        return service.enable(_id(payload));
      case 'mcp.disable':
        return service.disable(_id(payload));
      case 'mcp.remove':
        return service.remove(_id(payload));
      default:
        throw WorkspaceManagerProtocolException(
          'unsupported_command',
          'Unsupported Workspace Manager command: $command',
        );
    }
  }
}
