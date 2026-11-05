/// Limits and supported versions from `MCP_HOST_V1.md`.
abstract final class McpLimits {
  /// Newest first. The client proposes the first entry and accepts any listed
  /// version the server answers with; anything else is `mcp_version_unsupported`.
  static const supportedProtocolVersions = <String>[
    '2025-06-18',
    '2025-03-26',
    '2024-11-05',
  ];

  static const maxFrameBytes = 4 * 1024 * 1024;
  static const maxResultBytes = 1024 * 1024;
  static const maxTools = 128;
  static const maxCallTimeout = Duration(minutes: 10);
  static const initializeTimeout = Duration(seconds: 10);
  static const cancelGrace = Duration(seconds: 5);
  static const idleServerTtl = Duration(minutes: 5);
}

/// Stable diagnostic codes from `MCP_HOST_V1.md` section 6.
abstract final class McpFailure {
  static const versionUnsupported = 'mcp_version_unsupported';
  static const serverCrashed = 'mcp_server_crashed';
  static const authRequired = 'mcp_auth_required';
  static const definitionChanged = 'mcp_definition_changed';
  static const resultTooLarge = 'mcp_result_too_large';
  static const timeout = 'mcp_timeout';
  static const protocolViolation = 'mcp_protocol_violation';
}

class McpException implements Exception {
  McpException(this.code, this.message, {this.jsonRpcCode});

  final String code;
  final String message;
  final int? jsonRpcCode;

  @override
  String toString() => 'McpException($code): $message';
}
