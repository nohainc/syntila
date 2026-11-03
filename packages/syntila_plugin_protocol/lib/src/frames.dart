import 'dart:convert';

import 'limits.dart';

enum PluginDirection { hostToPlugin, pluginToHost }

class PluginFrameException implements Exception {
  const PluginFrameException(this.message);
  final String message;

  @override
  String toString() => 'PluginFrameException: $message';
}

const _hostToPluginTypes = <String>{
  'hello',
  'probe',
  'execute',
  'cancel',
  'ping',
  'pong',
  'shutdown',
};

const _pluginToHostTypes = <String>{
  'hello.result',
  'probe.result',
  'progress',
  'activity',
  'result',
  'error',
  'ping',
  'pong',
};

const _probeStates = <String>{
  'ready',
  'setup_required',
  'sign_in_required',
  'unavailable',
  'failed',
};

const _activityTypes = <String>{
  'execution.started',
  'model.started',
  'message.updated',
  'tool.started',
  'tool.completed',
  'tool.failed',
  'model.status',
  'execution.completed',
  'execution.failed',
  'execution.cancelled',
};

final _idPattern = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');
final _issueCodePattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
final _pluginProtocolPattern = RegExp(r'^1\.(0|[1-9][0-9]*)$');

/// A validated protocol frame. `json` is the decoded object; typed access to
/// common fields is provided, everything else is read from `json`.
final class PluginFrame {
  PluginFrame(this.type, Map<String, Object?> json)
      : json = Map<String, Object?>.unmodifiable(json);

  final String type;
  final Map<String, Object?> json;

  String? get id => json['id'] as String?;

  bool get isTerminal => type == 'result' || type == 'error';

  /// One NDJSON line without the trailing newline.
  String encode() {
    final line = jsonEncode(json);
    if (utf8.encode(line).length + 1 > PluginProtocolLimits.maxFrameBytes) {
      throw const PluginFrameException('frame exceeds the byte limit');
    }
    return line;
  }

  static PluginFrame hello({
    required String id,
    required String hostVersion,
    required String dataDir,
  }) =>
      PluginFrame('hello', {
        'type': 'hello',
        'id': id,
        'protocol': {
          'supported': PluginProtocolLimits.supportedProtocolVersions.toList(),
          'preferred': PluginProtocolLimits.protocolVersion,
        },
        'host': {'name': 'syntila-engine', 'version': hostVersion},
        'dataDir': dataDir,
        'limits': {
          'maxFrameBytes': PluginProtocolLimits.maxFrameBytes,
          'maxPromptBytes': PluginProtocolLimits.maxPromptBytes,
          'maxOutputBytes': PluginProtocolLimits.maxOutputBytes,
        },
      });

  static PluginFrame probe({required String id, required String mode}) =>
      PluginFrame('probe', {'type': 'probe', 'id': id, 'mode': mode});

  static PluginFrame execute({
    required String id,
    required int deadlineMs,
    required String prompt,
    required String workingDirectory,
    required String access,
    String? model,
    String? sessionKey,
    String sessionMode = 'new',
  }) =>
      PluginFrame('execute', {
        'type': 'execute',
        'id': id,
        'deadlineMs': deadlineMs,
        'prompt': prompt,
        'workingDirectory': workingDirectory,
        'access': access,
        if (model != null) 'model': model,
        if (sessionKey != null)
          'session': {'key': sessionKey, 'mode': sessionMode},
        'attachments': <Object?>[],
      });

  static PluginFrame cancel({required String id, String reason = 'user'}) =>
      PluginFrame('cancel', {'type': 'cancel', 'id': id, 'reason': reason});

  static PluginFrame ping(String nonce) =>
      PluginFrame('ping', {'type': 'ping', 'nonce': nonce});

  static PluginFrame pong(String nonce) =>
      PluginFrame('pong', {'type': 'pong', 'nonce': nonce});

  static PluginFrame shutdown() =>
      PluginFrame('shutdown', {'type': 'shutdown'});
}

/// Maps an unrecognized plugin error code to `internal`.
String normalizePluginErrorCode(String code) =>
    pluginErrorCodes.contains(code) ? code : 'internal';

/// True for a relative path that stays inside its base: no absolute form, no
/// drive letter, no empty or `..` segment, no NUL.
bool isSafePluginRelativePath(String path) {
  if (path.isEmpty || path.length > PluginProtocolLimits.maxPathLength) {
    return false;
  }
  if (path.contains('\u0000') ||
      path.startsWith('/') ||
      path.startsWith(r'\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(path)) {
    return false;
  }
  for (final segment in path.split(RegExp(r'[\\/]'))) {
    if (segment.isEmpty || segment == '..') return false;
  }
  return true;
}

/// Parses and validates one NDJSON line. Unknown fields are ignored; an
/// unknown or wrong-direction `type`, a missing or out-of-bound field, or an
/// oversize line throws [PluginFrameException].
PluginFrame decodePluginFrame(String line, PluginDirection direction) {
  var text = line;
  if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
  if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
  if (utf8.encode(text).length + 1 > PluginProtocolLimits.maxFrameBytes) {
    throw const PluginFrameException('frame exceeds the byte limit');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const PluginFrameException('frame is not valid JSON');
  }
  if (decoded is! Map) {
    throw const PluginFrameException('frame must be a JSON object');
  }
  final json = Map<String, Object?>.from(decoded);
  final type = json['type'];
  if (type is! String) {
    throw const PluginFrameException('frame type must be a string');
  }
  final allowed = direction == PluginDirection.hostToPlugin
      ? _hostToPluginTypes
      : _pluginToHostTypes;
  if (!allowed.contains(type)) {
    throw PluginFrameException('unsupported frame type: $type');
  }
  _validate(type, json);
  return PluginFrame(type, json);
}

void _validate(String type, Map<String, Object?> json) {
  switch (type) {
    case 'hello':
      _id(json);
      final protocol = _map(json, 'protocol');
      final supported = _list(protocol, 'supported', min: 1, max: 8);
      if (supported.any((v) => v is! String)) {
        throw const PluginFrameException('protocol.supported must be strings');
      }
      final preferred = _string(protocol, 'preferred', max: 16);
      if (!supported.contains(preferred)) {
        throw const PluginFrameException('preferred must be supported');
      }
      final host = _map(json, 'host');
      _string(host, 'name', max: 64);
      _string(host, 'version', max: 64);
      _string(json, 'dataDir', max: 4096);
    case 'hello.result':
      _id(json);
      final protocol = _string(json, 'protocol', max: 16);
      if (!_pluginProtocolPattern.hasMatch(protocol)) {
        throw const PluginFrameException('protocol must be 1.x');
      }
      final plugin = _map(json, 'plugin');
      _string(plugin, 'id', max: 48);
      _string(plugin, 'version', max: 64);
      _string(plugin, 'name', max: 128);
      final capabilities = _map(json, 'capabilities');
      final models = capabilities['models'];
      if (models != null) {
        if (models is! List ||
            models.length > PluginProtocolLimits.maxModels) {
          throw const PluginFrameException('models must be a short list');
        }
        for (final model in models) {
          if (model is! Map) {
            throw const PluginFrameException('model must be an object');
          }
          final entry = Map<String, Object?>.from(model);
          _string(entry, 'id', max: PluginProtocolLimits.maxModelLength);
          _string(entry, 'name', max: 128);
        }
      }
    case 'probe':
      _id(json);
      _enum(json, 'mode', const {'passive', 'live'});
    case 'probe.result':
      _id(json);
      _enum(json, 'state', _probeStates);
      final issueCode = json['issueCode'];
      if (issueCode != null &&
          (issueCode is! String || !_issueCodePattern.hasMatch(issueCode))) {
        throw const PluginFrameException('issueCode is malformed');
      }
      final checks = json['checks'];
      if (checks != null) {
        if (checks is! List || checks.length > PluginProtocolLimits.maxChecks) {
          throw const PluginFrameException('checks must be a short list');
        }
        for (final check in checks) {
          if (check is! Map) {
            throw const PluginFrameException('check must be an object');
          }
          final entry = Map<String, Object?>.from(check);
          _string(entry, 'code', max: 64);
          if (entry['ok'] is! bool) {
            throw const PluginFrameException('check.ok must be a boolean');
          }
          final message = entry['message'];
          if (message != null &&
              (message is! String ||
                  message.length > PluginProtocolLimits.maxCheckMessageLength)) {
            throw const PluginFrameException('check.message is too long');
          }
        }
      }
    case 'execute':
      _id(json);
      final deadline = json['deadlineMs'];
      if (deadline is! int ||
          deadline < 1 ||
          deadline > PluginProtocolLimits.maxTimeoutMs) {
        throw const PluginFrameException('deadlineMs is out of range');
      }
      _string(json, 'prompt',
          max: PluginProtocolLimits.maxPromptBytes, allowEmpty: true);
      if (utf8.encode(json['prompt'] as String).length >
          PluginProtocolLimits.maxPromptBytes) {
        throw const PluginFrameException('prompt exceeds the byte limit');
      }
      _string(json, 'workingDirectory', max: 4096);
      _enum(json, 'access', const {'read_only', 'read_write'});
      final model = json['model'];
      if (model != null &&
          (model is! String ||
              model.isEmpty ||
              model.length > PluginProtocolLimits.maxModelLength)) {
        throw const PluginFrameException('model is malformed');
      }
      final session = json['session'];
      if (session != null) {
        if (session is! Map) {
          throw const PluginFrameException('session must be an object');
        }
        final entry = Map<String, Object?>.from(session);
        _string(entry, 'key', max: PluginProtocolLimits.maxSessionKeyLength);
        _enum(entry, 'mode', const {'new', 'resume'});
      }
      final attachments = json['attachments'];
      if (attachments != null && (attachments is! List || attachments.isNotEmpty)) {
        throw const PluginFrameException('attachments are reserved');
      }
    case 'progress':
      _id(json);
      _string(json, 'message', max: PluginProtocolLimits.maxProgressMessageLength);
      final percent = json['percent'];
      if (percent != null && (percent is! int || percent < 0 || percent > 100)) {
        throw const PluginFrameException('percent must be 0..100');
      }
    case 'activity':
      _id(json);
      final seq = json['seq'];
      if (seq is! int || seq < 0) {
        throw const PluginFrameException('seq must be a non-negative integer');
      }
      _enum(json, 'activity', _activityTypes);
      final title = json['title'];
      if (title != null &&
          (title is! String ||
              title.length > PluginProtocolLimits.maxActivityTitleLength)) {
        throw const PluginFrameException('title is too long');
      }
      final details = json['details'];
      if (details != null) {
        if (details is! Map ||
            utf8.encode(jsonEncode(details)).length >
                PluginProtocolLimits.maxActivityDetailsBytes) {
          throw const PluginFrameException('details are too large');
        }
      }
    case 'result':
      _id(json);
      _string(json, 'output',
          max: PluginProtocolLimits.maxOutputBytes, allowEmpty: true);
      if (utf8.encode(json['output'] as String).length >
          PluginProtocolLimits.maxOutputBytes) {
        throw const PluginFrameException('output exceeds the byte limit');
      }
      final artifacts = json['artifacts'];
      if (artifacts != null) {
        if (artifacts is! List ||
            artifacts.length > PluginProtocolLimits.maxArtifacts) {
          throw const PluginFrameException('artifacts must be a short list');
        }
        for (final artifact in artifacts) {
          if (artifact is! Map) {
            throw const PluginFrameException('artifact must be an object');
          }
          final entry = Map<String, Object?>.from(artifact);
          final path = entry['path'];
          if (path is! String || !isSafePluginRelativePath(path)) {
            throw const PluginFrameException(
                PluginHostFailure.artifactPathInvalid);
          }
        }
      }
      final session = json['session'];
      if (session != null) {
        if (session is! Map) {
          throw const PluginFrameException('session must be an object');
        }
        _enum(Map<String, Object?>.from(session), 'state',
            const {'created', 'resumed', 'unavailable'});
      }
    case 'error':
      if (json['id'] != null) _id(json);
      _string(json, 'code', max: 64);
      _string(json, 'message',
          max: PluginProtocolLimits.maxErrorMessageLength, allowEmpty: true);
      final retryable = json['retryable'];
      if (retryable != null && retryable is! bool) {
        throw const PluginFrameException('retryable must be a boolean');
      }
    case 'cancel':
      _id(json);
      final reason = json['reason'];
      if (reason != null && (reason is! String || reason.length > 128)) {
        throw const PluginFrameException('reason is too long');
      }
    case 'ping':
    case 'pong':
      _string(json, 'nonce', max: 128);
    case 'shutdown':
      break;
  }
}

String _id(Map<String, Object?> json) {
  final value = json['id'];
  if (value is! String || !_idPattern.hasMatch(value)) {
    throw const PluginFrameException('id is missing or malformed');
  }
  return value;
}

String _string(
  Map<String, Object?> json,
  String key, {
  required int max,
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.isEmpty) || value.length > max) {
    throw PluginFrameException('"$key" must be a bounded string');
  }
  return value;
}

String _enum(Map<String, Object?> json, String key, Set<String> allowed) {
  final value = json[key];
  if (value is! String || !allowed.contains(value)) {
    throw PluginFrameException('"$key" is not an allowed value');
  }
  return value;
}

Map<String, Object?> _map(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw PluginFrameException('"$key" must be an object');
  return Map<String, Object?>.from(value);
}

List<Object?> _list(
  Map<String, Object?> json,
  String key, {
  required int min,
  required int max,
}) {
  final value = json[key];
  if (value is! List || value.length < min || value.length > max) {
    throw PluginFrameException('"$key" must be a list of $min..$max items');
  }
  return List<Object?>.from(value);
}
