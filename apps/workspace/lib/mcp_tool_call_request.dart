import 'dart:convert';

/// Internal v1 payload. Parsing does not authorize a call or advertise a
/// Cloud transport capability; assignment policy and local consent still apply.
class McpToolCallRequest {
  McpToolCallRequest._(this.taskId, this.dispatchKey, this.serverId, this.tool,
      this.toolDefinitionHash, this.arguments, this.timeoutMs);

  final String taskId;
  final String dispatchKey;
  final String serverId;
  final String tool;
  final String toolDefinitionHash;
  final Map<String, Object?> arguments;
  final int timeoutMs;

  static const maxArgumentsBytes = 64 * 1024;

  factory McpToolCallRequest.fromJson(Map<String, Object?> json) {
    const keys = {
      'schemaVersion',
      'taskId',
      'dispatchKey',
      'serverId',
      'tool',
      'toolDefinitionHash',
      'arguments',
      'timeoutMs',
    };
    final task = json['taskId'];
    final dispatch = json['dispatchKey'];
    final server = json['serverId'];
    final tool = json['tool'];
    final hash = json['toolDefinitionHash'];
    final arguments = json['arguments'];
    final timeout = json['timeoutMs'];
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        json['schemaVersion'] is! int ||
        json['schemaVersion'] != 1 ||
        task is! String ||
        task.isEmpty ||
        task.length > 900 ||
        dispatch is! String ||
        dispatch != 'mcp-tool-v1:$task' ||
        server is! String ||
        !RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(server) ||
        tool is! String ||
        tool.isEmpty ||
        tool.length > 128 ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        arguments is! Map ||
        arguments.keys.any((key) => key is! String) ||
        timeout is! int ||
        timeout < 1 ||
        timeout > 1800000) {
      throw const FormatException('Invalid MCP tool-call request');
    }
    try {
      final encoded = jsonEncode(arguments);
      if (utf8.encode(encoded).length > maxArgumentsBytes) {
        throw const FormatException('MCP tool arguments too large');
      }
      // Deep copy and normalize so later caller mutations cannot change the
      // admitted arguments between validation and dispatch.
      final copy = _freezeJson(jsonDecode(encoded)) as Map<String, Object?>;
      return McpToolCallRequest._(
          task, dispatch, server, tool, hash, copy, timeout);
    } on Object {
      throw const FormatException('Invalid MCP tool arguments');
    }
  }
}

Object? _freezeJson(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freezeJson(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeJson));
  }
  return value;
}
