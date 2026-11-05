import 'dart:convert';
import 'dart:io';

/// One locally configured MCP server (ADR-028). Holds no secrets: environment
/// *names* are stored and their values are read from the Service's own
/// environment at launch.
class McpServerRecord {
  McpServerRecord({
    required this.serverId,
    required this.displayName,
    required this.command,
    required this.commandSha256,
    this.arguments = const [],
    this.environmentNames = const [],
    this.toolPins = const {},
    this.consentHash,
    this.enabled = false,
  });

  final String serverId;
  final String displayName;
  final String command;

  /// SHA-256 of the executable at add time; re-checked at every launch.
  final String commandSha256;
  final List<String> arguments;
  final List<String> environmentNames;

  /// Tool name -> definition hash recorded at consent. Empty = not consented.
  Map<String, String> toolPins;

  /// Hash of the consent document the user accepted.
  String? consentHash;
  bool enabled;

  bool get consented => consentHash != null;

  McpServerRecord copy() => McpServerRecord(
        serverId: serverId,
        displayName: displayName,
        command: command,
        commandSha256: commandSha256,
        arguments: arguments,
        environmentNames: environmentNames,
        toolPins: Map.of(toolPins),
        consentHash: consentHash,
        enabled: enabled,
      );

  Map<String, Object?> toJson() => {
        'serverId': serverId,
        'displayName': displayName,
        'command': command,
        'commandSha256': commandSha256,
        'arguments': arguments,
        'environmentNames': environmentNames,
        'toolPins': toolPins,
        'consentHash': consentHash,
        'enabled': enabled,
      };

  factory McpServerRecord.fromJson(Map<String, Object?> json) =>
      McpServerRecord(
        serverId: json['serverId'] as String,
        displayName: json['displayName'] as String,
        command: json['command'] as String,
        commandSha256: json['commandSha256'] as String,
        arguments: List<String>.from(json['arguments'] as List),
        environmentNames: List<String>.from(json['environmentNames'] as List),
        toolPins: Map<String, String>.from(json['toolPins'] as Map),
        consentHash: json['consentHash'] as String?,
        enabled: json['enabled'] == true,
      );
}

/// File-backed list of MCP servers, written atomically (temp + rename).
class McpRegistry {
  McpRegistry(this._file);

  final File _file;

  Map<String, McpServerRecord> _read() {
    if (!_file.existsSync()) return {};
    final json = jsonDecode(_file.readAsStringSync()) as Map<String, Object?>;
    return {
      for (final entry in (json['servers'] as Map).entries)
        entry.key as String: McpServerRecord.fromJson(
          Map<String, Object?>.from(entry.value as Map),
        ),
    };
  }

  void _write(Map<String, McpServerRecord> servers) {
    _file.parent.createSync(recursive: true);
    final temp = File('${_file.path}.tmp');
    temp.writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'servers': {for (final e in servers.entries) e.key: e.value.toJson()},
      }),
      flush: true,
    );
    temp.renameSync(_file.path);
  }

  List<McpServerRecord> list() =>
      _read().values.toList()..sort((a, b) => a.serverId.compareTo(b.serverId));

  McpServerRecord? get(String serverId) => _read()[serverId];

  void put(McpServerRecord record) {
    final all = _read();
    all[record.serverId] = record;
    _write(all);
  }

  bool remove(String serverId) {
    final all = _read();
    final existed = all.remove(serverId) != null;
    if (existed) _write(all);
    return existed;
  }
}
