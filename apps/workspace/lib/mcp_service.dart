import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart'
    show McpServerLaunch, WorkerProtocolLimits;

import 'mcp_registry.dart';

/// A stable management error code, for example `mcp_not_consented`.
class McpPolicyException implements Exception {
  const McpPolicyException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Starts the server (through the Engine, never in this process) and returns
/// its current `tools/list`. Used to show and pin definitions at consent.
abstract interface class McpProbePort {
  Future<List<Map<String, Object?>>> listTools(McpServerRecord server);
}

/// The Service-side authority over which MCP servers an execution may use.
/// Cloud never sees commands, arguments or environments (AUTHORIZATION_MODEL).
class McpService {
  McpService(
    this._registry,
    this._probe, {
    Map<String, String>? environment,
  }) : _environment = environment ?? Platform.environment;

  final McpRegistry _registry;
  final McpProbePort _probe;
  final Map<String, String> _environment;

  static final _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
  static final _envPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$');

  Future<String> _sha256OfFile(String path) async {
    // Raw bytes: this must equal the Engine's PluginHost.sha256OfFile.
    return (await crypto.sha256.bind(File(path).openRead()).first).toString();
  }

  List<Map<String, Object?>> list() => [
        for (final s in _registry.list())
          {
            'serverId': s.serverId,
            'displayName': s.displayName,
            'command': s.command,
            'consented': s.consented,
            'enabled': s.enabled,
            'tools': (s.toolPins.keys.toList()..sort()),
          },
      ];

  Future<Map<String, Object?>> add({
    required String serverId,
    required String displayName,
    required String command,
    List<String> arguments = const [],
    List<String> environmentNames = const [],
  }) async {
    if (!_idPattern.hasMatch(serverId)) {
      throw const McpPolicyException('invalid_request', 'Invalid server id.');
    }
    if (_registry.get(serverId) != null) {
      throw const McpPolicyException(
        'mcp_exists',
        'A server with this id already exists.',
      );
    }
    if (displayName.isEmpty || displayName.length > 128) {
      throw const McpPolicyException('invalid_request', 'Invalid name.');
    }
    if (!File(command).isAbsolute ||
        command.contains('\u0000') ||
        !File(command).existsSync()) {
      throw const McpPolicyException(
        'invalid_request',
        'The command must be an existing absolute path.',
      );
    }
    if (arguments.length > WorkerProtocolLimits.maxMcpServerArguments ||
        environmentNames.length >
            WorkerProtocolLimits.maxMcpServerEnvironment ||
        environmentNames.any(
          (n) => !_envPattern.hasMatch(n) || n.startsWith('SYNTILA_'),
        )) {
      throw const McpPolicyException(
        'invalid_request',
        'Arguments or environment names exceed limits.',
      );
    }
    final record = McpServerRecord(
      serverId: serverId,
      displayName: displayName,
      command: command,
      commandSha256: await _sha256OfFile(command),
      arguments: arguments,
      environmentNames: environmentNames,
    );
    _registry.put(record);
    return {'serverId': serverId, 'next': 'syntila mcp consent $serverId'};
  }

  /// Without [acceptHash] returns the consent document (full tool definitions
  /// included). With the matching hash, pins the definitions and records
  /// consent. A server whose tools changed since the document was shown has a
  /// different hash and is refused.
  Future<Map<String, Object?>> consent(
    String serverId, {
    String? acceptHash,
  }) async {
    final server = _require(serverId);
    await _checkBinary(server);
    final tools = await _probe.listTools(server);
    final definitions = [
      for (final t in tools)
        {
          for (final key in const [
            'name',
            'description',
            'inputSchema',
            'outputSchema',
            'annotations',
          ])
            if (t.containsKey(key)) key: t[key],
        },
    ]..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    final document = {
      'serverId': server.serverId,
      'command': server.command,
      'commandSha256': server.commandSha256,
      'arguments': server.arguments,
      'environmentNames': server.environmentNames,
      'tools': definitions,
    };
    final hash = sha256Hex(canonicalJson(document));
    if (acceptHash == null) {
      return {
        'consentRequired': true,
        'document': document,
        'documentHash': hash,
      };
    }
    if (acceptHash != hash) {
      throw const McpPolicyException(
        'mcp_consent_mismatch',
        'The server changed since the consent document was shown.',
      );
    }
    final updated = server.copy()
      ..toolPins = ToolPins.fromTools(tools).hashes
      ..consentHash = hash;
    _registry.put(updated);
    return {'serverId': serverId, 'consented': true, 'documentHash': hash};
  }

  Map<String, Object?> enable(String serverId) {
    final server = _require(serverId);
    if (!server.consented) {
      throw const McpPolicyException(
        'mcp_not_consented',
        'Consent to the server and its tools before enabling it.',
      );
    }
    _registry.put(server.copy()..enabled = true);
    return {'serverId': serverId, 'enabled': true};
  }

  Map<String, Object?> disable(String serverId) {
    final server = _require(serverId);
    _registry.put(server.copy()..enabled = false);
    return {'serverId': serverId, 'enabled': false};
  }

  Map<String, Object?> remove(String serverId) {
    _require(serverId);
    _registry.remove(serverId);
    return {'serverId': serverId, 'removed': true};
  }

  /// Tool pins the Engine host must enforce for this server.
  ToolPins pinsFor(String serverId) =>
      ToolPins(Map.of(_require(serverId).toolPins));

  /// The only route from configuration to `execute.request.mcpServers`.
  /// Every requested server must be consented, enabled and byte-identical to
  /// what was consented; otherwise the whole request is refused (never a
  /// silent subset).
  Future<List<McpServerLaunch>> resolveLaunches(List<String> serverIds) async {
    final launches = <McpServerLaunch>[];
    for (final id in serverIds) {
      final server = _registry.get(id);
      if (server == null || !server.enabled || !server.consented) {
        throw McpPolicyException(
          'mcp_not_enabled',
          'MCP server "$id" is not enabled and consented.',
        );
      }
      await _checkBinary(server);
      launches.add(
        McpServerLaunch(
          name: server.serverId,
          command: server.command,
          arguments: server.arguments,
          environment: {
            for (final name in server.environmentNames)
              if (_environment[name] != null) name: _environment[name]!,
          },
        ),
      );
    }
    return launches;
  }

  McpServerRecord _require(String serverId) =>
      _registry.get(serverId) ??
      (throw McpPolicyException(
        'mcp_not_found',
        'No MCP server "$serverId".',
      ));

  Future<void> _checkBinary(McpServerRecord server) async {
    final String digest;
    try {
      digest = await _sha256OfFile(server.command);
    } on FileSystemException {
      throw McpPolicyException(
        'mcp_binary_changed',
        'The command for "${server.serverId}" can no longer be read.',
      );
    }
    if (digest != server.commandSha256) {
      throw McpPolicyException(
        'mcp_binary_changed',
        'The command for "${server.serverId}" changed since it was added.',
      );
    }
  }
}
