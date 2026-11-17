import 'generated_protocol.dart';

export 'generated_protocol.dart';
export 'provider_failure.dart';
export 'realtime_events.dart';
export 'workspace_runtime_protocol.dart';
export 'worker_descriptor.dart';
export 'worker_execution_options.dart';

bool isExecutionErrorCode(Object? value) => executionErrorCodes.contains(value);

String canonicalExecutionErrorCode(Object? value) =>
    isExecutionErrorCode(value) ? value! as String : 'execution_failed';

String executionErrorMessage(Object? code) =>
    executionErrorMessages[canonicalExecutionErrorCode(code)]!;

class ProtocolException implements Exception {
  const ProtocolException(this.message);
  final String message;

  @override
  String toString() => 'ProtocolException: $message';
}

bool isCompatibleVersion(String local, String remote) {
  final localParts = _versionParts(local);
  final remoteParts = _versionParts(remote);
  return localParts.$1 == remoteParts.$1 && remoteParts.$2 >= localParts.$2;
}

(int, int, int) _versionParts(String version) {
  final parts = version.split('.').map(int.tryParse).toList();
  if ((parts.length != 2 && parts.length != 3) ||
      parts.any((part) => part == null)) {
    throw const ProtocolException('version must be major.minor.patch');
  }
  return (parts[0]!, parts[1]!, parts.length == 3 ? parts[2]! : 0);
}
