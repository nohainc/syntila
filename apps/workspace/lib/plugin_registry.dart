import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'plugin_store.dart';

/// Result of the last conformance run for one exact manifest digest. Only a
/// run through the Engine satisfies the `plugin_conformance_required` gate.
class PluginConformanceRecord {
  const PluginConformanceRecord({
    required this.suiteVersion,
    required this.protocol,
    required this.passed,
    required this.at,
    required this.failedCases,
  });

  final String suiteVersion;
  final String protocol;
  final bool passed;
  final DateTime at;
  final List<String> failedCases;

  Map<String, Object?> toJson() => {
        'suiteVersion': suiteVersion,
        'protocol': protocol,
        'passed': passed,
        'at': at.toUtc().toIso8601String(),
        'failedCases': failedCases,
      };

  factory PluginConformanceRecord.fromJson(Map<String, Object?> json) =>
      PluginConformanceRecord(
        suiteVersion: json['suiteVersion'] as String,
        protocol: json['protocol'] as String,
        passed: json['passed'] == true,
        at: DateTime.parse(json['at'] as String),
        failedCases: List<String>.from(json['failedCases'] as List),
      );
}

class PluginVersionRecord {
  PluginVersionRecord({
    required this.version,
    required this.manifestDigest,
    required this.artifactDigest,
    required this.origin,
    this.signer,
    this.conformance,
    this.registeredAt,
  });

  final String version;
  final String manifestDigest;
  final String artifactDigest;
  final PluginOrigin origin;
  final PluginSigner? signer;
  PluginConformanceRecord? conformance;

  /// MCP Workers only: tool name -> definition hash recorded by `plugins test`
  /// and shown at consent. The Engine refuses any tool that differs.
  Map<String, String>? toolPins;

  /// MCP Workers only: what the person saw at consent (name, description, hash).
  List<Map<String, Object?>>? toolDefinitions;
  DateTime? registeredAt;

  Map<String, Object?> toJson() => {
        'version': version,
        'manifestDigest': manifestDigest,
        'artifactDigest': artifactDigest,
        'origin': origin.toJson(),
        if (signer != null) 'signer': signer!.toJson(),
        if (conformance != null) 'conformance': conformance!.toJson(),
        if (toolPins != null) 'toolPins': toolPins,
        if (toolDefinitions != null) 'toolDefinitions': toolDefinitions,
        if (registeredAt != null)
          'registeredAt': registeredAt!.toUtc().toIso8601String(),
      };

  factory PluginVersionRecord.fromJson(Map<String, Object?> json) =>
      PluginVersionRecord(
        version: json['version'] as String,
        manifestDigest: json['manifestDigest'] as String,
        artifactDigest: json['artifactDigest'] as String,
        origin: PluginOrigin.fromJson(
          Map<String, Object?>.from(json['origin'] as Map),
        ),
        signer: json['signer'] == null
            ? null
            : PluginSigner.fromJson(
                Map<String, Object?>.from(json['signer'] as Map),
              ),
        conformance: json['conformance'] == null
            ? null
            : PluginConformanceRecord.fromJson(
                Map<String, Object?>.from(json['conformance'] as Map),
              ),
        registeredAt: json['registeredAt'] == null
            ? null
            : DateTime.parse(json['registeredAt'] as String),
      )
        ..toolPins = json['toolPins'] == null
            ? null
            : Map<String, String>.from(json['toolPins'] as Map)
        ..toolDefinitions = json['toolDefinitions'] == null
            ? null
            : [
                for (final d in json['toolDefinitions'] as List)
                  Map<String, Object?>.from(d as Map),
              ];
}

/// The version this Workspace runs and the user's intent for it. Intent is
/// preserved when entitlement lapses: effective state is intent AND entitled.
class PluginPin {
  PluginPin({
    required this.version,
    required this.manifestDigest,
    required this.intent,
    required this.consentHash,
    required this.acceptedAt,
    this.shareable = false,
  });

  final String version;
  final String manifestDigest;

  /// `enabled` or `disabled`.
  String intent;
  final String consentHash;
  final DateTime acceptedAt;
  final bool shareable;

  bool get enabled => intent == 'enabled';

  Map<String, Object?> toJson() => {
        'version': version,
        'manifestDigest': manifestDigest,
        'intent': intent,
        'consentHash': consentHash,
        'acceptedAt': acceptedAt.toUtc().toIso8601String(),
        'shareable': shareable,
      };

  factory PluginPin.fromJson(Map<String, Object?> json) => PluginPin(
        version: json['version'] as String,
        manifestDigest: json['manifestDigest'] as String,
        intent: json['intent'] as String,
        consentHash: json['consentHash'] as String,
        acceptedAt: DateTime.parse(json['acceptedAt'] as String),
        shareable: json['shareable'] == true,
      );
}

class PluginRecord {
  PluginRecord({required this.pluginId, required this.displayName});

  final String pluginId;
  String displayName;

  /// Cloud-allocated Worker Type ID (`plugin-` + 12 hex), set at registration.
  String? pluginRef;
  final Map<String, PluginVersionRecord> versions = {};
  PluginPin? pin;

  Map<String, Object?> toJson() => {
        'pluginId': pluginId,
        'displayName': displayName,
        if (pluginRef != null) 'pluginRef': pluginRef,
        'versions': {for (final e in versions.entries) e.key: e.value.toJson()},
        if (pin != null) 'pin': pin!.toJson(),
      };

  factory PluginRecord.fromJson(Map<String, Object?> json) {
    final record = PluginRecord(
      pluginId: json['pluginId'] as String,
      displayName: json['displayName'] as String,
    )..pluginRef = json['pluginRef'] as String?;
    final versions = Map<String, Object?>.from(json['versions'] as Map);
    for (final entry in versions.entries) {
      record.versions[entry.key] = PluginVersionRecord.fromJson(
        Map<String, Object?>.from(entry.value as Map),
      );
    }
    if (json['pin'] != null) {
      record.pin = PluginPin.fromJson(
        Map<String, Object?>.from(json['pin'] as Map),
      );
    }
    return record;
  }
}

/// Local plugin state in the Service's private directory. It is a record of
/// user intent and verification results, not an authority: Cloud decides what
/// is scheduled, and the store re-hashes bytes before anything can run.
class PluginRegistry {
  PluginRegistry(this.file);

  final File file;
  Future<void> _tail = Future<void>.value();

  Future<Map<String, PluginRecord>> _read() async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['schemaVersion'] != 1) return {};
      final plugins = Map<String, Object?>.from(decoded['plugins'] as Map);
      return {
        for (final e in plugins.entries)
          e.key:
              PluginRecord.fromJson(Map<String, Object?>.from(e.value as Map)),
      };
    } on Object {
      return {};
    }
  }

  Future<void> _write(Map<String, PluginRecord> records) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'plugins': {for (final e in records.entries) e.key: e.value.toJson()},
      }),
      flush: true,
    );
    await temp.rename(file.path);
    if (!Platform.isWindows) await Process.run('chmod', ['600', file.path]);
  }

  Future<Map<String, PluginRecord>> all() =>
      _run((records) => records, write: false);

  Future<PluginRecord?> find(String pluginId) async => (await all())[pluginId];

  /// The record registered under a Cloud-allocated `pluginRef`.
  Future<PluginRecord?> findByRef(String pluginRef) async => (await all())
      .values
      .where((record) => record.pluginRef == pluginRef)
      .firstOrNull;

  /// Serialized read-modify-write; the callback may change the records.
  Future<T> mutate<T>(T Function(Map<String, PluginRecord> records) change) =>
      _run(change, write: true);

  Future<T> _run<T>(
    T Function(Map<String, PluginRecord> records) change, {
    required bool write,
  }) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        final records = await _read();
        final result = change(records);
        if (write) await _write(records);
        completer.complete(result);
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
