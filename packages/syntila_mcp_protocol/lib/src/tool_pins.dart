import 'canonical.dart';

/// Hash of one tool definition: name, description, inputSchema, outputSchema,
/// annotations (MCP_HOST_V1.md section 4). Other fields (e.g. `title`, `_meta`)
/// are deliberately excluded so cosmetic metadata cannot cause false drift.
String toolDefinitionHash(Map<String, Object?> tool) {
  const fields = [
    'name',
    'description',
    'inputSchema',
    'outputSchema',
    'annotations',
  ];
  return sha256Hex(canonicalJson({
    for (final f in fields)
      if (tool.containsKey(f)) f: tool[f],
  }));
}

class ToolPinDiff {
  const ToolPinDiff({
    this.added = const [],
    this.changed = const [],
    this.removed = const [],
  });
  final List<String> added;
  final List<String> changed;
  final List<String> removed;
  bool get isEmpty => added.isEmpty && changed.isEmpty && removed.isEmpty;
  bool get blocksCalls => added.isNotEmpty || changed.isNotEmpty;
}

/// Name -> hash map recorded at consent.
class ToolPins {
  ToolPins(Map<String, String> hashes) : hashes = Map.unmodifiable(hashes);

  factory ToolPins.fromTools(List<Map<String, Object?>> tools) =>
      ToolPins({for (final t in tools) '${t['name']}': toolDefinitionHash(t)});

  final Map<String, String> hashes;

  /// Compares the consented pins (`this`) with the server's current tools.
  ToolPinDiff diff(List<Map<String, Object?>> current) {
    final now = ToolPins.fromTools(current).hashes;
    return ToolPinDiff(
      added: [
        for (final n in now.keys)
          if (!hashes.containsKey(n)) n
      ]..sort(),
      changed: [
        for (final n in now.keys)
          if (hashes.containsKey(n) && hashes[n] != now[n]) n
      ]..sort(),
      removed: [
        for (final n in hashes.keys)
          if (!now.containsKey(n)) n
      ]..sort(),
    );
  }

  /// A call to [tool] is allowed only if it was consented and is unchanged.
  bool allows(String tool, List<Map<String, Object?>> current) {
    final h = hashes[tool];
    if (h == null) return false;
    for (final t in current) {
      if (t['name'] == tool) return toolDefinitionHash(t) == h;
    }
    return false;
  }
}
