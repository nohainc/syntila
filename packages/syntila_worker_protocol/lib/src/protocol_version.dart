const localWorkerProtocolVersion = '4.1';

/// Protocol 4.2 adds the optional `executor` object on `execute.request`
/// (ADR-027 plugin executor). Frames default to 4.1; a plugin execute names
/// 4.2 explicitly, and 4.0/4.1 peers are unchanged.
const pluginExecutorProtocolVersion = '4.2';
const supportedLocalWorkerProtocolVersions = {
  '4.0',
  localWorkerProtocolVersion,
  pluginExecutorProtocolVersion,
};

/// Selects the newest protocol version supported by both sides.
String? negotiateProtocolVersion({
  required Iterable<String> workspaceVersions,
  required Iterable<String> workerVersions,
}) {
  final worker = workerVersions.toSet();
  final common = workspaceVersions
      .where(supportedLocalWorkerProtocolVersions.contains)
      .where(worker.contains)
      .toList()
    ..sort(_compareVersions);
  return common.isEmpty ? null : common.last;
}

int _compareVersions(String left, String right) {
  final leftParts = _parseVersion(left);
  final rightParts = _parseVersion(right);
  for (var index = 0; index < 2; index++) {
    final comparison = leftParts[index].compareTo(rightParts[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

List<int> _parseVersion(String value) {
  final match = RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$').firstMatch(value);
  if (match == null) throw FormatException('invalid protocol version: $value');
  return [int.parse(match[1]!), int.parse(match[2]!)];
}
