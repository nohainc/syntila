part of 'workspace_cli.dart';

/// `syntila workers import|inspect|register|show` and the External Worker
/// branch of `workers enable|disable|remove`. An External Worker is an MCP
/// Worker package; once enabled it is an ordinary local Worker. Like `mcp`,
/// the CLI only sends requests and prints what the Service returned.
extension _ExternalWorkerCli on WorkspaceCli {
  /// Runs `workers enable|disable|remove` against the External Worker named
  /// [type] (its ID or Worker type), or against a catalog Worker otherwise.
  Future<int> _runWorkerLifecycle(
    String? dataDir,
    bool json,
    String action,
    String type, {
    String? acceptHash,
  }) async {
    final externalId = await _externalWorkerIdFor(dataDir, type);
    if (externalId != null) {
      return _runService(dataDir, json, 'externalWorkers.$action', {
        'externalWorkerId': externalId,
        if (acceptHash != null) 'acceptHash': acceptHash,
      });
    }
    final ipc = switch (action) {
      'enable' => 'workers.enableWorker',
      'disable' => 'workers.disableWorker',
      _ => 'workers.removeWorker',
    };
    return _runService(
      dataDir,
      json,
      ipc,
      {'workerId': type},
      workerType: type,
    );
  }

  /// The External Worker ID for [type], or null when [type] is not one. Any
  /// failure falls back to the catalog path, which reports it.
  Future<String?> _externalWorkerIdFor(String? dataDir, String type) async {
    final refs = await _externalWorkerRefs(dataDir);
    for (final entry in refs.entries) {
      if (entry.key == type || entry.value == type) return entry.value;
    }
    return null;
  }

  Future<Map<String, String>> _externalWorkerRefs(String? dataDir) async {
    try {
      final result = await _send(dataDir, 'externalWorkers.list', {});
      if (result is! Map || result['plugins'] is! List) return {};
      final refs = <String, String>{};
      for (final item in (result['plugins'] as List).whereType<Map>()) {
        if (item['pluginId'] is String && item['pluginRef'] is String) {
          refs[item['pluginRef'] as String] = item['pluginId'] as String;
        } else if (item['pluginId'] is String) {
          refs[item['pluginId'] as String] = item['pluginId'] as String;
        }
      }
      return refs;
    } on Object {
      return {};
    }
  }

  bool _printExternalWorkerResult(
      String command, Object? result, Map<String, Object?> payload) {
    if (result is! Map) return false;
    try {
      return _renderExternalWorkerResult(command, result, payload);
    } on Object {
      return false;
    }
  }

  bool _renderExternalWorkerResult(
      String command, Map result, Map<String, Object?> payload) {
    if (result['consentRequired'] == true) {
      _printExternalWorkerConsent(command, result);
      return true;
    }
    switch (command) {
      case 'externalWorkers.list':
        final workers = (result['plugins'] as List).whereType<Map>();
        if (workers.isEmpty) {
          out.writeln('No External Workers. Import one with: '
              'syntila workers import <path>');
        }
        for (final worker in workers) {
          final versions = (worker['versions'] as List).whereType<Map>();
          final latest = versions.isEmpty ? null : versions.last;
          final local = worker['workspace'] as Map?;
          final state = local != null
              ? '${local['effective']} ${local['pinnedVersion']}'
              : latest?['registered'] == true
                  ? 'registered'
                  : latest?['conformance'] == null
                      ? 'imported'
                      : 'inspected';
          out.writeln('${worker['pluginId']}  ${worker['displayName']}  '
              '(${latest?['version'] ?? '-'}, $state)');
        }
        return true;
      case 'externalWorkers.import':
        out.writeln(
          'Imported ${result['pluginId']} ${result['version']} '
          '(${result['signer'] == null ? 'unsigned' : 'signed'}).',
        );
        out.writeln('Next: syntila workers inspect ${result['pluginId']}');
        return true;
      case 'externalWorkers.show':
        _printFields({
          'ID': result['pluginId'],
          'Name': result['displayName'],
          if (result['workspace'] != null) 'Workspace': result['workspace'],
          if (result['versions'] != null) 'Versions': result['versions'],
          if (result['selected'] != null)
            'Selected version': result['selected'],
        });
        return true;
      case 'externalWorkers.test':
        final cases = (result['cases'] as List).whereType<Map>();
        for (final c in cases) {
          out.writeln(
            '  ${c['status'] == 'passed' ? 'ok  ' : 'FAIL'} ${c['id']}'
            '${c['detail'] == null ? '' : ': ${c['detail']}'}',
          );
        }
        out.writeln(result['passed'] == true
            ? 'Inspection passed.'
            : 'Inspection failed.');
        out.writeln('${result['disclaimer']}');
        return true;
      case 'externalWorkers.register':
        out.writeln(
            'Registered ${payload['externalWorkerId']} ${result['version']}.');
        return true;
      case 'externalWorkers.enable':
        out.writeln(
            'Enabled ${payload['externalWorkerId']} ${result['version']}.');
        out.writeln('It now appears in: syntila workers list');
        return true;
      case 'externalWorkers.disable':
        final draining = result['draining'] ?? 0;
        out.writeln(draining == 0
            ? 'Disabled.'
            : 'Disabled; $draining running assignment(s) will finish first.');
        if (result['cloudSynced'] == false) {
          out.writeln('Cloud was not reachable; it is updated on reconnect.');
        }
        return true;
      case 'externalWorkers.remove':
        out.writeln('Removed.');
        return true;
    }
    return false;
  }

  void _printExternalWorkerConsent(String command, Map result) {
    final doc = Map<String, Object?>.from(result['document'] as Map);
    final worker = Map<String, Object?>.from(doc['plugin'] as Map);
    final digest = Map<String, Object?>.from(doc['digest'] as Map);
    final access = Map<String, Object?>.from(doc['requestedAccess'] as Map);
    final signature = Map<String, Object?>.from(doc['signature'] as Map);
    final verb = command == 'externalWorkers.register' ? 'register' : 'enable';
    out.writeln('Review before you $verb this External Worker');
    out.writeln('  Worker:     ${worker['displayName']} '
        '(${worker['id']} ${worker['version']})');
    out.writeln('  Author:     ${worker['author']} (not verified)');
    out.writeln('  Signature:  ${signature['status']}');
    out.writeln('  Manifest:   ${digest['manifest']}');
    out.writeln('  Artifact:   ${digest['artifact']} (${digest['platform']})');
    for (final entry in access.entries) {
      if (entry.key == 'note') continue;
      out.writeln('  Access ${entry.key}: ${jsonEncode(entry.value)}');
    }
    out.writeln('  ${access['note']}');
    final mcp = doc['mcp'];
    if (mcp is Map) {
      final tools = (mcp['tools'] as List).whereType<Map>().toList();
      out.writeln('  Tools (${tools.length}):');
      for (final tool in tools) {
        out.writeln('    ${tool['name']}: ${tool['description']}');
      }
    }
    if (doc['change'] != null) {
      out.writeln(
          '  Change from the enabled version: ${jsonEncode(doc['change'])}');
    }
    out.writeln('${doc['statement']}');
    out.writeln('Document hash: ${result['documentHash']}');
    out.writeln('To accept, rerun with --accept ${result['documentHash']}');
  }
}
