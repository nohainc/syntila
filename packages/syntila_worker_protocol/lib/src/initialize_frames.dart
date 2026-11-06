import 'dart:convert';

import 'executor_frames.dart';
import 'limits.dart';
import 'protocol_version.dart';

abstract class WorkerFrame {
  const WorkerFrame({required this.requestId});

  final String requestId;
  String get type;
  Map<String, Object?> toJson();

  String encode() {
    final json = jsonEncode(toJson());
    if (utf8.encode(json).length > WorkerProtocolLimits.maxFrameBytes) {
      throw const FormatException('Worker frame exceeds the byte limit');
    }
    return json;
  }
}

final class InitializeRequest extends WorkerFrame {
  InitializeRequest({
    required String requestId,
    required this.workerTypeId,
    required this.expectedEngineVersion,
    required this.profileDefinitionId,
    required this.profileReleaseVersion,
    required this.profileDigest,
    this.executor,
    this.protocolVersion = localWorkerProtocolVersion,
  }) : super(requestId: requestId) {
    _validateToken(
        requestId, 'requestId', WorkerProtocolLimits.maxRequestIdLength);
    _validateToken(workerTypeId, 'workerTypeId',
        WorkerProtocolLimits.maxWorkerTypeIdLength);
    _validateToken(expectedEngineVersion, 'expectedEngineVersion',
        WorkerProtocolLimits.maxEngineVersionLength);
    _validateToken(profileDefinitionId, 'profileDefinitionId',
        WorkerProtocolLimits.maxProfileDefinitionIdLength);
    _validateToken(profileReleaseVersion, 'profileReleaseVersion',
        WorkerProtocolLimits.maxProfileReleaseVersionLength);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(profileDigest)) {
      throw const FormatException(
          'profileDigest must be a lowercase SHA-256 hex digest');
    }
    _validateProtocol(protocolVersion);
    if (executor != null) {
      final required = executor!.isMcp
          ? mcpExecutorProtocolVersion
          : pluginExecutorProtocolVersion;
      if (protocolVersion != required) {
        throw FormatException('executor requires protocol $required');
      }
      if (executor!.manifestDigest != profileDigest) {
        throw const FormatException(
            'plugin initialization digest must equal the manifest digest');
      }
    }
  }

  final String protocolVersion;

  /// Plugin identity for a plugin-mode Engine (protocol 4.2). The wire fields
  /// `profileDefinitionId`/`profileReleaseVersion`/`profileDigest` then carry
  /// the plugin id, version and manifest digest.
  final WorkerExecutor? executor;
  final String workerTypeId;
  final String expectedEngineVersion;
  final String profileDefinitionId;

  /// Resolved Profile revision. The wire name is retained for Protocol 4.x
  /// compatibility with older Workspace/Engine builds.
  final String profileReleaseVersion;
  final String profileDigest;

  String get profileRevision => profileReleaseVersion;

  @override
  String get type => 'initialize.request';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'protocolVersion': protocolVersion,
        'requestId': requestId,
        'workerTypeId': workerTypeId,
        'expectedEngineVersion': expectedEngineVersion,
        'profileDefinitionId': profileDefinitionId,
        'profileReleaseVersion': profileReleaseVersion,
        'profileDigest': profileDigest,
        if (executor != null) 'executor': executor!.toJson(),
      };

  factory InitializeRequest.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'protocolVersion',
      'requestId',
      'workerTypeId',
      'expectedEngineVersion',
      'profileDefinitionId',
      'profileReleaseVersion',
      'profileDigest',
      'executor',
    });
    _checkType(json, 'initialize.request');
    if (json['executor'] != null && json['executor'] is! Map) {
      throw const FormatException('executor must be an object');
    }
    final protocol = _requiredString(json, 'protocolVersion');
    if (!supportedLocalWorkerProtocolVersions.contains(protocol)) {
      throw FormatException('unsupported protocol version: $protocol');
    }
    return InitializeRequest(
      requestId: _boundedString(
          json, 'requestId', WorkerProtocolLimits.maxRequestIdLength),
      protocolVersion: protocol,
      workerTypeId: _boundedString(
          json, 'workerTypeId', WorkerProtocolLimits.maxWorkerTypeIdLength),
      expectedEngineVersion: _boundedString(json, 'expectedEngineVersion',
          WorkerProtocolLimits.maxEngineVersionLength),
      profileDefinitionId: _boundedString(json, 'profileDefinitionId',
          WorkerProtocolLimits.maxProfileDefinitionIdLength),
      profileReleaseVersion: _boundedString(json, 'profileReleaseVersion',
          WorkerProtocolLimits.maxProfileReleaseVersionLength),
      profileDigest: _boundedString(
          json, 'profileDigest', WorkerProtocolLimits.maxProfileDigestLength),
      executor: json['executor'] == null
          ? null
          : WorkerExecutor.fromJson(
              Map<String, Object?>.from(json['executor'] as Map)),
    );
  }
}

final class InitializeResult extends WorkerFrame {
  InitializeResult({
    required super.requestId,
    required this.workerTypeId,
    required this.engineVersion,
    required this.profileDefinitionId,
    required this.profileReleaseVersion,
    required this.profileSchemaVersion,
    required Iterable<String> capabilities,
    this.protocolVersion = localWorkerProtocolVersion,
  }) : capabilities = List.unmodifiable(capabilities) {
    _validateToken(
        requestId, 'requestId', WorkerProtocolLimits.maxRequestIdLength);
    _validateToken(workerTypeId, 'workerTypeId',
        WorkerProtocolLimits.maxWorkerTypeIdLength);
    _validateToken(engineVersion, 'engineVersion',
        WorkerProtocolLimits.maxEngineVersionLength);
    _validateToken(profileDefinitionId, 'profileDefinitionId',
        WorkerProtocolLimits.maxProfileDefinitionIdLength);
    _validateToken(profileReleaseVersion, 'profileReleaseVersion',
        WorkerProtocolLimits.maxProfileReleaseVersionLength);
    _validateProtocol(protocolVersion);
    if (profileSchemaVersion < 1 ||
        profileSchemaVersion > WorkerProtocolLimits.maxProfileSchemaVersion) {
      throw const FormatException('profileSchemaVersion is out of range');
    }
    if (this.capabilities.length > WorkerProtocolLimits.maxCapabilities) {
      throw const FormatException('too many Worker capabilities');
    }
    if (this.capabilities.toSet().length != this.capabilities.length) {
      throw const FormatException('capabilities must not contain duplicates');
    }
    for (final capability in this.capabilities) {
      _validateToken(
          capability, 'capability', WorkerProtocolLimits.maxCapabilityLength);
      if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(capability)) {
        throw const FormatException(
            'capability must be a stable lowercase identifier');
      }
    }
  }

  final String protocolVersion;
  final String workerTypeId;
  final String engineVersion;
  final String profileDefinitionId;

  /// Resolved Profile revision. The wire name is retained for Protocol 4.x
  /// compatibility with older Workspace/Engine builds.
  final String profileReleaseVersion;
  final int profileSchemaVersion;
  final List<String> capabilities;

  String get profileRevision => profileReleaseVersion;

  @override
  String get type => 'initialize.result';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'protocolVersion': protocolVersion,
        'requestId': requestId,
        'workerTypeId': workerTypeId,
        'engineVersion': engineVersion,
        'profileDefinitionId': profileDefinitionId,
        'profileReleaseVersion': profileReleaseVersion,
        'profileSchemaVersion': profileSchemaVersion,
        'capabilities': capabilities,
      };

  factory InitializeResult.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'protocolVersion',
      'requestId',
      'workerTypeId',
      'engineVersion',
      'profileDefinitionId',
      'profileReleaseVersion',
      'profileSchemaVersion',
      'capabilities',
    });
    _checkType(json, 'initialize.result');
    final protocol = _requiredString(json, 'protocolVersion');
    if (!supportedLocalWorkerProtocolVersions.contains(protocol)) {
      throw FormatException('unsupported protocol version: $protocol');
    }
    final rawSchemaVersion = json['profileSchemaVersion'];
    if (rawSchemaVersion is! int) {
      throw const FormatException('profileSchemaVersion must be an integer');
    }
    final rawCapabilities = json['capabilities'];
    if (rawCapabilities is! List ||
        rawCapabilities.length > WorkerProtocolLimits.maxCapabilities) {
      throw const FormatException('capabilities must be a bounded array');
    }
    if (rawCapabilities.any((value) => value is! String)) {
      throw const FormatException('capabilities must contain only strings');
    }
    return InitializeResult(
      requestId: _boundedString(
          json, 'requestId', WorkerProtocolLimits.maxRequestIdLength),
      protocolVersion: protocol,
      workerTypeId: _boundedString(
          json, 'workerTypeId', WorkerProtocolLimits.maxWorkerTypeIdLength),
      engineVersion: _boundedString(
          json, 'engineVersion', WorkerProtocolLimits.maxEngineVersionLength),
      profileDefinitionId: _boundedString(json, 'profileDefinitionId',
          WorkerProtocolLimits.maxProfileDefinitionIdLength),
      profileReleaseVersion: _boundedString(json, 'profileReleaseVersion',
          WorkerProtocolLimits.maxProfileReleaseVersionLength),
      profileSchemaVersion: rawSchemaVersion,
      capabilities: rawCapabilities.cast<String>(),
    );
  }
}

void _checkType(Map<String, Object?> json, String expected) {
  if (json['type'] != expected)
    throw FormatException('expected $expected frame');
}

void _expectKeys(Map<String, Object?> json, Set<String> allowed) {
  final unknown = json.keys.where((key) => !allowed.contains(key));
  if (unknown.isNotEmpty)
    throw FormatException('frame contains unsupported field: ${unknown.first}');
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty)
    throw FormatException('$key must be a non-empty string');
  return value;
}

String _boundedString(Map<String, Object?> json, String key, int limit) {
  final value = _requiredString(json, key);
  _validateToken(value, key, limit);
  return value;
}

void _validateToken(String value, String name, int maxLength) {
  if (value.trim().isEmpty || value.length > maxLength) {
    throw FormatException('$name is empty or exceeds $maxLength characters');
  }
}

void _validateProtocol(String value) {
  if (!supportedLocalWorkerProtocolVersions.contains(value))
    throw FormatException('unsupported protocol version: $value');
}
