import 'limits.dart';

/// A manifest or Worker answer that breaks a bound in
/// `WORKER_PLUGIN_PROTOCOL_V1.md`.
class ExternalWorkerValidationException implements Exception {
  const ExternalWorkerValidationException(this.message);
  final String message;

  @override
  String toString() => 'ExternalWorkerValidationException: $message';
}

/// True for a relative path that stays inside its base: no absolute form, no
/// drive letter, no empty or `..` segment, no NUL.
bool isSafeExternalWorkerRelativePath(String path) {
  if (path.isEmpty || path.length > ExternalWorkerLimits.maxPathLength) {
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

String _string(
  Map<String, Object?> json,
  String key, {
  required int max,
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      value.length > max) {
    throw ExternalWorkerValidationException('"$key" must be a bounded string');
  }
  return value;
}

String _enum(Map<String, Object?> json, String key, Set<String> allowed) {
  final value = json[key];
  if (value is! String || !allowed.contains(value)) {
    throw ExternalWorkerValidationException('"$key" is not an allowed value');
  }
  return value;
}

/// Validates a Worker's model list (`syntila.models`).
void validateExternalWorkerModels(Object? value) {
  if (value is! List || value.length > ExternalWorkerLimits.maxModels) {
    throw const ExternalWorkerValidationException(
        'models must be a bounded list');
  }
  final ids = <String>{};
  for (final raw in value) {
    if (raw is! Map)
      throw const ExternalWorkerValidationException('model must be an object');
    final model = Map<String, Object?>.from(raw);
    final id = _string(model, 'id', max: ExternalWorkerLimits.maxModelLength);
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(id) ||
        !ids.add(id)) {
      throw const ExternalWorkerValidationException(
          'model ID is invalid or duplicated');
    }
    final name = _string(model, 'name', max: 128);
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const ExternalWorkerValidationException(
          'model name contains control characters');
    }
    if (model['status'] != null)
      _enum(model, 'status', const {'listed', 'verified', 'unavailable'});
  }
}

void validateExternalWorkerContinuity(Object? value) {
  if (value == null) return;
  if (value is! Map)
    throw const ExternalWorkerValidationException(
        'continuity must be an object');
  final spec = Map<String, Object?>.from(value);
  _enum(spec, 'strategy',
      const {'none', 'history_replay', 'native_handle', 'checkpoint'});
  if (spec['formatId'] != null ||
      const {'native_handle', 'checkpoint'}.contains(spec['strategy'])) {
    final format = _string(spec, 'formatId', max: 96);
    if (!RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(format)) {
      throw const ExternalWorkerValidationException('formatId is malformed');
    }
  }
  if (spec['modelSwitchSupported'] != null &&
      spec['modelSwitchSupported'] is! bool) {
    throw const ExternalWorkerValidationException(
        'modelSwitchSupported must be boolean');
  }
}
