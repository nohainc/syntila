import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';

/// Static assessment of whether an installed NDJSON plugin could be repackaged
/// as a Syntila MCP Worker (ADR-028, plan phase M6). It reads only the manifest:
/// nothing is run, so it cannot prove the plugin's behaviour, only say what the
/// declared contract needs and what MCP Workers cannot do yet.
///
/// Blockers are things that cannot work today; warnings need the author's
/// attention; steps are the ordered migration.
Map<String, Object?> assessMcpMigration(PluginManifest manifest) {
  if (manifest.isMcp) {
    return {
      'alreadyMcp': true,
      'canMigrate': false,
      'blockers': <Object?>[],
      'warnings': <Object?>[],
      'steps': <Object?>[],
    };
  }
  final raw = manifest.raw;
  final capabilities = raw['capabilities'] is Map
      ? Map<String, Object?>.from(raw['capabilities'] as Map)
      : const <String, Object?>{};
  final access = raw['access'] is Map
      ? Map<String, Object?>.from(raw['access'] as Map)
      : const <String, Object?>{};

  final blockers = <Map<String, String>>[];
  final warnings = <Map<String, String>>[];

  final workRoot = access['workRoot'];
  if (workRoot != null && workRoot != 'none') {
    warnings.add({
      'code': 'working_directory_access',
      'message':
          'The plugin declares workRoot "$workRoot". Local MCP Workers receive '
              'the assigned working directory; access declarations are not a sandbox.',
    });
  }

  final continuity = capabilities['continuity'];
  final strategy = continuity is Map ? continuity['strategy'] : null;
  if (capabilities['sessionResume'] == true ||
      (strategy is String && strategy != 'history_replay')) {
    warnings.add({
      'code': 'session_state',
      'message': 'Native sessions map to session.state (created, resumed, '
          'unavailable) in the MCP result; re-check resume and rebuild.',
    });
  }
  if (capabilities['modelDiscovery'] == true) {
    warnings.add({
      'code': 'model_discovery',
      'message': 'Expose model discovery as the syntila.models tool.',
    });
  }
  warnings.add({
    'code': 'conformance_differs',
    'message':
        'There is no NDJSON conformance suite for MCP Workers; "plugins test" '
            'becomes a profile check (Worker marker and required tools), not a '
            'behavioural test.',
  });
  warnings.add({
    'code': 'tool_definitions_are_pinned',
    'message': 'Consent pins every tool definition. Changing a tool name or '
        'description later asks for consent again.',
  });

  return {
    'alreadyMcp': false,
    'canMigrate': blockers.isEmpty,
    'blockers': blockers,
    'warnings': warnings,
    'steps': [
      'Serve the same Worker over MCP: in Dart call runMcpWorker(worker) '
          'instead of runPlugin(worker); in other languages implement '
          'syntila.execute and syntila.probe as in MCP_WORKER_PROFILE_V1.',
      'In plugin.json add "kind": "mcp". The protocol range then names the '
          'Syntila Worker profile (keep 1.0).',
      'Raise the version, pack again (the digest changes) and sign again if '
          'the package was signed.',
      'Import it, run "plugins test", then register and enable it; the '
          'consent screen lists the tools.',
    ],
  };
}
