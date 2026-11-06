/// The sanitized MCP inventory Cloud serves for one Workspace
/// (`GET /api/workspaces/:id/mcp-inventory`). It names servers and the tool
/// definitions that were consented; it holds no commands, paths, endpoints or
/// tokens. It is information for choosing servers by name, never authority: the
/// Workspace re-checks consent, enablement and tool hashes before every run.
class AxMcpTool {
  const AxMcpTool({required this.name, required this.definitionHash});
  final String name;
  final String definitionHash;
}

class AxMcpServer {
  const AxMcpServer({
    required this.serverId,
    required this.displayName,
    required this.transport,
    required this.consented,
    required this.enabled,
    required this.availability,
    required this.diagnostic,
    required this.tools,
    required this.boundWorkerTypes,
  });

  final String serverId, displayName, transport, availability;
  final String? diagnostic;
  final bool consented, enabled;
  final List<AxMcpTool> tools;
  final List<String> boundWorkerTypes;

  bool get isRemote => transport == 'remote';

  /// Consented and enabled on the Workspace. Not proof that it is reachable.
  bool get isAuthorized => consented && enabled;

  /// Why this server cannot be used right now, in user words; null when nothing
  /// known prevents it.
  String? get blocker {
    if (!consented) return 'Not consented on the Workspace';
    if (!enabled) return 'Disabled on the Workspace';
    if (availability == 'incompatible') {
      return 'Not supported by the selected Worker';
    }
    if (availability == 'unavailable') return 'Not reachable';
    if (boundWorkerTypes.isEmpty) return 'Not bound to any Worker';
    return null;
  }

  factory AxMcpServer.fromJson(Map<String, dynamic> json) => AxMcpServer(
        serverId: json['serverId'] as String,
        displayName: json['displayName'] as String,
        transport: json['transport'] as String,
        consented: json['consented'] as bool,
        enabled: json['enabled'] as bool,
        availability: json['availability'] as String,
        diagnostic: json['diagnostic'] as String?,
        tools: [
          for (final tool in (json['tools'] as List))
            AxMcpTool(
              name: (tool as Map)['name'] as String,
              definitionHash: tool['definitionHash'] as String,
            ),
        ],
        boundWorkerTypes:
            (json['boundWorkerTypes'] as List).cast<String>().toList(),
      );
}

class AxMcpInventory {
  const AxMcpInventory({
    required this.revision,
    required this.servers,
    required this.online,
    required this.ageSeconds,
  });

  /// Rises with every local change on the Workspace.
  final int revision;
  final List<AxMcpServer> servers;

  /// Null when Cloud cannot say.
  final bool? online;

  /// Age of the snapshot when Cloud answered; null when unknown.
  final int? ageSeconds;

  /// A disconnected Workspace's inventory is the last known one, not current.
  bool get isStale => online != true;

  AxMcpServer? byId(String id) {
    for (final server in servers) {
      if (server.serverId == id) return server;
    }
    return null;
  }

  /// Null when the Workspace has not published an inventory.
  static AxMcpInventory? fromResponse(Map<String, dynamic> json) {
    final inventory = json['inventory'];
    if (inventory is! Map) return null;
    return AxMcpInventory(
      revision: inventory['revision'] as int,
      servers: [
        for (final server in (inventory['servers'] as List))
          AxMcpServer.fromJson(Map<String, dynamic>.from(server as Map)),
      ],
      online: json['online'] as bool?,
      ageSeconds: json['ageSeconds'] as int?,
    );
  }
}

abstract interface class AxMcpInventoryDataSource {
  /// Null when the Workspace has published nothing yet.
  Future<AxMcpInventory?> loadMcpInventory(String workspaceId);
}
