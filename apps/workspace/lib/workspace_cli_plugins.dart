part of 'workspace_cli.dart';

/// Rendering for `syntila plugins ...`. The CLI never reads a plugin's bytes,
/// never starts anything and never talks to Cloud; it prints what the Service
/// returned. A consent document is shown in full and accepting it means
/// rerunning the command with `--accept <documentHash>`.
extension _PluginOutput on WorkspaceCli {
  bool _printPluginResult(String command, Object? result) {
    if (result is! Map) return false;
    // A reply this CLI cannot render (for example from a different Service
    // version) falls back to the generic printer instead of crashing.
    try {
      return _renderPluginResult(command, result);
    } on Object {
      return false;
    }
  }

  bool _renderPluginResult(String command, Map result) {
    switch (command) {
      case 'plugins.list':
        _printPluginList(result);
        return true;
      case 'plugins.show':
        _printPluginShow(result);
        return true;
      case 'plugins.import':
        out.writeln(
          'Imported ${result['pluginId']} ${result['version']} '
          '(digest ${_short(result['manifestDigest'])}).',
        );
        out.writeln('Next: ${result['next']}');
        return true;
      case 'plugins.validate':
        out.writeln(
          'Valid: ${result['pluginId']} ${result['version']} for '
          '${result['platform']} (protocol ${result['protocol']}).',
        );
        for (final warning in (result['warnings'] as List? ?? const [])) {
          out.writeln('Warning: $warning');
        }
        return true;
      case 'plugins.test':
        _printConformance(result);
        return true;
      case 'plugins.migrateCheck':
        _printMigration(result);
        return true;
      case 'plugins.register':
      case 'plugins.enable':
        if (result['consentRequired'] == true) {
          _printConsent(command, result);
        } else if (command == 'plugins.register') {
          out.writeln(
            'Registered ${result['version']} as ${result['pluginRef']}.',
          );
          out.writeln('Next: syntila plugins enable <id>');
        } else {
          out.writeln('Enabled ${result['version']} (${result['pluginRef']}).');
        }
        return true;
      case 'plugins.disable':
        out.writeln('Disabled.');
        if (result['cloudSynced'] == false) {
          out.writeln(
            'Cloud could not confirm the change. Run plugins disable again '
            'to retry, or remove the plugin after reconnecting.',
          );
        }
        if ((result['draining'] as int? ?? 0) > 0) {
          out.writeln(
            '${result['draining']} running assignment(s) will finish first.',
          );
        }
        return true;
      case 'plugins.remove':
        out.writeln('Removed.');
        return true;
      case 'plugins.export':
        out.writeln(
          'Exported ${result['pluginId']} ${result['version']} '
          '(digest ${_short(result['manifestDigest'])}). '
          'The bundle contains no credentials, data or logs.',
        );
        return true;
      case 'plugins.signers':
        final signers = (result['signers'] as List).whereType<Map>();
        if (signers.isEmpty) out.writeln('No locally recognized signers.');
        for (final signer in signers) {
          out.writeln(
              '${signer['fingerprint']}  accepted ${signer['acceptedAt']}');
        }
        out.writeln(result['statement']);
        return true;
      case 'plugins.trustSigner':
        if (result['consentRequired'] == true) {
          final doc = result['document'] as Map;
          out.writeln(
              'Review before recognizing this signer on this installation');
          out.writeln('  Plugin: ${doc['pluginId']} ${doc['version']}');
          out.writeln('  Manifest: ${doc['manifestDigest']}');
          out.writeln('  Fingerprint: ${doc['fingerprint']}');
          out.writeln(doc['statement']);
          out.writeln('To accept exactly this, rerun with:');
          out.writeln('  --accept ${result['documentHash']}');
        } else {
          out.writeln('Recognized locally: ${result['fingerprint']}');
          out.writeln(
              'Plugin execution and updates still need explicit consent.');
        }
        return true;
      case 'plugins.untrustSigner':
        out.writeln(
            'Forgot local signer recognition: ${result['fingerprint']}');
        out.writeln(
            'Existing plugin enablement is unchanged; use plugins disable to stop scheduling.');
        return true;
    }
    return false;
  }

  String _short(Object? digest) => digest is String && digest.length > 12
      ? digest.substring(0, 12)
      : '$digest';

  void _printPluginList(Map result) {
    final plugins = (result['plugins'] as List? ?? const []).whereType<Map>();
    if (plugins.isEmpty) out.writeln('No plugins imported.');
    for (final plugin in plugins) {
      final workspace = plugin['workspace'];
      final state = workspace is Map
          ? '${workspace['effective']}'
              '${workspace['reason'] == null ? '' : ' (${workspace['reason']})'}'
              ' @ ${workspace['pinnedVersion']}'
          : 'not enabled';
      out.writeln('${plugin['pluginId']}  ${plugin['displayName']}  [$state]');
      for (final v in (plugin['versions'] as List).whereType<Map>()) {
        final c = v['conformance'];
        out.writeln(
          '  ${v['version']}  ${_short(v['manifestDigest'])}  '
          '${v['registered'] == true ? 'registered' : 'imported'}  '
          '${c is Map ? (c['passed'] == true ? 'conformant' : 'not conformant') : 'untested'}',
        );
      }
    }
  }

  void _printPluginShow(Map result) {
    _printPluginList({
      'plugins': [result],
    });
    final selected = result['selected'];
    if (selected is Map) {
      out.writeln('Digest:   ${selected['manifestDigest']}');
      out.writeln('Artifact: ${selected['artifactDigest']}');
      final origin = selected['origin'];
      if (origin is Map) {
        out.writeln('Origin:   ${origin['kind']} (${origin['locator']})');
      }
      final signer = selected['signer'];
      out.writeln(
        signer is Map
            ? 'Signer:   ${signer['fingerprint']} (signature verified; '
                '${selected['signerTrustedLocally'] == true ? 'recognized locally' : 'not recognized locally'})'
            : 'Signer:   unsigned',
      );
    }
  }

  void _printMigration(Map result) {
    out.writeln('${result['pluginId']} ${result['version']}');
    if (result['alreadyMcp'] == true) {
      out.writeln('Already an MCP Worker; nothing to migrate.');
      return;
    }
    final blockers = (result['blockers'] as List).whereType<Map>().toList();
    for (final b in blockers) {
      out.writeln('blocker  ${b['code']}: ${b['message']}');
    }
    for (final w in (result['warnings'] as List).whereType<Map>()) {
      out.writeln('warning  ${w['code']}: ${w['message']}');
    }
    out.writeln(
      result['canMigrate'] == true
          ? 'Can migrate today. Steps:'
          : 'Cannot migrate yet (see the blockers). Steps once unblocked:',
    );
    var n = 1;
    for (final step in (result['steps'] as List)) {
      out.writeln('  ${n++}. $step');
    }
    out.writeln(
      'Static check of plugin.json only: nothing was run, so behaviour is '
      'not verified. The NDJSON protocol keeps working; migrating is optional.',
    );
  }

  void _printConformance(Map result) {
    for (final c in (result['cases'] as List? ?? const []).whereType<Map>()) {
      out.writeln(
        '${'${c['status']}'.padRight(8)}${c['id']}'
        '${c['detail'] == null ? '' : '  - ${c['detail']}'}',
      );
    }
    out.writeln(
      result['passed'] == true
          ? 'Conformance: passed (suite ${result['suiteVersion']}).'
          : 'Conformance: FAILED (suite ${result['suiteVersion']}).',
    );
    out.writeln(result['disclaimer']);
  }

  void _printConsent(String command, Map result) {
    final doc = Map<String, Object?>.from(result['document'] as Map);
    final plugin = Map<String, Object?>.from(doc['plugin'] as Map);
    final digest = Map<String, Object?>.from(doc['digest'] as Map);
    final access = Map<String, Object?>.from(doc['requestedAccess'] as Map);
    final origin = Map<String, Object?>.from(doc['origin'] as Map);
    final signature = Map<String, Object?>.from(doc['signature'] as Map);
    final isolation = Map<String, Object?>.from(doc['isolation'] as Map);
    final verb = command == 'plugins.register' ? 'register' : 'enable';
    out.writeln('Review before you $verb this plugin');
    out.writeln(
        '  Plugin:    ${plugin['id']} ${plugin['version']} - ${plugin['displayName']}');
    out.writeln(
      '  Author:    ${plugin['author']} '
      '(unverified, as claimed)',
    );
    out.writeln('  Origin:    ${origin['kind']} (${origin['locator']})');
    out.writeln('  Digest:    ${digest['manifest']}');
    out.writeln('  Artifact:  ${digest['artifact']} (${digest['platform']})');
    final network = Map<String, Object?>.from(access['network'] as Map);
    out.writeln('  Requests:  workspace files: ${access['workRoot']}');
    out.writeln(
      '             network: ${network['mode']}'
      '${network['hosts'] == null ? '' : ' ${network['hosts']}'}',
    );
    out.writeln('             subprocesses: ${access['subprocess']}');
    out.writeln('             environment: ${access['env']}');
    out.writeln(
      '  Signature: ${signature['status']}'
      '${signature['fingerprint'] == null ? '' : ' ${signature['fingerprint']}'}',
    );
    if (signature['status'] == 'verified') {
      out.writeln(
          '  Key recognition: ${signature['trustedLocally'] == true ? 'recognized locally' : 'not recognized locally'}');
    }
    out.writeln(
      '  Isolation: ${isolation['tier']} (read-only enforced: '
      '${isolation['readOnlyEnforced']})',
    );
    final change = doc['change'];
    if (change is Map) {
      out.writeln(
        '  Change:    ${change['fromVersion']} -> ${change['toVersion']}; '
        'access increased: ${change['accessIncreased']}; '
        'signer changed: ${change['signerChanged']}',
      );
    }
    out.writeln();
    out.writeln(doc['statement']);
    out.writeln();
    out.writeln('To accept exactly this, rerun with:');
    out.writeln('  --accept ${result['documentHash']}');
  }
}
