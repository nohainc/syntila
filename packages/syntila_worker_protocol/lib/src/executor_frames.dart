/// The user-imported plugin an `execute.request` runs instead of a provider
/// CLI Profile (Local Worker Protocol 4.2, ADR-027). Workspace resolves and
/// verifies every field from its own plugin store; Cloud never supplies a path.
final class WorkerExecutor {
  WorkerExecutor({
    required this.pluginId,
    required this.version,
    required this.manifestDigest,
    required this.artifactSha256,
    required this.executable,
    required this.dataDirectory,
    this.arguments = const [],
    this.environmentNames = const [],
    this.protocol = 'ndjson',
    this.toolPins = const {},
  }) {
    if (!RegExp(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$').hasMatch(pluginId) ||
        pluginId.length > 48) {
      throw const FormatException('executor pluginId is malformed');
    }
    if (!RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')
            .hasMatch(version) ||
        version.length > 64) {
      throw const FormatException('executor version must be MAJOR.MINOR.PATCH');
    }
    for (final digest in [manifestDigest, artifactSha256]) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
        throw const FormatException('executor digests must be SHA-256 hex');
      }
    }
    for (final path in [executable, dataDirectory]) {
      if (path.isEmpty ||
          path.length > 4096 ||
          path.contains('\x00') ||
          !(path.startsWith('/') ||
              RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path))) {
        throw const FormatException('executor paths must be absolute');
      }
    }
    if (protocol != 'ndjson' && protocol != 'mcp') {
      throw const FormatException('executor protocol must be ndjson or mcp');
    }
    if (protocol == 'mcp') {
      // Consented tool-definition hashes: the Engine refuses any other tool.
      if (toolPins.isEmpty ||
          toolPins.length > 128 ||
          toolPins.entries.any((e) =>
              e.key.isEmpty ||
              e.key.length > 128 ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(e.value))) {
        throw const FormatException(
            'an mcp executor needs 1-128 SHA-256 tool pins');
      }
    } else if (toolPins.isNotEmpty) {
      throw const FormatException(
          'toolPins are only valid for an mcp executor');
    }
    if (arguments.length > 32 ||
        arguments.any((a) => a.length > 256 || a.contains('\x00'))) {
      throw const FormatException('executor arguments are out of bounds');
    }
    if (environmentNames.length > 16 ||
        environmentNames.any((name) =>
            !RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(name) ||
            name.startsWith('SYNTILA_'))) {
      throw const FormatException('executor environment names are invalid');
    }
  }

  final String pluginId;
  final String version;

  /// Pinned identity: SHA-256 of the canonical manifest.
  final String manifestDigest;

  /// SHA-256 of the one artifact for this OS and architecture. The Engine
  /// re-hashes the file before it spawns anything.
  final String artifactSha256;
  final String executable;
  final String dataDirectory;
  final List<String> arguments;
  final List<String> environmentNames;

  /// `ndjson` (Worker Plugin Protocol) or `mcp` (Syntila MCP Worker profile).
  final String protocol;

  /// Tool name -> definition hash recorded at consent; `mcp` only.
  final Map<String, String> toolPins;

  bool get isMcp => protocol == 'mcp';

  Map<String, Object?> toJson() => {
        'kind': 'plugin',
        'pluginId': pluginId,
        'version': version,
        'manifestDigest': manifestDigest,
        'artifactSha256': artifactSha256,
        'executable': executable,
        'dataDirectory': dataDirectory,
        'arguments': arguments,
        'environmentNames': environmentNames,
        if (isMcp) 'protocol': protocol,
        if (isMcp) 'toolPins': toolPins,
      };

  factory WorkerExecutor.fromJson(Map<String, Object?> json) {
    const allowed = {
      'kind',
      'pluginId',
      'version',
      'manifestDigest',
      'artifactSha256',
      'executable',
      'dataDirectory',
      'arguments',
      'environmentNames',
      'protocol',
      'toolPins',
    };
    final unknown = json.keys.where((key) => !allowed.contains(key));
    if (unknown.isNotEmpty) {
      throw FormatException(
          'executor contains unsupported field: ${unknown.first}');
    }
    if (json['kind'] != 'plugin') {
      throw const FormatException('executor kind must be plugin');
    }
    String string(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('executor $key must be a non-empty string');
      }
      return value;
    }

    List<String> strings(String key) {
      final value = json[key] ?? const <Object?>[];
      if (value is! List || value.any((item) => item is! String)) {
        throw FormatException('executor $key must be a list of strings');
      }
      return List<String>.unmodifiable(value.cast<String>());
    }

    final rawPins = json['toolPins'] ?? const <String, Object?>{};
    if (rawPins is! Map || rawPins.values.any((v) => v is! String)) {
      throw const FormatException('executor toolPins must map names to hashes');
    }
    final protocol = json['protocol'] ?? 'ndjson';
    if (protocol is! String) {
      throw const FormatException('executor protocol must be a string');
    }
    return WorkerExecutor(
      protocol: protocol,
      toolPins: Map<String, String>.unmodifiable(
          rawPins.map((k, v) => MapEntry('$k', v as String))),
      pluginId: string('pluginId'),
      version: string('version'),
      manifestDigest: string('manifestDigest'),
      artifactSha256: string('artifactSha256'),
      executable: string('executable'),
      dataDirectory: string('dataDirectory'),
      arguments: strings('arguments'),
      environmentNames: strings('environmentNames'),
    );
  }
}
