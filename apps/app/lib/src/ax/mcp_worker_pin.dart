/// An MCP Worker (ADR-041) as the owner pins it to a Worker: the package
/// version and its manifest digest. The Agent still runs it only when its own
/// list on that machine approves the same digest.
class McpWorkerVersion {
  const McpWorkerVersion({
    required this.id,
    required this.version,
    required this.manifestDigest,
  });

  /// The manifest `pluginId`; empty for a pin the server reports without one.
  final String id;
  final String version;
  final String manifestDigest;

  @override
  bool operator ==(Object other) =>
      other is McpWorkerVersion &&
      other.id == id &&
      other.version == version &&
      other.manifestDigest == manifestDigest;

  @override
  int get hashCode => Object.hash(id, version, manifestDigest);
}

/// The pin of one Worker and the versions its connected Agent says it can run.
class McpWorkerPinState {
  const McpWorkerPinState({this.pin, this.available = const []});

  final McpWorkerVersion? pin;
  final List<McpWorkerVersion> available;

  /// Reads `GET /api/workers/:id/mcp-pin`. Anything malformed is dropped.
  factory McpWorkerPinState.fromJson(Object? body) {
    McpWorkerVersion? read(Object? item) {
      if (item is! Map) return null;
      final version = item['version'];
      final digest = item['manifestDigest'];
      if (version is! String ||
          version.isEmpty ||
          digest is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
        return null;
      }
      final id = item['id'];
      return McpWorkerVersion(
        id: id is String ? id : '',
        version: version,
        manifestDigest: digest,
      );
    }

    if (body is! Map) return const McpWorkerPinState();
    final available = body['available'];
    return McpWorkerPinState(
      pin: read(body['pin']),
      available: [
        if (available is List)
          for (final item in available)
            if (read(item) case final version?) version,
      ],
    );
  }
}
