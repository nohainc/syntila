import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart'
    show ToolPins, toolDefinitionHash;
import 'package:syntila_plugin_protocol/syntila_plugin_protocol.dart';

import 'worker_trust_policy.dart' show canonicalJson;
import 'plugin_registry.dart';
import 'plugin_store.dart';
import 'plugin_signer_trust.dart';

/// Cloud operations the plugin service needs. The HTTP implementation talks to
/// the account library and enablement routes; tests substitute a fake.
abstract interface class PluginCloudPort {
  /// Creates or finds the account-library entry and returns its `pluginRef`.
  /// Cloud re-checks the paid feature and recomputes the manifest digest.
  Future<String> registerVersion({
    required Map<String, Object?> manifest,
    required String manifestDigest,
    required Map<String, Object?> origin,
    required Map<String, Object?>? signer,
  });

  /// Records (or clears) this Workspace's pin. Enabling is paid; disabling
  /// never is.
  Future<void> setEnablement({
    required String pluginRef,
    required String version,
    required String manifestDigest,
    required String consentHash,
    required bool enabled,
    required bool shareable,
  });

  Future<void> removeFromLibrary(String pluginRef);
}

/// A Cloud failure with a management-IPC error code, for example
/// `paid_plan_required`, `login_required` or `cloud_unavailable`.
class PluginCloudException implements Exception {
  const PluginCloudException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Runs the protocol conformance suite for an installed plugin inside the
/// Engine. The service never spawns the plugin itself.
abstract interface class PluginConformancePort {
  Future<Map<String, Object?>> run(
    InstalledPlugin plugin, {
    required String workerTypeId,
    required bool declaresResume,
    required Map<String, Object?> declaredCapabilities,
    void Function(String progress)? onProgress,
  });
}

/// Lists an MCP Worker's tools by running it through the Engine (ADR-028). The
/// Service never starts the server itself. Throws [PluginServiceException].
abstract interface class PluginMcpInspectPort {
  /// Starts the server, requires the Syntila Worker profile marker, and returns
  /// its current `tools/list`.
  Future<List<Map<String, Object?>>> listWorkerTools(InstalledPlugin plugin);
}

/// Makes an enabled plugin an ordinary local Worker so it flows through the
/// existing registry, readiness, inventory and scheduling paths.
abstract interface class PluginWorkerHost {
  /// Creates or re-enables the local Worker for [pluginRef].
  Future<void> activate({
    required String pluginRef,
    required String pluginId,
    required String displayName,
  });

  /// Stops scheduling the Worker; running work finishes.
  Future<void> deactivate(String pluginRef);

  /// Deletes the local Worker record.
  Future<void> remove(String pluginRef);
}

class _NoPluginWorkerHost implements PluginWorkerHost {
  const _NoPluginWorkerHost();
  @override
  Future<void> activate({
    required String pluginRef,
    required String pluginId,
    required String displayName,
  }) async {}
  @override
  Future<void> deactivate(String pluginRef) async {}
  @override
  Future<void> remove(String pluginRef) async {}
}

const pluginConsentStatement =
    'This program runs as you and can do anything you can do. The access list '
    'above is what it says it needs, not a restriction.';

/// The management commands for plugins. All state changes happen here; the CLI
/// only sends requests and prints results.
class WorkspacePluginService {
  WorkspacePluginService({
    required this.store,
    required this.registry,
    required this.cloud,
    required this.conformance,
    this.activeAssignments = _none,
    this.workerHost = const _NoPluginWorkerHost(),
    this.mcpInspect,
    DateTime Function()? clock,
    PluginSignerTrust? signerTrust,
  })  : _clock = clock ?? DateTime.now,
        signerTrust = signerTrust ??
            PluginSignerTrust(
                File('${registry.file.parent.path}/trusted-signers.json'));

  static Future<int> _none(String pluginRef) async => 0;

  final PluginStore store;
  final PluginRegistry registry;
  final PluginSignerTrust signerTrust;
  final PluginCloudPort cloud;
  final PluginConformancePort conformance;

  final PluginWorkerHost workerHost;

  /// Needed only for MCP Workers; null makes `plugins test` refuse them.
  final PluginMcpInspectPort? mcpInspect;

  /// Running or queued assignments for a plugin Worker (by `pluginRef`).
  final Future<int> Function(String pluginRef) activeAssignments;
  final DateTime Function() _clock;

  // ---- reads -------------------------------------------------------------------

  Future<Map<String, Object?>> list() async {
    final records = await registry.all();
    return {
      'schemaVersion': 1,
      'plugins': [
        for (final record in records.values) _summary(record),
      ],
    };
  }

  Future<Map<String, Object?>> show(String pluginId, [String? version]) async {
    final record = await _record(pluginId);
    final selected = _version(record, version);
    return {
      'schemaVersion': 1,
      ..._summary(record),
      'selected': {
        ..._versionJson(selected),
        'signerTrustedLocally': selected.signer != null &&
            await signerTrust.contains(selected.signer!.fingerprint),
      },
    };
  }

  Map<String, Object?> _summary(PluginRecord record) {
    final pin = record.pin;
    final intent = pin?.intent;
    return {
      'pluginId': record.pluginId,
      'displayName': record.displayName,
      if (record.pluginRef != null) 'pluginRef': record.pluginRef,
      'versions': [
        for (final v in record.versions.values) _versionJson(v),
      ],
      if (pin != null)
        'workspace': {
          'pinnedVersion': pin.version,
          'manifestDigest': pin.manifestDigest,
          'intent': intent,
          // Plan limits apply when Cloud schedules work, not here.
          'effective': pin.enabled ? 'enabled' : 'disabled',
          'shareable': pin.shareable,
        },
    };
  }

  Map<String, Object?> _versionJson(PluginVersionRecord v) => {
        'version': v.version,
        'manifestDigest': v.manifestDigest,
        'artifactDigest': v.artifactDigest,
        'origin': v.origin.toJson(),
        if (v.signer != null) 'signer': v.signer!.toJson(),
        'registered': v.registeredAt != null,
        if (v.conformance != null) 'conformance': v.conformance!.toJson(),
      };

  // Signer recognition does not bypass digest, consent or conformance.
  Future<Map<String, Object?>> signers() async => {
        'schemaVersion': 1,
        'signers': await signerTrust.all(),
        'scope': 'installation',
        'statement':
            'A recognized key is not a safety assessment or execution permission.',
      };

  Future<Map<String, Object?>> trustSigner(String pluginId,
      {String? version, String? acceptHash}) async {
    final record = await _record(pluginId);
    final selected = _version(record, version);
    // Re-read the signature and artifact; never trust the registry's claim.
    final installed = await _load(selected, pluginId);
    final signer = installed.signer;
    if (signer == null || !signer.verified) {
      throw const PluginServiceException('plugin_signature_required',
          'A verified package signature is required to recognize a signer.');
    }
    final document = <String, Object?>{
      'operation': 'trustSigner',
      'scope': 'installation',
      'pluginId': installed.pluginId,
      'version': installed.version,
      'manifestDigest': installed.manifestDigest,
      'fingerprint': signer.fingerprint,
      'statement': 'Verify this fingerprint through a trusted source. '
          'Recognizing a key does not verify an author name, establish safety, '
          'or approve any plugin execution or update.',
    };
    final hash = consentHash(document);
    if (acceptHash != hash) {
      return {
        'schemaVersion': 1,
        'consentRequired': true,
        'document': document,
        'documentHash': hash
      };
    }
    await signerTrust.pin(signer.fingerprint, _clock());
    return {
      'schemaVersion': 1,
      'trustedLocally': true,
      'fingerprint': signer.fingerprint,
      'scope': 'installation'
    };
  }

  Future<Map<String, Object?>> untrustSigner(String fingerprint) async => {
        'schemaVersion': 1,
        'fingerprint': fingerprint,
        'removed': await signerTrust.remove(fingerprint),
        'scope': 'installation',
      };

  // ---- lifecycle -----------------------------------------------------------------

  Future<Map<String, Object?>> import(String path) async {
    final installed = await store.import(path);
    await registry.mutate((records) {
      final record = records.putIfAbsent(
        installed.pluginId,
        () => PluginRecord(
          pluginId: installed.pluginId,
          displayName: installed.manifest.displayName,
        ),
      );
      record.displayName = installed.manifest.displayName;
      record.versions.putIfAbsent(
        installed.version,
        () => PluginVersionRecord(
          version: installed.version,
          manifestDigest: installed.manifestDigest,
          artifactDigest: installed.artifactDigest,
          origin: installed.origin,
          signer: installed.signer,
        ),
      );
    });
    return {
      'schemaVersion': 1,
      'pluginId': installed.pluginId,
      'version': installed.version,
      'manifestDigest': installed.manifestDigest,
      'artifactDigest': installed.artifactDigest,
      'origin': installed.origin.toJson(),
      if (installed.signer != null) 'signer': installed.signer!.toJson(),
      'next': 'validate, then test, then register',
    };
  }

  /// Static re-verification of the stored files. Never starts the plugin and
  /// is free, so authors and downgraded users can always check a package.
  Future<Map<String, Object?>> validate(String pluginId,
      [String? version]) async {
    final record = await _record(pluginId);
    final selected = _version(record, version);
    final installed = await _load(selected, pluginId);
    final warnings = <String>[];
    if (installed.signer == null) warnings.add('unsigned');
    return {
      'schemaVersion': 1,
      'valid': true,
      'pluginId': pluginId,
      'version': selected.version,
      'manifestDigest': installed.manifestDigest,
      'protocol': negotiatePluginProtocol(installed.manifest),
      'platform': installed.platform,
      'warnings': warnings,
    };
  }

  Future<Map<String, Object?>> test(
    String pluginId, {
    String? version,
    void Function(String progress)? onProgress,
  }) async {
    final record = await _record(pluginId);
    final selected = _version(record, version);
    final installed = await _load(selected, pluginId);
    if (installed.manifest.isMcp) {
      return _testMcp(pluginId, selected, installed);
    }
    final capabilities = Map<String, Object?>.from(
      installed.manifest.raw['capabilities'] as Map,
    );
    final report = await conformance.run(
      installed,
      workerTypeId: record.pluginRef ?? 'plugin-000000000000',
      declaresResume: capabilities['sessionResume'] == true ||
          (capabilities['continuity'] is Map &&
              const {'native_handle', 'checkpoint'}
                  .contains((capabilities['continuity'] as Map)['strategy'])),
      declaredCapabilities: capabilities,
      onProgress: onProgress,
    );
    final cases = List<Map<String, Object?>>.from(
      (report['cases'] as List).map((c) => Map<String, Object?>.from(c as Map)),
    );
    await registry.mutate((records) {
      final stored = records[pluginId]?.versions[selected.version];
      if (stored == null || stored.manifestDigest != selected.manifestDigest) {
        return;
      }
      stored.conformance = PluginConformanceRecord(
        suiteVersion: report['suiteVersion'] as String,
        protocol: report['protocol'] as String,
        passed: report['passed'] == true,
        at: _clock().toUtc(),
        failedCases: [
          for (final c in cases)
            if (c['status'] == 'failed') c['id'] as String,
        ],
      );
    });
    return {
      'schemaVersion': 1,
      ...report,
      'disclaimer':
          'Conformance shows protocol behavior only; it is not a safety assessment.',
    };
  }

  /// MCP Workers have no NDJSON conformance suite. This checks only that the
  /// server, run by the Engine, advertises the Syntila Worker profile and
  /// provides the required tools, and pins their definitions for consent.
  Future<Map<String, Object?>> _testMcp(
    String pluginId,
    PluginVersionRecord selected,
    InstalledPlugin installed,
  ) async {
    final inspect = mcpInspect;
    if (inspect == null) {
      throw const PluginServiceException(
        'plugin_mcp_unavailable',
        'MCP Workers are not available on this Workspace.',
      );
    }
    final tools = await inspect.listWorkerTools(installed);
    final names = {for (final t in tools) '${t['name']}'};
    final cases = <Map<String, Object?>>[
      {
        'id': 'mcp.profile_advertised',
        'status': 'passed',
        'detail': 'The server advertises the Syntila Worker profile.',
      },
      for (final required in const ['syntila.execute', 'syntila.probe'])
        {
          'id': 'mcp.tool.$required',
          'status': names.contains(required) ? 'passed' : 'failed',
          if (!names.contains(required)) 'detail': 'The tool is missing.',
        },
    ];
    final passed = cases.every((c) => c['status'] == 'passed');
    final definitions = [
      for (final t in tools)
        {
          'name': '${t['name']}',
          'description': '${t['description'] ?? ''}',
          'hash': toolDefinitionHash(t),
        },
    ]..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    await registry.mutate((records) {
      final stored = records[pluginId]?.versions[selected.version];
      if (stored == null || stored.manifestDigest != selected.manifestDigest) {
        return;
      }
      stored.toolPins = ToolPins.fromTools(tools).hashes;
      stored.toolDefinitions = definitions;
      stored.conformance = PluginConformanceRecord(
        suiteVersion: 'mcp-worker-profile-1',
        protocol: 'syntila.worker/1',
        passed: passed,
        at: _clock().toUtc(),
        failedCases: [
          for (final c in cases)
            if (c['status'] == 'failed') c['id'] as String,
        ],
      );
    });
    return {
      'schemaVersion': 1,
      'suiteVersion': 'mcp-worker-profile-1',
      'protocol': 'syntila.worker/1',
      'passed': passed,
      'cases': cases,
      'disclaimer':
          'This checks that the server advertises the Syntila Worker profile '
              'and provides the required tools. It is not a behavioural '
              'conformance suite and not a safety assessment.',
    };
  }

  /// Two-step by content: without the matching [acceptHash] the result carries
  /// the consent document and its hash; with it the registration happens. The
  /// hash covers the digest, so a changed package can never reuse consent.
  Future<Map<String, Object?>> register(
    String pluginId, {
    String? version,
    String? acceptHash,
  }) async {
    final record = await _record(pluginId);
    final selected = _version(record, version);
    final installed = await _load(selected, pluginId);
    _requireConformance(selected);
    final document = await _consentDocument(
      'register',
      installed,
      record: record,
    );
    final hash = consentHash(document);
    if (acceptHash != hash) {
      return {
        'schemaVersion': 1,
        'consentRequired': true,
        'document': document,
        'documentHash': hash,
      };
    }
    final String ref;
    try {
      ref = await cloud.registerVersion(
        manifest: installed.manifest.raw,
        manifestDigest: installed.manifestDigest,
        origin: installed.origin.toJson(),
        signer: installed.signer?.toJson(),
      );
    } on PluginCloudException catch (error) {
      throw PluginServiceException(error.code, error.message);
    }
    await registry.mutate((records) {
      final stored = records[pluginId]!;
      stored.pluginRef = ref;
      stored.versions[selected.version]!.registeredAt = _clock().toUtc();
    });
    return {
      'schemaVersion': 1,
      'registered': true,
      'pluginRef': ref,
      'version': selected.version,
      'manifestDigest': installed.manifestDigest,
    };
  }

  Future<Map<String, Object?>> enable(
    String pluginId, {
    String? version,
    String? acceptHash,
    bool shareable = false,
  }) async {
    final record = await _record(pluginId);
    final selected = _version(record, version ?? _latestRegistered(record));
    if (selected.registeredAt == null || record.pluginRef == null) {
      throw const PluginServiceException(
        'plugin_conformance_required',
        'Register this plugin version before enabling it.',
      );
    }
    final installed = await _load(selected, pluginId);
    _requireConformance(selected);
    final document = await _consentDocument(
      'enable',
      installed,
      record: record,
      shareable: shareable,
    );
    final hash = consentHash(document);
    if (acceptHash != hash) {
      return {
        'schemaVersion': 1,
        'consentRequired': true,
        'document': document,
        'documentHash': hash,
      };
    }
    try {
      await cloud.setEnablement(
        pluginRef: record.pluginRef!,
        version: selected.version,
        manifestDigest: selected.manifestDigest,
        consentHash: hash,
        enabled: true,
        shareable: shareable,
      );
    } on PluginCloudException catch (error) {
      throw PluginServiceException(error.code, error.message);
    }
    await registry.mutate((records) {
      records[pluginId]!.pin = PluginPin(
        version: selected.version,
        manifestDigest: selected.manifestDigest,
        intent: 'enabled',
        consentHash: hash,
        acceptedAt: _clock().toUtc(),
        shareable: shareable,
      );
    });
    await workerHost.activate(
      pluginRef: record.pluginRef!,
      pluginId: pluginId,
      displayName: installed.manifest.displayName,
    );
    return {
      'schemaVersion': 1,
      'enabled': true,
      'pluginRef': record.pluginRef,
      'version': selected.version,
    };
  }

  /// Always allowed. The local intent is recorded first so a lapsed or offline
  /// Workspace can still stop a plugin; Cloud is told on a best-effort basis.
  Future<Map<String, Object?>> disable(String pluginId) async {
    final record = await _record(pluginId);
    final pin = record.pin;
    if (pin == null) {
      throw const PluginServiceException(
        'plugin_not_enabled',
        'This plugin is not enabled on this Workspace.',
      );
    }
    await registry
        .mutate((records) => records[pluginId]!.pin!.intent = 'disabled');
    var cloudSynced = true;
    if (record.pluginRef != null) {
      try {
        await cloud.setEnablement(
          pluginRef: record.pluginRef!,
          version: pin.version,
          manifestDigest: pin.manifestDigest,
          consentHash: pin.consentHash,
          enabled: false,
          shareable: pin.shareable,
        );
      } on PluginCloudException {
        cloudSynced = false;
      }
    }
    if (record.pluginRef != null) {
      await workerHost.deactivate(record.pluginRef!);
    }
    return {
      'schemaVersion': 1,
      'disabled': true,
      'cloudSynced': cloudSynced,
      'draining': record.pluginRef == null
          ? 0
          : await activeAssignments(record.pluginRef!),
    };
  }

  Future<Map<String, Object?>> remove(String pluginId) async {
    final record = await _record(pluginId);
    if (record.pin?.enabled == true) {
      throw const PluginServiceException(
        'plugin_in_use',
        'Disable this plugin before removing it.',
      );
    }
    final ref = record.pluginRef;
    if (ref != null && await activeAssignments(ref) > 0) {
      throw const PluginServiceException(
        'plugin_in_use',
        'This plugin still has running work. Remove it when that finishes.',
      );
    }
    if (ref != null) {
      try {
        // A prior offline disable changes local intent first. Reconcile that
        // intent before asking Cloud to remove the account-wide library entry.
        final pin = record.pin;
        if (pin != null) {
          await cloud.setEnablement(
            pluginRef: ref,
            version: pin.version,
            manifestDigest: pin.manifestDigest,
            consentHash: pin.consentHash,
            enabled: false,
            shareable: pin.shareable,
          );
        }
        await cloud.removeFromLibrary(ref);
      } on PluginCloudException catch (error) {
        throw PluginServiceException(error.code, error.message);
      }
    }
    if (ref != null) await workerHost.remove(ref);
    await store.removePlugin(pluginId);
    await registry.mutate((records) => records.remove(pluginId));
    return {'schemaVersion': 1, 'removed': true, 'state': 'removed'};
  }

  /// Free, offline and lapsed: export only reads local files.
  Future<Map<String, Object?>> export(
    String pluginId,
    String outputPath, {
    String? version,
  }) async {
    final record = await _record(pluginId);
    final selected = _version(record, version);
    final installed = await _load(selected, pluginId);
    await store.export(installed, outputPath);
    return {
      'schemaVersion': 1,
      'exported': true,
      'pluginId': pluginId,
      'version': selected.version,
      'manifestDigest': installed.manifestDigest,
    };
  }

  // ---- internals -----------------------------------------------------------------

  Future<PluginRecord> _record(String pluginId) async {
    final record = await registry.find(pluginId);
    if (record == null) {
      throw const PluginServiceException(
        'plugin_not_found',
        'No such plugin on this Workspace.',
      );
    }
    return record;
  }

  PluginVersionRecord _version(PluginRecord record, String? version) {
    if (version != null) {
      final found = record.versions[version];
      if (found == null) {
        throw const PluginServiceException(
          'plugin_not_found',
          'No such plugin version on this Workspace.',
        );
      }
      return found;
    }
    final latest = _latest(record);
    if (latest == null) {
      throw const PluginServiceException(
        'plugin_not_found',
        'No such plugin on this Workspace.',
      );
    }
    return latest;
  }

  PluginVersionRecord? _latest(PluginRecord record) {
    if (record.versions.isEmpty) return null;
    return record.versions.values.reduce(
      (a, b) => _compareVersions(a.version, b.version) >= 0 ? a : b,
    );
  }

  String? _latestRegistered(PluginRecord record) {
    final registered = record.versions.values.where(
      (v) => v.registeredAt != null,
    );
    if (registered.isEmpty) return null;
    return registered
        .reduce((a, b) => _compareVersions(a.version, b.version) >= 0 ? a : b)
        .version;
  }

  static int _compareVersions(String a, String b) {
    final left = a.split('.').map(int.parse).toList();
    final right = b.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      final c = left[i].compareTo(right[i]);
      if (c != 0) return c;
    }
    return 0;
  }

  Future<InstalledPlugin> _load(PluginVersionRecord v, String pluginId) =>
      store.load(
        pluginId,
        v.version,
        v.manifestDigest,
        origin: v.origin,
        signer: v.signer,
      );

  void _requireConformance(PluginVersionRecord v) {
    final result = v.conformance;
    if (result == null || !result.passed) {
      throw const PluginServiceException(
        'plugin_conformance_required',
        'Run "plugins test" and pass the conformance suite for this exact '
            'version first.',
      );
    }
  }

  /// What the person must see and accept. It contains no secrets and no paths.
  Future<Map<String, Object?>> _consentDocument(
    String operation,
    InstalledPlugin installed, {
    required PluginRecord record,
    bool shareable = false,
  }) async {
    final manifest = installed.manifest.raw;
    final author = Map<String, Object?>.from(manifest['author'] as Map);
    final access = Map<String, Object?>.from(manifest['access'] as Map);
    final pin = record.pin;
    return {
      'operation': operation,
      'plugin': {
        'id': installed.pluginId,
        'version': installed.version,
        'displayName': installed.manifest.displayName,
        // The key signature does not verify a claimed human/organization name.
        'author': author['name'],
        'authorVerified': false,
        'signatureVerified': installed.signer?.verified == true,
      },
      'origin': installed.origin.toJson()..remove('importedAt'),
      'digest': {
        'manifest': installed.manifestDigest,
        'artifact': installed.artifactDigest,
        'platform': installed.platform,
      },
      'requestedAccess': {
        ...access,
        'note': 'Declared by the plugin. Not enforced: the plugin runs as you.',
      },
      'capabilities': manifest['capabilities'],
      if (installed.manifest.isMcp)
        'mcp': {
          'profile': 'syntila.worker/1',
          // Descriptions come from the server and are untrusted; the hashes
          // are what the Engine enforces at run time.
          'tools': record.versions[installed.version]?.toolDefinitions ??
              const <Object?>[],
        },
      'requires': manifest['requires'] ?? const <Object?>[],
      'isolation': {
        'tier': 'none',
        'readOnlyEnforced': false,
        'note': 'A process boundary only; no filesystem or network sandbox.',
      },
      'signature': installed.signer == null
          ? {'status': 'unsigned'}
          : {
              'status': installed.signer!.verified ? 'verified' : 'invalid',
              'fingerprint': installed.signer!.fingerprint,
              'trustedLocally':
                  await signerTrust.contains(installed.signer!.fingerprint),
            },
      if (operation == 'enable') 'shareable': shareable,
      if (operation == 'enable' &&
          pin != null &&
          pin.manifestDigest != installed.manifestDigest)
        'change': await _change(pin, installed, record),
      'statement': pluginConsentStatement,
    };
  }

  /// What moves when the pin moves to [next]: any rise in requested access or
  /// a signer change is flagged. A previous version that can no longer be
  /// loaded is treated as an increase, the cautious reading.
  Future<Map<String, Object?>> _change(
    PluginPin pin,
    InstalledPlugin next,
    PluginRecord record,
  ) async {
    final previousRecord = record.versions[pin.version];
    Map<String, Object?>? previousAccess;
    if (previousRecord != null) {
      try {
        final previous = await _load(previousRecord, record.pluginId);
        previousAccess = Map<String, Object?>.from(
          previous.manifest.raw['access'] as Map,
        );
      } on PluginServiceException {
        previousAccess = null;
      }
    }
    final nextAccess = Map<String, Object?>.from(
      next.manifest.raw['access'] as Map,
    );
    return {
      'fromVersion': pin.version,
      'toVersion': next.version,
      'accessIncreased': previousAccess == null
          ? true
          : _accessIncreased(previousAccess, nextAccess),
      'signerChanged':
          previousRecord?.signer?.fingerprint != next.signer?.fingerprint,
    };
  }

  static bool _accessIncreased(
    Map<String, Object?> before,
    Map<String, Object?> after,
  ) {
    const rank = {'none': 0, 'read': 1, 'write': 2};
    if ((rank[after['workRoot']] ?? 0) > (rank[before['workRoot']] ?? 0)) {
      return true;
    }
    final beforeNetwork = (before['network'] as Map)['mode'];
    final afterNetwork = (after['network'] as Map)['mode'];
    if (beforeNetwork == 'none' && afterNetwork != 'none') return true;
    if (before['subprocess'] != true && after['subprocess'] == true) {
      return true;
    }
    final beforeEnv = Set<String>.from(before['env'] as List);
    return Set<String>.from(after['env'] as List)
        .difference(beforeEnv)
        .isNotEmpty;
  }
}

/// SHA-256 over the canonical consent document. Accepting a hash accepts
/// exactly this content, including the digest.
String consentHash(Map<String, Object?> document) =>
    sha256.convert(utf8.encode(canonicalJson(document))).toString();
