import 'dart:convert';
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
/// A remote server as the Engine needs it: the endpoint and the token the
/// Service read from its environment just now. Never persisted.
class McpRemoteTarget {
  const McpRemoteTarget({
    required this.endpoint,
    this.bearerToken,
    this.insecureLoopback = false,
  });

  final Uri endpoint;
  final String? bearerToken;
  final bool insecureLoopback;
}

/// A local, short-lived admission snapshot. It can contain credentials and
/// must never be sent to Cloud, persisted, or logged.
class McpToolCallAdmission {
  const McpToolCallAdmission._({
    required this.serverId,
    required this.tool,
    required this.toolHash,
    this.launch,
    this.commandSha256,
    this.remote,
  });

  final String serverId;
  final String tool;
  final String toolHash;
  final McpServerLaunch? launch;
  final String? commandSha256;
  final McpRemoteTarget? remote;
}

abstract interface class McpProbePort {
  /// [launch] is the resolved launch (command, arguments and the environment
  /// values for the consented names); the record carries the pinned digest.
  Future<List<Map<String, Object?>>> listTools(
    McpServerRecord server,
    McpServerLaunch launch,
  );

  /// Same for a remote server (Streamable HTTP).
  Future<List<Map<String, Object?>>> listRemoteTools(
    McpServerRecord server,
    McpRemoteTarget remote,
  );
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
    // Raw bytes: this must equal the Engine's ExternalWorkerProcessHost.sha256OfFile.
    return (await crypto.sha256.bind(File(path).openRead()).first).toString();
  }

  List<Map<String, Object?>> list() => [
        for (final s in _registry.list())
          {
            'serverId': s.serverId,
            'displayName': s.displayName,
            if (s.command != null) 'command': s.command,
            if (s.endpoint != null) 'endpoint': s.endpoint,
            'remote': s.isRemote,
            'consented': s.consented,
            'enabled': s.enabled,
            'tools': (s.toolPins.keys.toList()..sort()),
          },
      ];

  /// A secret-free inventory projection. Availability is unknown until a
  /// live diagnostic mechanism supplies fresh evidence; consent and enablement
  /// alone do not prove that the server is reachable or its definitions match.
  /// This is not an authorization decision.
  List<Map<String, Object?>> sanitizedInventory() {
    return [
      for (final server in _registry.list())
        {
          'serverId': server.serverId,
          'displayName': server.displayName,
          'transport': server.isRemote ? 'remote' : 'local',
          'consented': server.consented,
          'enabled': server.enabled,
          'availability': 'unknown',
          'tools': [
            for (final name in (server.toolPins.keys.toList()..sort()))
              {'name': name, 'definitionHash': server.toolPins[name]},
          ],
        },
    ];
  }

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
    final List<Map<String, Object?>> tools;
    if (server.isRemote) {
      tools = await _probe.listRemoteTools(server, _remoteTargetFor(server));
    } else {
      await _checkBinary(server);
      tools = await _probe.listTools(server, _launchFor(server));
    }
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
    final document = server.isRemote
        ? {
            'serverId': server.serverId,
            'transport': 'remote',
            'endpoint': server.endpoint,
            // The NAME of the variable that holds the token; never its value.
            'tokenEnvironmentName': server.tokenEnv,
            'insecureLoopback': server.insecureLoopback,
            'tools': definitions,
          }
        : {
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

  /// Probes the server and returns its current tools without modifying pins or
  /// consent. Throws if the server is unreachable or its binary check fails.
  Future<Map<String, Object?>> test(String serverId) async {
    final server = _require(serverId);
    final List<Map<String, Object?>> tools;
    if (server.isRemote) {
      tools = await _probe.listRemoteTools(server, _remoteTargetFor(server));
    } else {
      await _checkBinary(server);
      tools = await _probe.listTools(server, _launchFor(server));
    }
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
    return {
      'serverId': serverId,
      'reachable': true,
      'toolsCount': tools.length,
      'tools': definitions,
    };
  }

  /// Launches for one execution of the Workspace owner's own work (ADR-028):
  /// every enabled, consented local server, for any Worker and Workflow, with
  /// no further selection. A server that cannot be launched safely (remote, or
  /// its command changed since consent) is left out and reported through
  /// [onSkipped]; it never runs and never fails the whole execution.
  Future<List<McpServerLaunch>> launchesForOwnerExecution({
    void Function(String message)? onSkipped,
  }) async {
    final List<McpServerRecord> servers;
    try {
      servers = _registry.list();
    } on McpRegistryUnreadable {
      throw const McpPolicyException(
        'mcp_registry_unreadable',
        'The MCP server registry could not be read.',
      );
    }
    final launches = <McpServerLaunch>[];
    for (final server in servers) {
      if (!server.enabled || !server.consented) continue;
      if (server.isRemote) {
        try {
          final target = _remoteTargetFor(server);
          launches.add(
            McpServerLaunch(
              name: server.serverId,
              url: target.endpoint.toString(),
              headers: {
                if (target.bearerToken != null)
                  'Authorization': 'Bearer ${target.bearerToken}',
              },
            ),
          );
        } on McpPolicyException catch (error) {
          onSkipped?.call(error.message);
        }
        continue;
      }
      try {
        await _checkBinary(server);
      } on McpPolicyException catch (error) {
        onSkipped?.call(error.message);
        continue;
      }
      launches.add(_launchFor(server));
    }
    return launches;
  }

  /// Tool pins the Engine host must enforce for this server.
  ToolPins pinsFor(String serverId) =>
      ToolPins(Map.of(_require(serverId).toolPins));

  /// Resolves one frozen tool identity for a direct call. This is only local
  /// admission: the assignment's authorization, durable no-replay record and
  /// the Engine's revalidation remain mandatory before actual execution.
  Future<McpToolCallAdmission> admitToolCall({
    required String serverId,
    required String tool,
    required String expectedToolHash,
  }) async {
    if (!_idPattern.hasMatch(serverId) ||
        tool.isEmpty ||
        tool.length > 128 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedToolHash)) {
      throw const McpPolicyException('invalid_request', 'Invalid tool call.');
    }
    final server = _registry.get(serverId);
    if (server == null || !server.enabled || !server.consented) {
      throw const McpPolicyException(
        'mcp_not_enabled',
        'MCP server is not enabled and consented.',
      );
    }
    if (server.toolPins[tool] != expectedToolHash) {
      throw const McpPolicyException(
        'mcp_tool_not_consented',
        'The requested tool definition is not consented.',
      );
    }
    if (server.isRemote) {
      _remoteEndpoint(server.endpoint!,
          insecureLoopback: server.insecureLoopback);
      return McpToolCallAdmission._(
        serverId: serverId,
        tool: tool,
        toolHash: expectedToolHash,
        remote: _remoteTargetFor(server),
      );
    }
    final snapshot = jsonEncode(server.toJson());
    await _checkBinary(server);
    final current = _registry.get(serverId);
    if (current == null || jsonEncode(current.toJson()) != snapshot) {
      throw const McpPolicyException(
        'mcp_admission_changed',
        'MCP server configuration changed during admission.',
      );
    }
    return McpToolCallAdmission._(
      serverId: serverId,
      tool: tool,
      toolHash: expectedToolHash,
      launch: _launchFor(current),
      commandSha256: current.commandSha256,
    );
  }

  static Uri _remoteEndpoint(String raw, {required bool insecureLoopback}) {
    final uri = Uri.tryParse(raw);
    const loopback = {'127.0.0.1', 'localhost', '::1', '[::1]'};
    final secure = uri != null && uri.scheme == 'https';
    final plain = uri != null &&
        uri.scheme == 'http' &&
        insecureLoopback &&
        loopback.contains(uri.host);
    if (raw.length > 2048 ||
        uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !(secure || plain)) {
      throw const McpPolicyException(
        'invalid_request',
        'The endpoint must be an https URL without credentials or a '
            'fragment (plain http only for loopback, explicitly allowed).',
      );
    }
    return uri;
  }

  /// Registers a remote MCP server. Nothing is contacted until consent.
  Map<String, Object?> addRemote({
    required String serverId,
    required String displayName,
    required String endpoint,
    String? tokenEnv,
    bool insecureLoopback = false,
  }) {
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
    final uri = _remoteEndpoint(endpoint, insecureLoopback: insecureLoopback);
    if (tokenEnv != null &&
        (!_envPattern.hasMatch(tokenEnv) || tokenEnv.startsWith('SYNTILA_'))) {
      throw const McpPolicyException(
        'invalid_request',
        'The token variable name is invalid.',
      );
    }
    _registry.put(
      McpServerRecord(
        serverId: serverId,
        displayName: displayName,
        endpoint: uri.toString(),
        tokenEnv: tokenEnv,
        insecureLoopback: insecureLoopback,
      ),
    );
    return {'serverId': serverId, 'next': 'syntila mcp consent $serverId'};
  }

  McpRemoteTarget _remoteTargetFor(McpServerRecord server) {
    final name = server.tokenEnv;
    final token = name == null ? null : _environment[name];
    if (name != null && (token == null || token.isEmpty)) {
      // Fail closed: never contact the server without the credential the
      // person agreed to send.
      throw McpPolicyException(
        'mcp_token_missing',
        'The environment variable $name is not set for "${server.serverId}".',
      );
    }
    return McpRemoteTarget(
      endpoint: Uri.parse(server.endpoint!),
      bearerToken: token,
      insecureLoopback: server.insecureLoopback,
    );
  }

  /// The only route from configuration to a remote connection: consented,
  /// enabled, and the token present. Cloud never sees any of it.
  McpRemoteTarget resolveRemote(String serverId) {
    final server = _registry.get(serverId);
    if (server == null ||
        !server.isRemote ||
        !server.enabled ||
        !server.consented) {
      throw McpPolicyException(
        'mcp_not_enabled',
        'Remote MCP server "$serverId" is not enabled and consented.',
      );
    }
    return _remoteTargetFor(server);
  }

  McpServerLaunch _launchFor(McpServerRecord server) => McpServerLaunch(
        name: server.serverId,
        command: server.command!,
        arguments: server.arguments,
        environment: {
          for (final name in server.environmentNames)
            if (_environment[name] != null) name: _environment[name]!,
        },
      );

  McpServerRecord _require(String serverId) =>
      _registry.get(serverId) ??
      (throw McpPolicyException(
        'mcp_not_found',
        'No MCP server "$serverId".',
      ));

  Future<void> _checkBinary(McpServerRecord server) async {
    final String digest;
    try {
      digest = await _sha256OfFile(server.command!);
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

/// True when every argument vector that may be selected (base and each
/// compatibility override) contains the `mcpConfigArguments` slot (ADR-028).
bool profileSupportsMcpServers(Map<String, Object?> profile) {
  bool hasSlot(Object? arguments) =>
      arguments is List &&
      arguments
          .any((part) => part is Map && part.containsKey('mcpConfigArguments'));
  final execution = profile['execution'];
  if (execution is! Map || !hasSlot(execution['arguments'])) return false;
  final overrides = profile['compatibilityOverrides'];
  if (overrides is List) {
    for (final override in overrides) {
      if (override is Map &&
          override.containsKey('executionArguments') &&
          !hasSlot(override['executionArguments'])) {
        return false;
      }
    }
  }
  return true;
}

/// What an execution of an official Worker gets, decided in one place.
///
/// Only the Workspace owner's own work receives MCP servers: a Space member or
/// shared-Workspace user whose work runs here gets none, because the servers
/// act with the owner's local files and credentials. [requestedByOwner] must
/// come from the authenticated assignment, never from request input.
///
/// An unreadable registry, a Profile without the MCP slot, or a server that
/// cannot be launched safely yields fewer servers and a message through
/// [onSkipped] (a less capable run, never a more privileged one).
Future<List<McpServerLaunch>> mcpLaunchesForExecution(
  McpService service,
  Map<String, Object?> profile, {
  required bool requestedByOwner,
  void Function(String message)? onSkipped,
}) async {
  if (!requestedByOwner) return const [];
  final List<McpServerLaunch> launches;
  try {
    launches = await service.launchesForOwnerExecution(onSkipped: onSkipped);
  } on McpPolicyException catch (error) {
    onSkipped?.call(error.message);
    return const [];
  }
  if (launches.isNotEmpty && !profileSupportsMcpServers(profile)) {
    onSkipped?.call('This Worker cannot use MCP servers yet.');
    return const [];
  }
  return launches;
}

/// True only when the authenticated requester of this assignment is the
/// Workspace owner. Unknown on either side means not the owner.
bool assignmentRequestedByOwner(
  Map<String, Object?> payload,
  String? ownerUserId,
) {
  final requester = payload['requestedByUserId'];
  return ownerUserId != null &&
      ownerUserId.isNotEmpty &&
      requester is String &&
      requester == ownerUserId;
}
